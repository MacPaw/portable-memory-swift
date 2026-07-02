import XCTest
@testable import PortableMemory

/// Coverage expansion: the gaps the launch audit found untested (mirrors the Python
/// suite's `test_coverage_expansion.py`).
///
/// - ALL 15 record kinds round-trip (the base suite exercises only episode/entity/edge).
/// - Incremental (`--since`) semantics: delta-filtered kinds, chunks-follow-parent,
///   structural kinds always full, tombstones/audit since-filtered.
/// - Evidence Pack export; redact tombstones survive the wire with their op intact.
/// - The audit trail's export-only asymmetry is pinned as intended behavior.
///
/// Self-contained (own `FullStore`) so it merges cleanly next to every open PR.
final class CoverageTests: XCTestCase {

    static let tOld = Date(timeIntervalSince1970: 1_704_067_200)   // 2024-01-01Z
    static let tNew = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01Z
    static let cutoff = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01Z

    static func episode(_ id: String, _ ts: Date) -> PortableEpisode {
        PortableEpisode(id: id, eventTime: ts, mentionTime: ts, ingestionTime: ts,
                        sourceType: "note", sourceID: nil, actors: ["a"], summary: "s",
                        details: "d", sensitivity: "low", deletedAt: nil, metadata: ["k": "v"],
                        contextID: nil, categories: ["c"], importance: 0.5, confidence: 0.7,
                        lifecycleState: "HOT", extractionState: "done", lastAccessed: nil,
                        accessCount: 1, pinned: true, expirationDate: nil,
                        vaultRefs: ["vault_1"], speaker: nil)
    }

    /// A store holding one record of EVERY kind, keyed for merge-by-id/natural-key.
    actor FullStore: PortableMemoryStore {
        var episodes: [String: PortableEpisode] = [:]
        var entities: [String: PortableEntity] = [:]
        var edges: [String: PortableEdge] = [:]
        var facts: [String: PortableFact] = [:]
        var factLinks: [String: PortableFactLink] = [:]
        var episodeLinks: [String: PortableEpisodeLink] = [:]
        var resources: [String: PortableResource] = [:]
        var chunks: [String: PortableChunk] = [:]
        var cores: [String: PortableCore] = [:]
        var procedures: [String: PortableProcedure] = [:]
        var contexts: [String: PortableContext] = [:]
        var communities: [String: PortableCommunity] = [:]
        var categories: [String: PortableCategory] = [:]
        var preferences: [String: PortablePreference] = [:]
        var secretRefs: [String: PortableSecretRef] = [:]
        var tombstones: [Tombstone] = []
        var audit: [PortableAuditRecord] = []
        var appliedOps: [String] = []

        func seed(episodeTS: Date = CoverageTests.tNew, includeAudit: Bool = true) {
            let t = CoverageTests.tNew
            let e = CoverageTests.episode("ep_1", episodeTS)
            episodes[e.id] = e
            entities["ent_1"] = PortableEntity(id: "ent_1", type: "person", canonicalName: "Ada",
                                               aliases: ["A"], summary: "s", sensitivity: "low",
                                               updatedAt: t)
            edges["edge_1"] = PortableEdge(id: "edge_1", srcEntityID: "ent_1", dstEntityID: "ent_1",
                                           edgeType: "self", tValidFrom: t, tValidTo: nil,
                                           ingestionTime: t, confidence: 0.9,
                                           evidenceEpisodeIDs: ["ep_1"], supersededBy: nil)
            facts["fact_1"] = PortableFact(id: "fact_1", episodeID: "ep_1", subject: "Ada",
                                           predicate: "leads", object: "X", text: "Ada leads X",
                                           eventTime: nil, tValidFrom: t, tValidTo: nil,
                                           supersededBy: nil, confidence: 0.9, importance: 0.5,
                                           speaker: nil, reconciledAt: nil, lastReinforcedAt: nil,
                                           prunedAt: nil, createdAt: t)
            factLinks["fact_1|fact_1"] = PortableFactLink(srcFactID: "fact_1", dstFactID: "fact_1",
                                                          linkType: "refines", createdAt: t)
            episodeLinks["ep_1|ep_1"] = PortableEpisodeLink(srcEpisodeID: "ep_1", dstEpisodeID: "ep_1",
                                                            linkType: "related", weight: 0.5)
            resources["res_1"] = PortableResource(id: "res_1", uri: "file:///x",
                                                  mimeType: "text/plain", contentHash: "sha256:ab",
                                                  title: "t", summary: "s", created: t, modified: t)
            chunks["chunk_1"] = PortableChunk(id: "chunk_1", resourceID: "res_1", position: 0,
                                              text: "chunk text", sensitivity: "low",
                                              contextPrefix: nil)
            cores["human"] = PortableCore(id: "human", content: "profile", charBudget: 100, version: 1)
            procedures["proc_1"] = PortableProcedure(id: "proc_1", name: "n", triggerPattern: "p",
                                                     steps: ["a"], successCount: 1, failureCount: 0,
                                                     lastUsed: nil, enabled: true)
            contexts["ctx_1"] = PortableContext(id: "ctx_1", label: "l", parentID: nil,
                                                archived: false, createdAt: t)
            communities["com_1"] = PortableCommunity(id: "com_1", label: "l", summary: "s",
                                                     memberEntityIDs: ["ent_1"])
            categories["prefs"] = PortableCategory(name: "prefs", description: "d")
            preferences["theme"] = PortablePreference(key: "theme", value: "dark")
            secretRefs["sec_1"] = PortableSecretRef(id: "sec_1", label: "api key",
                                                    sensitivity: "high", category: "cred",
                                                    preview: "…last4",
                                                    encryptionMetadata: "aes-256-gcm",
                                                    createdAt: t, lastAccessed: nil)
            tombstones.append(Tombstone(id: "tomb_1", op: .delete, targetKind: "episode",
                                        targetID: "ep_gone", deletedAt: t, reason: "erasure",
                                        actor: "user", derived: DerivedRefs()))
            if includeAudit {
                audit.append(PortableAuditRecord(ts: t, actor: "user", op: "delete",
                                                 targetID: "ep_gone", reason: "erasure"))
            }
        }

        // Seed helpers for the incremental test.
        func seedOldRows() {
            episodes["ep_old"] = CoverageTests.episode("ep_old", CoverageTests.tOld)
            resources["res_old"] = PortableResource(id: "res_old", uri: "file:///old",
                                                    mimeType: "text/plain", contentHash: "sha256:cd",
                                                    title: "t", summary: "s",
                                                    created: CoverageTests.tOld,
                                                    modified: CoverageTests.tOld)
            chunks["chunk_old"] = PortableChunk(id: "chunk_old", resourceID: "res_old", position: 0,
                                                text: "old", sensitivity: "low", contextPrefix: nil)
            tombstones.insert(Tombstone(id: "tomb_old", op: .delete, targetKind: "episode",
                                        targetID: "ep_ancient", deletedAt: CoverageTests.tOld,
                                        reason: "old", actor: "user", derived: DerivedRefs()), at: 0)
            audit.insert(PortableAuditRecord(ts: CoverageTests.tOld, actor: "user", op: "delete",
                                             targetID: "ep_ancient", reason: "old"), at: 0)
        }
        func seedTombstone(_ t: Tombstone) { tombstones.append(t) }

        func storeInfo() -> StoreInfo { StoreInfo(generator: "coverage/1.0", schemaVersion: 1) }

        // Export readers
        func exportEpisodes() -> [PortableEpisode] { Array(episodes.values) }
        func exportEntities() -> [PortableEntity] { Array(entities.values) }
        func exportEdges() -> [PortableEdge] { Array(edges.values) }
        func exportFacts() -> [PortableFact] { Array(facts.values) }
        func exportFactLinks() -> [PortableFactLink] { Array(factLinks.values) }
        func exportEpisodeLinks() -> [PortableEpisodeLink] { Array(episodeLinks.values) }
        func exportResources() -> [PortableResource] { Array(resources.values) }
        func exportChunks() -> [PortableChunk] { Array(chunks.values) }
        func exportCoreBlocks() -> [PortableCore] { Array(cores.values) }
        func exportProcedures() -> [PortableProcedure] { Array(procedures.values) }
        func exportContexts() -> [PortableContext] { Array(contexts.values) }
        func exportCommunities() -> [PortableCommunity] { Array(communities.values) }
        func exportCategories() -> [PortableCategory] { Array(categories.values) }
        func exportPreferences() -> [PortablePreference] { Array(preferences.values) }
        func exportSecretRefs() -> [PortableSecretRef] { Array(secretRefs.values) }
        func exportTombstones(since: Date?) -> [Tombstone] {
            tombstones.filter { since == nil || $0.deletedAt >= since! }
        }
        func exportAuditLog(since: Date?) -> [PortableAuditRecord] {
            audit.filter { since == nil || $0.ts >= since! }
        }

        // Import writers
        func tombstonedTargetIDs() -> Set<String> { Set(tombstones.map(\.targetID)) }
        func applyTombstone(_ t: Tombstone) {
            appliedOps.append(t.op.rawValue)
            tombstones.append(t)
        }
        func importEpisode(_ e: PortableEpisode, ext: String?) { episodes[e.id] = e }
        func importEntity(_ e: PortableEntity) { entities[e.id] = e }
        func importEdge(_ e: PortableEdge) { edges[e.id] = e }
        func importFact(_ f: PortableFact) { facts[f.id] = f }
        func importFactLink(_ l: PortableFactLink) { factLinks["\(l.srcFactID)|\(l.dstFactID)"] = l }
        func importEpisodeLink(_ l: PortableEpisodeLink) { episodeLinks["\(l.srcEpisodeID)|\(l.dstEpisodeID)"] = l }
        func importResource(_ r: PortableResource) { resources[r.id] = r }
        func importChunk(_ c: PortableChunk) { chunks[c.id] = c }
        func importCoreBlock(_ c: PortableCore) { cores[c.id] = c }
        func importProcedure(_ p: PortableProcedure) { procedures[p.id] = p }
        func importContext(_ c: PortableContext) { contexts[c.id] = c }
        func importCommunity(_ c: PortableCommunity) { communities[c.id] = c }
        func importCategory(_ c: PortableCategory) { categories[c.name] = c }
        func importPreference(_ p: PortablePreference) { preferences[p.key] = p }
        func importSecretRef(_ r: PortableSecretRef) { secretRefs[r.id] = r }

        // Test seams
        func auditCount() -> Int { audit.count }
        func ops() -> [String] { appliedOps }
        func tombstoneByID(_ id: String) -> Tombstone? { tombstones.first { $0.id == id } }
    }

    private static let allKinds = ["episode", "entity", "edge", "fact", "factLink",
                                   "episodeLink", "resource", "chunk", "core", "procedure",
                                   "context", "community", "category", "preference", "secretRef"]

    private func tmpDir(_ tag: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-cov-\(tag)-\(UInt64.random(in: 0..<UInt64.max)).mem")
    }

    /// Bytes of every data file (items/ + audit/ + CHECKSUMS) — the equality oracle.
    private func dataFiles(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let fm = FileManager.default
        for sub in ["items", "audit"] {
            let d = dir.appendingPathComponent(sub)
            guard let entries = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) else { continue }
            for f in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                out["\(sub)/\(f.lastPathComponent)"] = try Data(contentsOf: f)
            }
        }
        out["CHECKSUMS"] = try Data(contentsOf: dir.appendingPathComponent("CHECKSUMS"))
        return out
    }

    func testAllFifteenKindsRoundTripByteIdentically() async throws {
        // No audit rows here: the audit trail is host-owned — written on export, never
        // imported into the store (pinned separately below).
        let src = FullStore()
        await src.seed(includeAudit: false)
        let d1 = tmpDir("rt1"); addTeardownBlock { try? FileManager.default.removeItem(at: d1) }
        let d2 = tmpDir("rt2"); addTeardownBlock { try? FileManager.default.removeItem(at: d2) }

        let m = try await BundleExporter().export(src, to: d1)
        for kind in Self.allKinds {
            XCTAssertEqual(m.counts[kind], 1, "\(kind) missing from manifest counts")
        }
        XCTAssertEqual(m.counts["tombstone"], 1)
        XCTAssertTrue(BundleValidator().validate(bundle: d1).ok)

        let dst = FullStore()
        let report = try await BundleImporter().importBundle(dst, from: d1)
        for kind in Self.allKinds {
            XCTAssertEqual(report.applied[kind], 1, "\(kind) not applied on import")
        }

        // The strongest equality check: the re-export is byte-identical.
        _ = try await BundleExporter().export(dst, to: d2)
        XCTAssertEqual(try dataFiles(d1), try dataFiles(d2))
    }

    func testAuditLogIsExportedButNotImportedIntoTheStore() async throws {
        let src = FullStore()
        await src.seed(includeAudit: true)
        let dir = tmpDir("audit"); addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let m = try await BundleExporter().export(src, to: dir)
        XCTAssertEqual(m.counts["audit"], 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audit/log.jsonl").path))
        let dst = FullStore()
        _ = try await BundleImporter().importBundle(dst, from: dir)
        let n = await dst.auditCount()
        XCTAssertEqual(n, 0, "the host owns its own mutation history")
    }

    func testIncrementalSinceSemantics() async throws {
        let src = FullStore()
        await src.seed(episodeTS: Self.tNew)
        await src.seedOldRows()
        let dir = tmpDir("inc"); addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let m = try await BundleExporter().export(src, to: dir, mode: .incremental, since: Self.cutoff)
        XCTAssertEqual(m.exportMode, .incremental)
        XCTAssertNotNil(m.since)

        func text(_ rel: String) throws -> String {
            try String(contentsOf: dir.appendingPathComponent(rel), encoding: .utf8)
        }
        let episodes = try text("items/episode.jsonl")
        XCTAssertTrue(episodes.contains(#""id":"ep_1""#)); XCTAssertFalse(episodes.contains("ep_old"))

        let resources = try text("items/resource.jsonl")
        XCTAssertTrue(resources.contains("res_1")); XCTAssertFalse(resources.contains("res_old"))
        // Chunks follow their parent resource into the delta.
        let chunks = try text("items/chunk.jsonl")
        XCTAssertTrue(chunks.contains("chunk_1")); XCTAssertFalse(chunks.contains("chunk_old"))

        // Structural kinds are ALWAYS full, even incremental.
        XCTAssertTrue(try text("items/entity.jsonl").contains("ent_1"))
        XCTAssertTrue(try text("items/edge.jsonl").contains("edge_1"))
        XCTAssertTrue(try text("items/preference.jsonl").contains("theme"))

        // Tombstones and audit are since-filtered.
        let tombs = try text("audit/tombstones.jsonl")
        XCTAssertTrue(tombs.contains("tomb_1")); XCTAssertFalse(tombs.contains("tomb_old"))
        let audit = try text("audit/log.jsonl")
        XCTAssertTrue(audit.contains(#""targetID":"ep_gone""#))
        XCTAssertEqual(audit.filter { $0 == "\n" }.count, 1)
    }

    func testEvidencePackExport() async throws {
        let src = FullStore()
        await src.seed()
        let dir = tmpDir("ep"); addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let m = try await BundleExporter().exportEvidencePack(src, to: dir)
        for rel in ["audit/log.jsonl", "audit/tombstones.jsonl", "provenance/edges.jsonl"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(rel).path),
                          "\(rel) missing from Evidence Pack")
        }
        XCTAssertTrue(m.capabilities.contains("evidence-pack"))
        XCTAssertTrue(m.capabilities.contains("proof-of-deletion"))
        XCTAssertEqual(m.counts["tombstone"], 1)
        XCTAssertEqual(m.counts["provenanceEdge"], 1)
        XCTAssertTrue(BundleValidator().validate(bundle: dir).ok)
    }

    func testRedactTombstoneSurvivesTheWireWithOpIntact() async throws {
        let src = FullStore()
        await src.seed()
        await src.seedTombstone(Tombstone(id: "tomb_r", op: .redact, targetKind: "episode",
                                          targetID: "ep_redact_me", deletedAt: Self.tNew,
                                          reason: "GDPR Art. 17", actor: "user",
                                          derived: DerivedRefs()))
        let dir = tmpDir("redact"); addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        _ = try await BundleExporter().export(src, to: dir)
        let tombs = try String(contentsOf: dir.appendingPathComponent("audit/tombstones.jsonl"),
                               encoding: .utf8)
        XCTAssertTrue(tombs.contains(#""op":"redact""#))

        let dst = FullStore()
        _ = try await BundleImporter().importBundle(dst, from: dir)
        // The receiver hook saw the redact op (content-purge semantics are the host's
        // obligation per spec §5 — this pins that the op arrives intact).
        let ops = await dst.ops()
        XCTAssertTrue(ops.contains("redact"))
        let redacted = await dst.tombstoneByID("tomb_r")
        XCTAssertEqual(redacted?.op, .redact)
    }
}
