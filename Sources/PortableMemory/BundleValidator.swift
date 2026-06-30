import Foundation

/// Validates a `.mem` bundle without importing it — the L0 conformance check and a
/// pre-flight any adopter can run. Verifies the manifest parses, every listed file
/// matches its checksum, no unlisted data files were injected, and known-kind streams
/// decode. Returns a result with any issues rather than throwing on the first.
public struct BundleValidator: Sendable {
    public init() {}

    public struct Result: Sendable {
        public var ok: Bool { issues.isEmpty }
        public var manifest: MemManifest?
        public var issues: [String]
    }

    public func validate(bundle dir: URL) -> Result {
        var issues: [String] = []
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let mData = try? Data(contentsOf: manifestURL) else {
            return Result(manifest: nil, issues: ["manifest.json missing"])
        }
        guard let manifest = try? MemCodec.decoder.decode(MemManifest.self, from: mData) else {
            return Result(manifest: nil, issues: ["manifest.json does not parse"])
        }
        if manifest.format.split(separator: ".").first != MemFormat.version.split(separator: ".").first {
            issues.append("major format mismatch: bundle \(manifest.format) vs reader \(MemFormat.version)")
        }

        let listed = Set(manifest.files.map { $0.path })
        for f in manifest.files {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(f.path)) else {
                issues.append("listed file missing: \(f.path)"); continue
            }
            if Hashing.sha256Hex(data) != f.sha256 { issues.append("checksum mismatch: \(f.path)") }
            if data.count != f.bytes { issues.append("byte-count mismatch: \(f.path)") }
        }
        let fm = FileManager.default
        for sub in ["items", "audit", "embeddings"] {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir.appendingPathComponent(sub), includingPropertiesForKeys: nil) else { continue }
            for u in entries where !listed.contains("\(sub)/\(u.lastPathComponent)") {
                issues.append("unlisted file present: \(sub)/\(u.lastPathComponent)")
            }
        }
        // Known-kind streams must decode (unknown kinds are intentionally opaque).
        for kind in MemKind.allCases {
            let url = dir.appendingPathComponent("items/\(kind.rawValue).jsonl")
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
                let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty, let d = s.data(using: .utf8) else { continue }
                if !decodes(kind, d) { issues.append("malformed \(kind.rawValue) record"); break }
            }
        }
        return Result(manifest: manifest, issues: issues)
    }

    private func decodes(_ kind: MemKind, _ d: Data) -> Bool {
        let dec = MemCodec.decoder
        switch kind {
        case .episode: return (try? dec.decode(PortableEpisode.self, from: d)) != nil
        case .entity: return (try? dec.decode(PortableEntity.self, from: d)) != nil
        case .edge: return (try? dec.decode(PortableEdge.self, from: d)) != nil
        case .fact: return (try? dec.decode(PortableFact.self, from: d)) != nil
        case .factLink: return (try? dec.decode(PortableFactLink.self, from: d)) != nil
        case .episodeLink: return (try? dec.decode(PortableEpisodeLink.self, from: d)) != nil
        case .resource: return (try? dec.decode(PortableResource.self, from: d)) != nil
        case .chunk: return (try? dec.decode(PortableChunk.self, from: d)) != nil
        case .core: return (try? dec.decode(PortableCore.self, from: d)) != nil
        case .procedure: return (try? dec.decode(PortableProcedure.self, from: d)) != nil
        case .context: return (try? dec.decode(PortableContext.self, from: d)) != nil
        case .community: return (try? dec.decode(PortableCommunity.self, from: d)) != nil
        case .category: return (try? dec.decode(PortableCategory.self, from: d)) != nil
        case .preference: return (try? dec.decode(PortablePreference.self, from: d)) != nil
        case .secretRef: return (try? dec.decode(PortableSecretRef.self, from: d)) != nil
        }
    }
}
