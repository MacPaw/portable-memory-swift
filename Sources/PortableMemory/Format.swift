import Foundation

// MARK: - Portable Memory format (.mem bundle)
//
// An open, vendor-neutral container for carrying AI memory across apps, devices, and
// vendors — losslessly, locally, and verifiably governed. A bundle is a plain
// directory of JSONL streams plus a manifest and a checksum file; no server is needed
// to read, verify, or transfer it. The format is a lossless SUPERSET container:
// foreign FIELDS on the episode record survive via `ext`, and entire foreign KINDS
// round-trip verbatim, so a newer or other-vendor bundle never loses data in any
// conformant reader.
//
// Full specification: Spec/portable-memory-spec.md.

public enum MemFormat {
    /// Semantic version of the on-disk format. Importers negotiate by this + capabilities.
    public static let version = "1.0.0"
    /// Conventional bundle directory suffix.
    public static let bundleSuffix = "mem"
}

/// The portable type tag for a record in `items/<kind>.jsonl`. The seven-component
/// memory model (Working / Core / Episodic / Semantic / Procedural / Resource /
/// Vault) maps onto these kinds; adopters may add kinds, and kinds not in this enum
/// round-trip verbatim via passthrough (see `BundleImporter`/`BundleExporter`).
public enum MemKind: String, Codable, CaseIterable, Sendable {
    case episode        // a timestamped event — the atomic, cross-vendor memory unit
    case entity         // a semantic graph node
    case edge           // a bi-temporal relation
    case fact           // a derived subject–predicate–object triple
    case factLink       // evidence_of / refines link between facts
    case episodeLink    // cross-link between episodes
    case resource       // a file/doc reference, parent of chunks
    case chunk          // a resource fragment
    case core           // an always-injected profile block
    case procedure      // a user-defined routine
    case context        // a scoping/tag node
    case community      // a graph community
    case category       // a memory category
    case preference     // a durable user key/value setting
    case secretRef      // a reference to a vault secret — NEVER plaintext/ciphertext

    /// Stable import order: parents before children so references resolve.
    public static let importOrder: [MemKind] = [
        .context, .category, .preference, .core,
        .entity, .episode, .resource, .chunk,
        .edge, .fact, .factLink, .episodeLink,
        .procedure, .community, .secretRef,
    ]
}

public enum ExportMode: String, Codable, Sendable {
    case full
    case incremental
}

/// Conformance levels (spec §8). The badge requires **L2** — deletion-propagation
/// correctness is the single hardest guarantee a memory layer makes.
public enum ConformanceLevel: String, Codable, Sendable, CaseIterable {
    case L0   // Read / Export — a valid, checksum-clean bundle
    case L1   // Import / Merge — lossless, idempotent, bi-temporal merge
    case L2   // Deletion propagation — honors tombstones across all derived artifacts (BADGE)
    case L3   // Governed — full audit trail, Evidence Pack, signed tombstones
}

/// One file's integrity record, mirrored in `manifest.files` and `CHECKSUMS`.
public struct MemFileEntry: Codable, Sendable {
    public var path: String      // bundle-relative, e.g. "items/episode.jsonl"
    public var sha256: String    // lowercase hex
    public var bytes: Int
    public init(path: String, sha256: String, bytes: Int) {
        self.path = path; self.sha256 = sha256; self.bytes = bytes
    }
}

/// Declares everything an importer needs to negotiate capabilities and verify integrity.
public struct MemManifest: Codable, Sendable {
    public var format: String                 // MemFormat.version
    public var generator: String              // "<vendor>/<version>"
    public var conformanceLevel: ConformanceLevel
    public var createdAt: Date
    public var exportMode: ExportMode
    public var since: Date?                   // present for incremental exports
    public var schemaVersion: Int             // source store's schema version at export time
    public var embeddingModel: String         // model tag for embeddings/*.vec (engine-agnostic)
    public var embeddingDim: Int
    public var embeddingsIncluded: Bool       // false ⇒ receiver must re-embed from source text
    public var capabilities: [String]         // e.g. bitemporal, tombstones, redaction, embeddings:<model>
    public var counts: [String: Int]          // MemKind.rawValue (or vendor kind) → row count
    public var files: [MemFileEntry]          // integrity (excludes manifest.json + CHECKSUMS)

    public init(format: String, generator: String, conformanceLevel: ConformanceLevel,
                createdAt: Date, exportMode: ExportMode, since: Date?, schemaVersion: Int,
                embeddingModel: String, embeddingDim: Int, embeddingsIncluded: Bool,
                capabilities: [String], counts: [String: Int], files: [MemFileEntry]) {
        self.format = format
        self.generator = generator
        self.conformanceLevel = conformanceLevel
        self.createdAt = createdAt
        self.exportMode = exportMode
        self.since = since
        self.schemaVersion = schemaVersion
        self.embeddingModel = embeddingModel
        self.embeddingDim = embeddingDim
        self.embeddingsIncluded = embeddingsIncluded
        self.capabilities = capabilities
        self.counts = counts
        self.files = files
    }
}

// MARK: - Bundle path safety

/// A `.mem` is untrusted input: a crafted `manifest.json` could list a `path` with an
/// absolute root or `..` segments to make a reader hash/ingest files OUTSIDE the bundle
/// directory. Every manifest-declared path must be validated bundle-relative before it
/// is resolved against the bundle root.
public enum BundlePath {
    public static func isSafe(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~") else { return false }
        // Reject Windows-style roots / drive letters and backslash separators too.
        if relativePath.contains("\\") || relativePath.contains(":") { return false }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        for c in components where c == ".." || c == "." { return false }
        return true
    }
}

// MARK: - Deterministic canonical codec

/// The single JSON configuration used for every portable record, so serialization is
/// byte-deterministic (diffable bundles) and `content_hash` is computed over the
/// identical bytes a reader sees. `.sortedKeys` fixes field order; `.iso8601` is the
/// timestamp wire format throughout.
public enum MemCodec {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Encode one record to a single canonical JSON line (no trailing newline).
    public static func line<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
