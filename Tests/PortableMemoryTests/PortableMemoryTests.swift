import XCTest
@testable import PortableMemory

/// A minimal in-memory `PortableMemoryStore` so the format/protocol can be exercised
/// with zero infrastructure — this is also the shape an adopter implements.
actor InMemoryStore: PortableMemoryStore {
    var episodes: [String: PortableEpisode] = [:]
    var episodeExt: [String: String] = [:]
    var entities: [String: PortableEntity] = [:]
    var edges: [String: PortableEdge] = [:]
    var tombstones: [Tombstone] = []
    var tombstonedIDs: Set<String> = []
    var passthrough: [String: [String]] = [:]

    func storeInfo() -> StoreInfo {
        StoreInfo(generator: "test/1.0", schemaVersion: 1, embeddingModel: "test-embed", embeddingDim: 8)
    }
    func exportEpisodes() -> [PortableEpisode] { episodes.values.sorted { $0.id < $1.id } }
    func exportEpisodeExt() -> [String: String] { episodeExt }
    func exportEntities() -> [PortableEntity] { entities.values.sorted { $0.id < $1.id } }
    func exportEdges() -> [PortableEdge] { edges.values.sorted { $0.id < $1.id } }
    func exportTombstones(since: Date?) -> [Tombstone] {
        tombstones.filter { since == nil || $0.deletedAt >= since! }
    }
    func exportPassthroughKinds() -> [String] { passthrough.keys.sorted() }
    func exportPassthroughLines(kind: String) -> [String] { passthrough[kind] ?? [] }

    func tombstonedTargetIDs() -> Set<String> { tombstonedIDs }
    func applyTombstone(_ t: Tombstone) {
        episodes[t.targetID] = nil
        episodeExt[t.targetID] = nil
        tombstonedIDs.insert(t.targetID)
        tombstones.append(t)
    }
    func importEpisode(_ e: PortableEpisode, ext: String?) {
        episodes[e.id] = e
        episodeExt[e.id] = ext
    }
    func importEntity(_ e: PortableEntity) { entities[e.id] = e }
    func importEdge(_ e: PortableEdge) { edges[e.id] = e }
    func storePassthrough(kind: String, lines: [String]) { passthrough[kind] = lines }

    // Test seam helpers (plain actor methods — not protocol requirements)
    func seedEpisode(_ e: PortableEpisode, ext: String? = nil) { episodes[e.id] = e; episodeExt[e.id] = ext }
    func seedEntity(_ e: PortableEntity) { entities[e.id] = e }
    func seedEdge(_ e: PortableEdge) { edges[e.id] = e }
    func seedTombstone(_ t: Tombstone) { applyTombstone(t) }
    func seedPassthrough(_ kind: String, _ lines: [String]) { passthrough[kind] = lines }
    func episodeCount() -> Int { episodes.count }
    func episodeIDs() -> [String] { episodes.keys.sorted() }
    func summaryFor(_ id: String) -> String? { episodes[id]?.summary }
    func extFor(_ id: String) -> String? { episodeExt[id] }
    func passthroughFor(_ kind: String) -> [String] { passthrough[kind] ?? [] }
}

func ep(_ id: String, _ summary: String) -> PortableEpisode {
    PortableEpisode(id: id, eventTime: Date(timeIntervalSince1970: 1_700_000_000),
                    mentionTime: Date(timeIntervalSince1970: 1_700_000_000),
                    ingestionTime: Date(timeIntervalSince1970: 1_700_000_000),
                    sourceType: "note", sourceID: nil, actors: [], summary: summary,
                    details: summary, sensitivity: "low", deletedAt: nil, metadata: [:],
                    contextID: nil, categories: [], importance: 0.5, confidence: 0.7,
                    lifecycleState: "HOT", extractionState: "done", lastAccessed: nil,
                    accessCount: 0, pinned: false, expirationDate: nil, vaultRefs: [], speaker: nil)
}

final class PortableMemoryTests: XCTestCase {
    private func tmpDir(_ tag: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-\(tag)-\(UInt64.random(in: 0..<UInt64.max)).mem")
    }

    func testRoundTripLosslessAndIdempotent() async throws {
        let a = InMemoryStore()
        await a.seedEpisode(ep("ep_a", "alpha"))
        await a.seedEpisode(ep("ep_b", "beta"))
        await a.seedEntity(PortableEntity(id: "ent_1", type: "person", canonicalName: "Sarah",
                                          aliases: [], summary: "", sensitivity: "low", updatedAt: Date()))
        await a.seedEdge(PortableEdge(id: "edge_1", srcEntityID: "ent_1", dstEntityID: "ent_1",
                                      edgeType: "self", tValidFrom: Date(), tValidTo: nil,
                                      ingestionTime: Date(), confidence: 0.9,
                                      evidenceEpisodeIDs: ["ep_a"], supersededBy: nil))

        let dir = tmpDir("rt"); addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let m = try await BundleExporter().export(a, to: dir)
        XCTAssertEqual(m.counts[MemKind.episode.rawValue], 2)
        XCTAssertEqual(m.counts[MemKind.entity.rawValue], 1)
        XCTAssertEqual(m.counts[MemKind.edge.rawValue], 1)

        let c = InMemoryStore()
        let r = try await BundleImporter().importBundle(c, from: dir)
        XCTAssertEqual(r.applied[MemKind.episode.rawValue], 2)
        let n1 = await c.episodeCount(); XCTAssertEqual(n1, 2)
        let s = await c.summaryFor("ep_a")
        XCTAssertEqual(s, "alpha")

        _ = try await BundleImporter().importBundle(c, from: dir)
        let n2 = await c.episodeCount(); XCTAssertEqual(n2, 2, "re-import is a no-op")
    }

    func testTombstoneFirstNoResurrection() async throws {
        let a = InMemoryStore()
        await a.seedEpisode(ep("ep_x", "secret"))
        await a.seedEpisode(ep("ep_y", "ordinary"))
        let bundleAll = tmpDir("all"); addTeardownBlock { try? FileManager.default.removeItem(at: bundleAll) }
        _ = try await BundleExporter().export(a, to: bundleAll)

        await a.seedTombstone(Tombstone(id: "tomb_1", op: .delete, targetKind: "episode",
                                        targetID: "ep_x", deletedAt: Date(), reason: "erasure",
                                        actor: "user", derived: DerivedRefs()))
        let bundleDel = tmpDir("del"); addTeardownBlock { try? FileManager.default.removeItem(at: bundleDel) }
        let dm = try await BundleExporter().export(a, to: bundleDel)
        XCTAssertEqual(dm.counts["tombstone"], 1)

        let d = InMemoryStore()
        _ = try await BundleImporter().importBundle(d, from: bundleDel)   // tombstone for X first
        let r = try await BundleImporter().importBundle(d, from: bundleAll) // bundle still HAS X
        XCTAssertGreaterThanOrEqual(r.skippedTombstoned, 1, "X refused — tombstone wins")
        let ids = await d.episodeIDs()
        XCTAssertFalse(ids.contains("ep_x"), "X never resurrected")
        XCTAssertTrue(ids.contains("ep_y"))
    }

    func testForeignFieldsRoundTripViaExt() async throws {
        let a = InMemoryStore()
        await a.seedEpisode(ep("ep_e", "s"), ext: #"{"vendorScore":0.91,"vendorTag":"alpha"}"#)
        let dir = tmpDir("ext"); addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        _ = try await BundleExporter().export(a, to: dir)
        let line = try String(contentsOf: dir.appendingPathComponent("items/episode.jsonl"), encoding: .utf8)
        XCTAssertTrue(line.contains("vendorScore"))

        let c = InMemoryStore()
        _ = try await BundleImporter().importBundle(c, from: dir)
        let ext = await c.extFor("ep_e")
        XCTAssertTrue(ext?.contains("vendorTag") == true, "foreign field persisted")

        let dir2 = tmpDir("ext2"); addTeardownBlock { try? FileManager.default.removeItem(at: dir2) }
        _ = try await BundleExporter().export(c, to: dir2)
        let line2 = try String(contentsOf: dir2.appendingPathComponent("items/episode.jsonl"), encoding: .utf8)
        XCTAssertTrue(line2.contains("vendorScore"), "foreign field re-emitted")
    }

    func testUnknownKindRoundTripsVerbatim() async throws {
        let a = InMemoryStore()
        await a.seedEpisode(ep("ep_k", "x"))
        // Include a whitespace-padded line to prove passthrough preserves content
        // verbatim (no trimming).
        let foreign = [#"{"id":"vt_1","blob":"opaque"}"#, #"   {"id":"vt_2","pad":true}   "#]
        await a.seedPassthrough("vendorThing", foreign)
        let dir = tmpDir("uk"); addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let m = try await BundleExporter().export(a, to: dir)
        XCTAssertEqual(m.counts["vendorThing"], 2)

        let c = InMemoryStore()
        _ = try await BundleImporter().importBundle(c, from: dir)
        let lines = await c.passthroughFor("vendorThing")
        XCTAssertEqual(lines, foreign, "unknown kind preserved verbatim, incl. surrounding whitespace")
    }

    func testRejectsManifestPathTraversal() async throws {
        let a = InMemoryStore()
        await a.seedEpisode(ep("ep_p", "p"))
        let dir = tmpDir("trav"); addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        _ = try await BundleExporter().export(a, to: dir)

        // Tamper the manifest to declare a file path that escapes the bundle directory.
        let manifestURL = dir.appendingPathComponent("manifest.json")
        var m = try MemCodec.decoder.decode(MemManifest.self, from: Data(contentsOf: manifestURL))
        m.files.append(MemFileEntry(path: "../../../../etc/passwd",
                                    sha256: String(repeating: "0", count: 64), bytes: 0))
        try MemCodec.encoder.encode(m).write(to: manifestURL)

        XCTAssertFalse(BundleValidator().validate(bundle: dir).ok, "validator flags the escaping path")
        let c = InMemoryStore()
        do {
            _ = try await BundleImporter().importBundle(c, from: dir)
            XCTFail("import must refuse a manifest whose path escapes the bundle")
        } catch { /* expected */ }
    }

    func testValidatorDetectsTamper() async throws {
        let a = InMemoryStore()
        await a.seedEpisode(ep("ep_v", "z"))
        let dir = tmpDir("val"); addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        _ = try await BundleExporter().export(a, to: dir)
        XCTAssertTrue(BundleValidator().validate(bundle: dir).ok, "freshly exported bundle is valid")

        try Data(#"{"id":"ep_tampered"}"#.utf8).write(to: dir.appendingPathComponent("items/episode.jsonl"))
        XCTAssertFalse(BundleValidator().validate(bundle: dir).ok, "tamper detected")

        let c = InMemoryStore()
        do {
            _ = try await BundleImporter().importBundle(c, from: dir)
            XCTFail("import should reject a tampered bundle")
        } catch { /* expected */ }
    }

    func testMem0AdapterMapsExportLosslessly() throws {
        let json = """
        {"results":[
          {"id":"m1","memory":"User prefers dark mode","user_id":"ivan",
           "categories":["preferences"],"created_at":"2026-05-01T10:00:00.000Z","metadata":{"app":"editor"}},
          {"id":"m2","memory":"Assistant scheduled the demo","role":"assistant",
           "agent_id":"asst","run_id":"sess7","created_at":"2026-05-02T12:00:00Z"}
        ]}
        """
        let eps = try Mem0Adapter.parseEpisodes(Data(json.utf8))
        XCTAssertEqual(eps.count, 2)
        XCTAssertEqual(eps[0].details, "User prefers dark mode")
        XCTAssertEqual(eps[0].sourceType, "text")
        XCTAssertTrue(eps[0].actors.contains("ivan"))
        XCTAssertEqual(eps[0].categories, ["preferences"])
        XCTAssertEqual(eps[0].metadata["mem0_id"], "m1")
        XCTAssertEqual(eps[0].metadata["app"], "editor")
        XCTAssertEqual(eps[1].speaker, "assistant")
        XCTAssertEqual(eps[1].sourceType, "chat")
        XCTAssertEqual(eps[1].contextID, "sess7")
    }
}
