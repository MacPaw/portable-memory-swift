import Foundation

/// Identity + embedding metadata a host stamps into the manifest.
public struct StoreInfo: Sendable {
    public var generator: String        // "<vendor>/<version>"
    public var schemaVersion: Int
    public var embeddingModel: String
    public var embeddingDim: Int
    public init(generator: String, schemaVersion: Int = 0,
                embeddingModel: String = "", embeddingDim: Int = 0) {
        self.generator = generator; self.schemaVersion = schemaVersion
        self.embeddingModel = embeddingModel; self.embeddingDim = embeddingDim
    }
}

/// The seam between the portable FORMAT (owned by this package) and a host's
/// PERSISTENCE (owned by the adopter). `BundleExporter` reads through this protocol;
/// `BundleImporter` writes through it. The package owns bundle I/O, the manifest,
/// checksums, deterministic JSONL, tombstone-first ordering, `--since` filtering, and
/// `ext`/passthrough; the host owns mapping its store to/from the portable DTOs and
/// re-deriving its own artifacts (FTS, embeddings, …) on import.
///
/// Every requirement has a default (empty read / no-op write), so an adopter overrides
/// ONLY the kinds it actually supports — a vendor with just episodes implements two
/// methods, not thirty.
public protocol PortableMemoryStore: Sendable {
    func storeInfo() async throws -> StoreInfo

    // MARK: Export readers (full snapshots; the exporter applies --since filtering)
    func exportEpisodes() async throws -> [PortableEpisode]
    func exportEpisodeExt() async throws -> [String: String]   // episode id → foreign-field JSON
    func exportEntities() async throws -> [PortableEntity]
    func exportEdges() async throws -> [PortableEdge]
    func exportFacts() async throws -> [PortableFact]
    func exportFactLinks() async throws -> [PortableFactLink]
    func exportEpisodeLinks() async throws -> [PortableEpisodeLink]
    func exportResources() async throws -> [PortableResource]
    func exportChunks() async throws -> [PortableChunk]
    func exportCoreBlocks() async throws -> [PortableCore]
    func exportProcedures() async throws -> [PortableProcedure]
    func exportContexts() async throws -> [PortableContext]
    func exportCommunities() async throws -> [PortableCommunity]
    func exportCategories() async throws -> [PortableCategory]
    func exportPreferences() async throws -> [PortablePreference]
    func exportSecretRefs() async throws -> [PortableSecretRef]
    func exportTombstones(since: Date?) async throws -> [Tombstone]
    func exportAuditLog(since: Date?) async throws -> [PortableAuditRecord]
    func exportPassthroughKinds() async throws -> [String]
    func exportPassthroughLines(kind: String) async throws -> [String]

    // MARK: Import writers
    func tombstonedTargetIDs() async throws -> Set<String>
    func applyTombstone(_ t: Tombstone) async throws
    func importEpisode(_ e: PortableEpisode, ext: String?) async throws
    func importEntity(_ e: PortableEntity) async throws
    func importEdge(_ e: PortableEdge) async throws
    func importFact(_ f: PortableFact) async throws
    func importFactLink(_ l: PortableFactLink) async throws
    func importEpisodeLink(_ l: PortableEpisodeLink) async throws
    func importResource(_ r: PortableResource) async throws
    func importChunk(_ c: PortableChunk) async throws
    func importCoreBlock(_ c: PortableCore) async throws
    func importProcedure(_ p: PortableProcedure) async throws
    func importContext(_ c: PortableContext) async throws
    func importCommunity(_ c: PortableCommunity) async throws
    func importCategory(_ c: PortableCategory) async throws
    func importPreference(_ p: PortablePreference) async throws
    /// Restore a secret REFERENCE's metadata skeleton (label, sensitivity, category,
    /// preview, encryption metadata) — NEVER the value/ciphertext, which is not in the
    /// bundle (spec §7). Default no-op: a store that can't represent a dangling ref
    /// simply skips it (the importer still reports it).
    func importSecretRef(_ r: PortableSecretRef) async throws
    func storePassthrough(kind: String, lines: [String]) async throws

    /// Re-derive host-local artifacts for the imported episodes (FTS, sentence index,
    /// and — when `reembed` and an embedder is available — vectors). Returns episodes
    /// embedded. The package re-derives nothing itself; this is the host's hook.
    func finalizeImport(reembedEpisodeIDs: [String], reembed: Bool) async throws -> Int

    /// Converge any synced replica (a deletion/merge target too). No-op when none.
    func sync() async throws
}

// MARK: - Defaults (empty read / no-op write) so adopters implement only what they support.

public extension PortableMemoryStore {
    func storeInfo() async throws -> StoreInfo { StoreInfo(generator: "portable-memory/\(MemFormat.version)") }

    func exportEpisodes() async throws -> [PortableEpisode] { [] }
    func exportEpisodeExt() async throws -> [String: String] { [:] }
    func exportEntities() async throws -> [PortableEntity] { [] }
    func exportEdges() async throws -> [PortableEdge] { [] }
    func exportFacts() async throws -> [PortableFact] { [] }
    func exportFactLinks() async throws -> [PortableFactLink] { [] }
    func exportEpisodeLinks() async throws -> [PortableEpisodeLink] { [] }
    func exportResources() async throws -> [PortableResource] { [] }
    func exportChunks() async throws -> [PortableChunk] { [] }
    func exportCoreBlocks() async throws -> [PortableCore] { [] }
    func exportProcedures() async throws -> [PortableProcedure] { [] }
    func exportContexts() async throws -> [PortableContext] { [] }
    func exportCommunities() async throws -> [PortableCommunity] { [] }
    func exportCategories() async throws -> [PortableCategory] { [] }
    func exportPreferences() async throws -> [PortablePreference] { [] }
    func exportSecretRefs() async throws -> [PortableSecretRef] { [] }
    func exportTombstones(since: Date?) async throws -> [Tombstone] { [] }
    func exportAuditLog(since: Date?) async throws -> [PortableAuditRecord] { [] }
    func exportPassthroughKinds() async throws -> [String] { [] }
    func exportPassthroughLines(kind: String) async throws -> [String] { [] }

    func tombstonedTargetIDs() async throws -> Set<String> { [] }
    func applyTombstone(_ t: Tombstone) async throws {}
    func importEpisode(_ e: PortableEpisode, ext: String?) async throws {}
    func importEntity(_ e: PortableEntity) async throws {}
    func importEdge(_ e: PortableEdge) async throws {}
    func importFact(_ f: PortableFact) async throws {}
    func importFactLink(_ l: PortableFactLink) async throws {}
    func importEpisodeLink(_ l: PortableEpisodeLink) async throws {}
    func importResource(_ r: PortableResource) async throws {}
    func importChunk(_ c: PortableChunk) async throws {}
    func importCoreBlock(_ c: PortableCore) async throws {}
    func importProcedure(_ p: PortableProcedure) async throws {}
    func importContext(_ c: PortableContext) async throws {}
    func importCommunity(_ c: PortableCommunity) async throws {}
    func importCategory(_ c: PortableCategory) async throws {}
    func importPreference(_ p: PortablePreference) async throws {}
    func importSecretRef(_ r: PortableSecretRef) async throws {}
    func storePassthrough(kind: String, lines: [String]) async throws {}
    func finalizeImport(reembedEpisodeIDs: [String], reembed: Bool) async throws -> Int { 0 }
    func sync() async throws {}
}
