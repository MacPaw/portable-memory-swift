import Foundation

/// Writes a `.mem` bundle from any `PortableMemoryStore` (spec §1, §4). Streams are
/// deterministic (rows ordered by the host, fields sorted), every file is checksummed,
/// and embeddings are not inlined (source text is the portable truth; the receiver
/// re-embeds). Full or `--since` incremental.
public struct BundleExporter: Sendable {
    public init() {}

    public func export(_ store: PortableMemoryStore, to dir: URL,
                       mode: ExportMode = .full, since: Date? = nil,
                       level: ConformanceLevel = .L2) async throws -> MemManifest {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("items"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("audit"), withIntermediateDirectories: true)

        let info = try await store.storeInfo()
        var files: [MemFileEntry] = []
        var counts: [String: Int] = [:]
        let incremental = (mode == .incremental)
        // A cursor only applies to an incremental export. Ignore a stray `since` on a
        // full export so it can never silently omit older tombstones/audit rows or write
        // a `since` into a full manifest (which would contradict the schema).
        let cutoff = incremental ? since : nil
        func keep(_ ts: Date) -> Bool { !incremental || cutoff == nil || ts >= cutoff! }

        // ── Bulky, append-mostly kinds: --since delta-filtered. Episodes merge `ext`. ──
        let extMap = try await store.exportEpisodeExt()
        let episodes = try await store.exportEpisodes().filter { keep($0.ingestionTime) }
        counts[MemKind.episode.rawValue] =
            try writeEpisodes(episodes, extMap: extMap, to: "items/episode.jsonl", in: dir, files: &files)

        let facts = try await store.exportFacts().filter { keep($0.createdAt) }
        counts[MemKind.fact.rawValue] = try writeJSONL(facts, "items/fact.jsonl", dir, &files)

        let factLinks = try await store.exportFactLinks().filter { keep($0.createdAt) }
        counts[MemKind.factLink.rawValue] = try writeJSONL(factLinks, "items/factLink.jsonl", dir, &files)

        let resources = try await store.exportResources().filter { keep($0.created) }
        counts[MemKind.resource.rawValue] = try writeJSONL(resources, "items/resource.jsonl", dir, &files)

        // Chunks have no own cursor; in incremental mode emit only those whose parent
        // resource is in the delta, so a newly-ingested resource's chunks travel with it.
        let allChunks = try await store.exportChunks()
        let deltaResourceIDs = Set(resources.map { $0.id })
        let chunks = incremental ? allChunks.filter { deltaResourceIDs.contains($0.resourceID) } : allChunks
        counts[MemKind.chunk.rawValue] = try writeJSONL(chunks, "items/chunk.jsonl", dir, &files)

        // ── Structural / graph / profile kinds: ALWAYS emitted in full (even incremental).
        //    Small, no reliable change cursor; skipping them would orphan edges/facts that
        //    reference a new entity, drop links/profile, or miss a supersession that mutates
        //    an OLD edge. Full emission + idempotent merge-by-id keeps imports complete. ──
        counts[MemKind.entity.rawValue] = try writeJSONL(await store.exportEntities(), "items/entity.jsonl", dir, &files)
        counts[MemKind.edge.rawValue] = try writeJSONL(await store.exportEdges(), "items/edge.jsonl", dir, &files)
        counts[MemKind.episodeLink.rawValue] = try writeJSONL(await store.exportEpisodeLinks(), "items/episodeLink.jsonl", dir, &files)
        counts[MemKind.core.rawValue] = try writeJSONL(await store.exportCoreBlocks(), "items/core.jsonl", dir, &files)
        counts[MemKind.procedure.rawValue] = try writeJSONL(await store.exportProcedures(), "items/procedure.jsonl", dir, &files)
        counts[MemKind.context.rawValue] = try writeJSONL(await store.exportContexts(), "items/context.jsonl", dir, &files)
        counts[MemKind.community.rawValue] = try writeJSONL(await store.exportCommunities(), "items/community.jsonl", dir, &files)
        counts[MemKind.category.rawValue] = try writeJSONL(await store.exportCategories(), "items/category.jsonl", dir, &files)
        counts[MemKind.preference.rawValue] = try writeJSONL(await store.exportPreferences(), "items/preference.jsonl", dir, &files)
        counts[MemKind.secretRef.rawValue] = try writeJSONL(await store.exportSecretRefs(), "items/secretRef.jsonl", dir, &files)

        // ── Unknown-kind passthrough — re-emit foreign record kinds verbatim (§10). ──
        for kind in try await store.exportPassthroughKinds() where MemKind(rawValue: kind) == nil {
            let lines = try await store.exportPassthroughLines(kind: kind)
            guard !lines.isEmpty else { continue }
            let data = Data((lines.joined(separator: "\n") + "\n").utf8)
            let rel = "items/\(kind).jsonl"
            try data.write(to: dir.appendingPathComponent(rel))
            files.append(MemFileEntry(path: rel, sha256: Hashing.sha256Hex(data), bytes: data.count))
            counts[kind] = lines.count
        }

        // ── audit/tombstones.jsonl — applied FIRST on import (§5). ──
        let tombstones = try await store.exportTombstones(since: cutoff)
        counts["tombstone"] = try writeJSONL(tombstones, "audit/tombstones.jsonl", dir, &files)

        // ── audit/log.jsonl — the portable mutation trail (L1+). ──
        if level != .L0 {
            let audit = try await store.exportAuditLog(since: cutoff)
            counts["audit"] = try writeJSONL(audit, "audit/log.jsonl", dir, &files)
        }

        try writeChecksums(files, in: dir)
        let manifest = makeManifest(
            info: info, level: level, mode: mode, since: cutoff,
            counts: counts, files: files,
            capabilities: ["bitemporal", "tombstones", "redaction", "evidence-pack", "ext", "passthrough"])
        try MemCodec.encoder.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        return manifest
    }

    /// The Memory Evidence Pack (spec §6): audit + tombstones (proof-of-deletion) +
    /// provenance (edge → evidence episodes). Procurement-grade; conformance L3.
    public func exportEvidencePack(_ store: PortableMemoryStore, to dir: URL,
                                   since: Date? = nil) async throws -> MemManifest {
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("audit"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("provenance"), withIntermediateDirectories: true)
        let info = try await store.storeInfo()
        var files: [MemFileEntry] = []
        var counts: [String: Int] = [:]
        counts["audit"] = try writeJSONL(await store.exportAuditLog(since: since), "audit/log.jsonl", dir, &files)
        counts["tombstone"] = try writeJSONL(await store.exportTombstones(since: since), "audit/tombstones.jsonl", dir, &files)
        counts["provenanceEdge"] = try writeJSONL(await store.exportEdges(), "provenance/edges.jsonl", dir, &files)
        try writeChecksums(files, in: dir)
        let manifest = makeManifest(
            info: info, level: .L3, mode: since == nil ? .full : .incremental, since: since,
            counts: counts, files: files,
            capabilities: ["evidence-pack", "proof-of-deletion", "audit", "provenance"])
        try MemCodec.encoder.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        return manifest
    }

    // MARK: - Internals

    private func makeManifest(info: StoreInfo, level: ConformanceLevel, mode: ExportMode,
                              since: Date?, counts: [String: Int], files: [MemFileEntry],
                              capabilities: [String]) -> MemManifest {
        MemManifest(
            format: MemFormat.version, generator: info.generator, conformanceLevel: level,
            createdAt: Date(), exportMode: mode, since: since, schemaVersion: info.schemaVersion,
            embeddingModel: info.embeddingModel, embeddingDim: info.embeddingDim,
            embeddingsIncluded: false, capabilities: capabilities,
            counts: counts.filter { $0.value > 0 }, files: files.sorted { $0.path < $1.path })
    }

    private func writeChecksums(_ files: [MemFileEntry], in dir: URL) throws {
        let lines = files.sorted { $0.path < $1.path }.map { "\($0.sha256)  \($0.path)" }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: dir.appendingPathComponent("CHECKSUMS"))
    }

    private func writeEpisodes(_ episodes: [PortableEpisode], extMap: [String: String],
                               to relPath: String, in dir: URL, files: inout [MemFileEntry]) throws -> Int {
        guard !episodes.isEmpty else { return 0 }
        var lines: [String] = []
        lines.reserveCapacity(episodes.count)
        for e in episodes.sorted(by: { $0.id < $1.id }) {
            let native = try MemCodec.encoder.encode(e)
            lines.append(String(decoding: Interop.mergeEpisodeExt(nativeJSON: native, extJSON: extMap[e.id]), as: UTF8.self))
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        try data.write(to: dir.appendingPathComponent(relPath))
        files.append(MemFileEntry(path: relPath, sha256: Hashing.sha256Hex(data), bytes: data.count))
        return episodes.count
    }

    private func writeJSONL<T: Encodable>(_ rows: [T], _ relPath: String,
                                          _ dir: URL, _ files: inout [MemFileEntry]) throws -> Int {
        guard !rows.isEmpty else { return 0 }
        let lines = try rows.map { try MemCodec.line($0) }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        try data.write(to: dir.appendingPathComponent(relPath))
        files.append(MemFileEntry(path: relPath, sha256: Hashing.sha256Hex(data), bytes: data.count))
        return rows.count
    }
}
