import Foundation

public enum MemImportError: Error, CustomStringConvertible {
    case manifestMissing(String)
    case checksumMismatch(String)
    case dimensionMismatch(expected: Int, got: Int)

    public var description: String {
        switch self {
        case .manifestMissing(let p): return "manifest not found at \(p)"
        case .checksumMismatch(let f): return "checksum mismatch for \(f) — bundle is corrupt or tampered"
        case .dimensionMismatch(let e, let g):
            return "embedding dimension mismatch: bundle=\(g), store=\(e)."
        }
    }
}

/// Reads a `.mem` bundle into any `PortableMemoryStore` (spec §4). Idempotent and
/// merge-by-id; tombstones applied FIRST (no resurrection); integrity verified before
/// any write; foreign fields (`ext`) and foreign kinds preserved; the host re-derives
/// its own artifacts in `finalizeImport`.
public struct BundleImporter: Sendable {
    public init() {}

    public func importBundle(_ store: PortableMemoryStore, from dir: URL,
                             reembed: Bool = true, dryRun: Bool = false) async throws -> MemImportReport {
        // 1. Manifest + integrity.
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw MemImportError.manifestMissing(manifestURL.path)
        }
        let manifest = try MemCodec.decoder.decode(MemManifest.self, from: manifestData)
        try verifyChecksums(dir: dir, manifest: manifest)
        let info = try await store.storeInfo()
        if manifest.embeddingsIncluded, info.embeddingDim > 0, manifest.embeddingDim != info.embeddingDim {
            throw MemImportError.dimensionMismatch(expected: info.embeddingDim, got: manifest.embeddingDim)
        }

        var report = MemImportReport()
        if dryRun {
            report.applied = manifest.counts.filter { MemKind(rawValue: $0.key) != nil }
            report.tombstonesApplied = manifest.counts["tombstone"] ?? 0
            return report
        }

        // 2. Tombstones FIRST (§5).
        for t in try readJSONL(dir, "audit/tombstones.jsonl", Tombstone.self) {
            try await store.applyTombstone(t)
            report.tombstonesApplied += 1
        }
        let tombstoned = try await store.tombstonedTargetIDs()
        func bump(_ k: MemKind, _ n: Int = 1) { report.applied[k.rawValue, default: 0] += n }

        // 3. Merge items by id, dependency order.
        for c in try readJSONL(dir, "items/context.jsonl", PortableContext.self) { try await store.importContext(c); bump(.context) }
        for c in try readJSONL(dir, "items/category.jsonl", PortableCategory.self) { try await store.importCategory(c); bump(.category) }
        for p in try readJSONL(dir, "items/preference.jsonl", PortablePreference.self) { try await store.importPreference(p); bump(.preference) }
        for c in try readJSONL(dir, "items/core.jsonl", PortableCore.self) { try await store.importCoreBlock(c); bump(.core) }
        for e in try readJSONL(dir, "items/entity.jsonl", PortableEntity.self) { try await store.importEntity(e); bump(.entity) }

        var importedEpisodeIDs: [String] = []
        for (lineData, e) in try readEpisodes(dir, "items/episode.jsonl") {
            if tombstoned.contains(e.id) { report.skippedTombstoned += 1; continue }
            try await store.importEpisode(e, ext: Interop.extractEpisodeExt(line: lineData))
            importedEpisodeIDs.append(e.id); bump(.episode)
        }
        for r in try readJSONL(dir, "items/resource.jsonl", PortableResource.self) { try await store.importResource(r); bump(.resource) }
        for c in try readJSONL(dir, "items/chunk.jsonl", PortableChunk.self) { try await store.importChunk(c); bump(.chunk) }
        for e in try readJSONL(dir, "items/edge.jsonl", PortableEdge.self) { try await store.importEdge(e); bump(.edge) }
        for f in try readJSONL(dir, "items/fact.jsonl", PortableFact.self) {
            if tombstoned.contains(f.episodeID) { report.skippedTombstoned += 1; continue }
            try await store.importFact(f); bump(.fact)
        }
        for l in try readJSONL(dir, "items/factLink.jsonl", PortableFactLink.self) { try await store.importFactLink(l); bump(.factLink) }
        for l in try readJSONL(dir, "items/episodeLink.jsonl", PortableEpisodeLink.self) {
            if tombstoned.contains(l.srcEpisodeID) || tombstoned.contains(l.dstEpisodeID) { continue }
            try await store.importEpisodeLink(l); bump(.episodeLink)
        }
        for p in try readJSONL(dir, "items/procedure.jsonl", PortableProcedure.self) { try await store.importProcedure(p); bump(.procedure) }
        for c in try readJSONL(dir, "items/community.jsonl", PortableCommunity.self) { try await store.importCommunity(c); bump(.community) }
        let refs = try readJSONL(dir, "items/secretRef.jsonl", PortableSecretRef.self)
        for r in refs { try await store.importSecretRef(r); bump(.secretRef) }
        if !refs.isEmpty {
            report.warnings.append(
                "\(refs.count) secret reference(s): metadata skeleton restored, but the encrypted " +
                "VALUE is not in the bundle — transfer it via an authorized encrypted channel (spec §7).")
        }

        // 4. Unknown-kind passthrough — store foreign kinds verbatim (§10). Already
        //    integrity-checked (listed in the manifest).
        let knownFiles = Set(MemKind.allCases.map { "\($0.rawValue).jsonl" })
        let itemsDir = dir.appendingPathComponent("items")
        if let entries = try? FileManager.default.contentsOfDirectory(at: itemsDir, includingPropertiesForKeys: nil) {
            for u in entries where u.pathExtension == "jsonl" && !knownFiles.contains(u.lastPathComponent) {
                let kind = String(u.lastPathComponent.dropLast(6))
                let lines = rawLines(u)
                guard !lines.isEmpty else { continue }
                try await store.storePassthrough(kind: kind, lines: lines)
                report.applied[kind, default: 0] += lines.count
            }
        }

        // 5. Host re-derives FTS/sentences/embeddings; then converge the replica.
        report.reembedded = try await store.finalizeImport(reembedEpisodeIDs: importedEpisodeIDs, reembed: reembed)
        try await store.sync()
        return report
    }

    // MARK: - Internals

    private func verifyChecksums(dir: URL, manifest: MemManifest) throws {
        let listed = Set(manifest.files.map { $0.path })
        for f in manifest.files {
            // A crafted manifest must not be able to escape the bundle directory.
            guard BundlePath.isSafe(f.path) else {
                throw MemImportError.checksumMismatch("\(f.path) (path escapes the bundle)")
            }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(f.path)) else {
                throw MemImportError.checksumMismatch("\(f.path) (missing)")
            }
            if Hashing.sha256Hex(data) != f.sha256 { throw MemImportError.checksumMismatch(f.path) }
        }
        // No UNLISTED data file may be present — the importer reads items/ and audit/ by
        // fixed path, so an injected file would otherwise be ingested unverified.
        let fm = FileManager.default
        for sub in ["items", "audit", "embeddings"] {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir.appendingPathComponent(sub), includingPropertiesForKeys: nil) else { continue }
            for u in entries {
                let rel = "\(sub)/\(u.lastPathComponent)"
                if !listed.contains(rel) {
                    throw MemImportError.checksumMismatch("\(rel) (present but not listed in manifest)")
                }
            }
        }
    }

    private func readEpisodes(_ dir: URL, _ relPath: String) throws -> [(line: Data, episode: PortableEpisode)] {
        let url = dir.appendingPathComponent(relPath)
        guard let data = try? Data(contentsOf: url) else { return [] }
        var out: [(Data, PortableEpisode)] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, let d = s.data(using: .utf8) else { continue }
            out.append((d, try MemCodec.decoder.decode(PortableEpisode.self, from: d)))
        }
        return out
    }

    /// Verbatim line content for unknown-kind passthrough — does NOT trim, so each
    /// record's bytes survive a round-trip unchanged (only the `\n` framing, inherent to
    /// JSONL, is normalized; empty lines carry no record and are dropped).
    private func rawLines(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func readJSONL<T: Decodable>(_ dir: URL, _ relPath: String, _ type: T.Type) throws -> [T] {
        let url = dir.appendingPathComponent(relPath)
        guard let data = try? Data(contentsOf: url) else { return [] }
        var out: [T] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, let d = s.data(using: .utf8) else { continue }
            out.append(try MemCodec.decoder.decode(T.self, from: d))
        }
        return out
    }
}
