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
        // A tombstone is kind-agnostic here: remove the target from whichever collection
        // holds it, and record the id so a later merge can't resurrect it.
        episodes[t.targetID] = nil
        episodeExt[t.targetID] = nil
        entities[t.targetID] = nil
        edges[t.targetID] = nil
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
    func entityIDs() -> [String] { entities.keys.sorted() }
    func edgeIDs() -> [String] { edges.keys.sorted() }
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

    /// L2 must hold for EVERY kind, not just episodes: a tombstoned entity/edge (by its
    /// own id, or via an endpoint) must not be resurrected by a stale bundle re-import.
    func testTombstoneNonEpisodeKindsNotResurrected() async throws {
        let a = InMemoryStore()
        await a.seedEntity(PortableEntity(id: "ent_keep", type: "person", canonicalName: "Keep",
                                          aliases: [], summary: "", sensitivity: "low", updatedAt: Date()))
        await a.seedEntity(PortableEntity(id: "ent_kill", type: "person", canonicalName: "Kill",
                                          aliases: [], summary: "", sensitivity: "low", updatedAt: Date()))
        // edge_self references only ent_keep; edge_dep references the doomed ent_kill.
        await a.seedEdge(PortableEdge(id: "edge_self", srcEntityID: "ent_keep", dstEntityID: "ent_keep",
                                      edgeType: "self", tValidFrom: Date(), tValidTo: nil, ingestionTime: Date(),
                                      confidence: 0.9, evidenceEpisodeIDs: [], supersededBy: nil))
        await a.seedEdge(PortableEdge(id: "edge_dep", srcEntityID: "ent_keep", dstEntityID: "ent_kill",
                                      edgeType: "knows", tValidFrom: Date(), tValidTo: nil, ingestionTime: Date(),
                                      confidence: 0.9, evidenceEpisodeIDs: [], supersededBy: nil))
        await a.seedEdge(PortableEdge(id: "edge_kill", srcEntityID: "ent_keep", dstEntityID: "ent_keep",
                                      edgeType: "self", tValidFrom: Date(), tValidTo: nil, ingestionTime: Date(),
                                      confidence: 0.9, evidenceEpisodeIDs: [], supersededBy: nil))

        let bundleAll = tmpDir("ne-all"); addTeardownBlock { try? FileManager.default.removeItem(at: bundleAll) }
        _ = try await BundleExporter().export(a, to: bundleAll)   // captured while everything exists

        // Delete an entity (ent_kill) and an edge by its own id (edge_kill).
        await a.seedTombstone(Tombstone(id: "tb_ent", op: .delete, targetKind: "entity",
                                        targetID: "ent_kill", deletedAt: Date(), reason: "erasure",
                                        actor: "user", derived: DerivedRefs()))
        await a.seedTombstone(Tombstone(id: "tb_edge", op: .delete, targetKind: "edge",
                                        targetID: "edge_kill", deletedAt: Date(), reason: "erasure",
                                        actor: "user", derived: DerivedRefs()))
        let bundleDel = tmpDir("ne-del"); addTeardownBlock { try? FileManager.default.removeItem(at: bundleDel) }
        _ = try await BundleExporter().export(a, to: bundleDel)

        let d = InMemoryStore()
        _ = try await BundleImporter().importBundle(d, from: bundleDel)     // tombstones first
        let r = try await BundleImporter().importBundle(d, from: bundleAll) // stale bundle STILL ships the rows

        let ents = await d.entityIDs()
        XCTAssertEqual(ents, ["ent_keep"], "tombstoned entity must not be resurrected")
        let edges = await d.edgeIDs()
        XCTAssertFalse(edges.contains("edge_kill"), "edge tombstoned by id must not be resurrected")
        XCTAssertFalse(edges.contains("edge_dep"), "edge whose endpoint entity was deleted must not be resurrected")
        XCTAssertTrue(edges.contains("edge_self"), "unrelated edge survives")
        XCTAssertGreaterThanOrEqual(r.skippedTombstoned, 3, "ent_kill + edge_kill + edge_dep all refused")
    }

    /// Foreign (`ext`) fields must serialize with the SAME canonical number form as
    /// native fields — shortest round-trip (`0.7`), never full IEEE-754
    /// (`0.69999999999999996`) — or cross-implementation checksums break (spec §1).
    func testExtNumbersUseCanonicalShortestForm() async throws {
        let a = InMemoryStore()
        // confidence is 0.7 natively (see `ep`); add a foreign float + int + bool.
        await a.seedEpisode(ep("ep_n", "s"), ext: #"{"vendorScore":0.92,"vendorCount":3,"vendorFlag":true}"#)
        let dir = tmpDir("num"); addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        _ = try await BundleExporter().export(a, to: dir)
        let line = try String(contentsOf: dir.appendingPathComponent("items/episode.jsonl"), encoding: .utf8)
        XCTAssertTrue(line.contains(#""confidence":0.7"#), "native float stays shortest form")
        XCTAssertTrue(line.contains(#""vendorScore":0.92"#), "foreign float stays shortest form")
        XCTAssertTrue(line.contains(#""vendorCount":3"#), "foreign int stays an int")
        XCTAssertTrue(line.contains(#""vendorFlag":true"#), "foreign bool stays a bool")
        XCTAssertFalse(line.contains("9999999"), "no IEEE-754 precision leak")
        XCTAssertFalse(line.contains("0000000"), "no IEEE-754 precision leak")

        // Re-export must be byte-identical (determinism / idempotent round-trip).
        let c = InMemoryStore()
        _ = try await BundleImporter().importBundle(c, from: dir)
        let dir2 = tmpDir("num2"); addTeardownBlock { try? FileManager.default.removeItem(at: dir2) }
        _ = try await BundleExporter().export(c, to: dir2)
        let line2 = try String(contentsOf: dir2.appendingPathComponent("items/episode.jsonl"), encoding: .utf8)
        XCTAssertEqual(line, line2, "ext round-trip is byte-identical")
    }

    /// The shipped conformance fixture must stay valid (checksums, byte counts, no
    /// unlisted files, known-kind decodability) — guards against fixture drift.
    func testConformanceFixtureValidates() throws {
        // Package root is three levels up from this source file.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("Conformance/fixtures/sample.mem")
        let res = BundleValidator().validate(bundle: fixture)
        XCTAssertTrue(res.ok, "shipped conformance fixture must validate: \(res.issues)")
    }

    func testManifestSigningVerifiesAndRejectsUntrusted() async throws {
        let a = InMemoryStore()
        await a.seedEpisode(ep("ep_sig", "s"))
        let key = PortableSigningKey()
        let other = PortableSigningKey()
        let dir = tmpDir("sig"); addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        _ = try await BundleExporter().export(a, to: dir, signingKey: key)

        // A signature file is written and the manifest advertises the capability.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.sig").path))

        // Validate/import with the correct trusted key succeeds.
        XCTAssertTrue(BundleValidator().validate(bundle: dir, trustedKeys: [key.verifyingKey]).ok)
        let c = InMemoryStore()
        _ = try await BundleImporter().importBundle(c, from: dir, trustedKeys: [key.verifyingKey])
        let n = await c.episodeCount(); XCTAssertEqual(n, 1)

        // A different (untrusted) key is rejected by both validator and importer.
        XCTAssertFalse(BundleValidator().validate(bundle: dir, trustedKeys: [other.verifyingKey]).ok)
        let d = InMemoryStore()
        do {
            _ = try await BundleImporter().importBundle(d, from: dir, trustedKeys: [other.verifyingKey])
            XCTFail("import must reject a manifest not signed by a trusted key")
        } catch { /* expected */ }

        // No trusted keys → signature is not required (back-compat).
        XCTAssertTrue(BundleValidator().validate(bundle: dir).ok)
    }

    func testManifestSignatureRejectsManifestTamper() async throws {
        let a = InMemoryStore()
        await a.seedEpisode(ep("ep_t", "s"))
        let key = PortableSigningKey()
        let dir = tmpDir("sigt"); addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        _ = try await BundleExporter().export(a, to: dir, signingKey: key)

        // Rewrite manifest.json bytes (trailing space keeps it valid JSON but breaks the
        // signature over the original bytes).
        let mURL = dir.appendingPathComponent("manifest.json")
        var m = try Data(contentsOf: mURL); m.append(0x20)
        try m.write(to: mURL)

        let res = BundleValidator().validate(bundle: dir, trustedKeys: [key.verifyingKey])
        XCTAssertFalse(res.ok, "a tampered manifest must fail signature verification")
        XCTAssertTrue(res.issues.contains { $0.contains("signature") })
    }

    func testTombstoneSignatureRoundTrip() throws {
        let key = PortableSigningKey()
        let other = PortableSigningKey()
        let t = Tombstone(id: "tb_s", op: .delete, targetKind: "episode", targetID: "ep_z",
                          deletedAt: Date(timeIntervalSince1970: 1_700_000_000), reason: "erasure",
                          actor: "user", derived: DerivedRefs())
        let signed = try t.signed(by: key)
        XCTAssertNotNil(signed.signature)
        XCTAssertTrue(signed.signatureIsValid(trusted: [key.verifyingKey]))
        XCTAssertFalse(signed.signatureIsValid(trusted: [other.verifyingKey]), "untrusted key rejected")

        var tampered = signed; tampered.targetID = "ep_other"
        XCTAssertFalse(tampered.signatureIsValid(trusted: [key.verifyingKey]), "altered tombstone fails")
        XCTAssertFalse(t.signatureIsValid(trusted: [key.verifyingKey]), "unsigned tombstone is not valid")
    }

    func testLenientDateDecodeAcceptsFractionalSeconds() throws {
        // A foreign bundle may emit fractional seconds; the reader must accept them
        // (canonical OUTPUT stays whole-second — spec §1.1).
        let whole = try MemCodec.encoder.encode(ep("ep_d", "s"))
        let asString = String(decoding: whole, as: UTF8.self)
        let withFraction = asString.replacingOccurrences(of: ":20Z", with: ":20.500Z")
        let decoded = try MemCodec.decoder.decode(PortableEpisode.self, from: Data(withFraction.utf8))
        XCTAssertEqual(decoded.id, "ep_d")
        // Re-encoding normalizes back to whole-second canonical form.
        let reencoded = String(decoding: try MemCodec.encoder.encode(decoded), as: UTF8.self)
        XCTAssertFalse(reencoded.contains(".500"), "canonical output is whole-second")
    }

    func testSymlinkEscapeIsRejected() async throws {
        let a = InMemoryStore()
        await a.seedEpisode(ep("ep_l", "s"))
        let dir = tmpDir("sym"); addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        _ = try await BundleExporter().export(a, to: dir)

        // Place the SAME bytes outside the bundle, then replace the listed file with a
        // symlink pointing at them. Checksums would pass (same bytes) — only the symlink
        // guard should stop it.
        let epURL = dir.appendingPathComponent("items/episode.jsonl")
        let payload = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("payload-\(UInt64.random(in: 0..<UInt64.max)).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: payload) }
        try FileManager.default.copyItem(at: epURL, to: payload)
        try FileManager.default.removeItem(at: epURL)
        try FileManager.default.createSymbolicLink(at: epURL, withDestinationURL: payload)

        XCTAssertFalse(BundleValidator().validate(bundle: dir).ok, "symlinked/escaping file rejected")
        let c = InMemoryStore()
        do {
            _ = try await BundleImporter().importBundle(c, from: dir)
            XCTFail("import must refuse a symlinked bundle file")
        } catch { /* expected */ }
    }

    func testFileSizeBoundRejectsOversizeFile() async throws {
        let a = InMemoryStore()
        await a.seedEpisode(ep("ep_big", "s"))
        let dir = tmpDir("big"); addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        _ = try await BundleExporter().export(a, to: dir)

        let saved = MemLimits.maxFileBytes
        addTeardownBlock { MemLimits.maxFileBytes = saved }
        MemLimits.maxFileBytes = 4   // any real file exceeds this

        XCTAssertFalse(BundleValidator().validate(bundle: dir).ok, "oversize files flagged")
        let c = InMemoryStore()
        do {
            _ = try await BundleImporter().importBundle(c, from: dir)
            XCTFail("import must refuse a file over the size limit")
        } catch { /* expected */ }
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

    func testReExportClearsStaleFiles() async throws {
        let a = InMemoryStore()
        await a.seedEpisode(ep("ep_s", "s"))
        let dir = tmpDir("stale"); addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        _ = try await BundleExporter().export(a, to: dir)
        // Plant a stale item file as if left by a prior, larger export.
        let stale = dir.appendingPathComponent("items/episode_OLD.jsonl")
        try Data("{}\n".utf8).write(to: stale)
        // Re-export to the same directory — the stale file must be gone and the bundle
        // must validate clean (no "present but not listed").
        _ = try await BundleExporter().export(a, to: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "stale file cleared on re-export")
        XCTAssertTrue(BundleValidator().validate(bundle: dir).ok, "re-exported bundle is valid")
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
