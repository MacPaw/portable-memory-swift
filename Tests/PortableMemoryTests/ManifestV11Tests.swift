import XCTest
@testable import PortableMemory

/// Format 1.1 manifest fields — `specURL`, `coverage`, `scopes`, `bundleDigest` (spec §3.1)
/// — plus backward compatibility with the shipped 1.0 fixtures. Mirrors
/// `tests/test_manifest_v11.py`.
final class ManifestV11Tests: XCTestCase {
    private let fixed = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z
    /// sha256 of the CHECKSUMS file of the transfer-fixture bundle — identical in the Python suite.
    private let parityDigest = "1f7f0cdce93ef223537e6106b4713af03ff725e5ec07ab984cc805f719d6e401"

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func sampleEpisodes() throws -> [PortableEpisode] {
        let text = try String(contentsOf: root.appendingPathComponent("Conformance/fixtures/transfer/sample-export.txt"), encoding: .utf8)
        return TransferTextAdapter.parseEpisodes(text, source: "chatgpt", now: fixed)
    }
    private func tmp(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("m11-\(name)-\(UUID().uuidString).mem")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d)
    }
    private func onDisk(_ dir: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("manifest.json"))) as! [String: Any]
    }

    /// The smallest store that can carry contexts (the shared test `InMemoryStore` has none).
    actor ScopedStore: PortableMemoryStore {
        var episodes: [PortableEpisode] = []
        var contexts: [PortableContext] = []
        func storeInfo() async throws -> StoreInfo { StoreInfo(generator: "test/1.0") }
        func exportEpisodes() async throws -> [PortableEpisode] { episodes.sorted { $0.id < $1.id } }
        func exportContexts() async throws -> [PortableContext] { contexts }
        func add(_ e: PortableEpisode) { episodes.append(e) }
        func add(_ c: PortableContext) { contexts.append(c) }
    }

    func testManifestCarriesFormat11Fields() async throws {
        let store = InMemoryStore()
        for e in try sampleEpisodes() { await store.seedEpisode(e) }
        let dir = tmp("fields")
        let m = try await BundleExporter().export(store, to: dir)
        XCTAssertEqual(m.format, "1.1.0"); XCTAssertEqual(MemFormat.version, "1.1.0")
        XCTAssertEqual(m.specURL, MemFormat.specURL)
        // coverage = earliest/latest eventTime: undated entries take `now`; the latest dated entry is [2026-03-01].
        XCTAssertEqual(m.coverage?.from, fixed)
        XCTAssertEqual(m.coverage.map { iso($0.to) }, "2026-03-01T00:00:00Z")
        XCTAssertNil(m.scopes)                                          // transfer entries reference no scopes
        let checksums = try Data(contentsOf: dir.appendingPathComponent("CHECKSUMS"))
        XCTAssertEqual(m.bundleDigest, Hashing.sha256Hex(checksums))
        XCTAssertEqual(m.bundleDigest, parityDigest)

        let json = try onDisk(dir)
        XCTAssertEqual(json["format"] as? String, "1.1.0"); XCTAssertEqual(json["specURL"] as? String, MemFormat.specURL)
        XCTAssertEqual(json["coverage"] as? [String: String], ["from": "2023-11-14T22:13:20Z", "to": "2026-03-01T00:00:00Z"])
        XCTAssertNil(json["scopes"])                                    // absent optional fields are omitted, never null
        XCTAssertEqual(json["bundleDigest"] as? String, m.bundleDigest)
        XCTAssertTrue(BundleValidator().validate(bundle: dir).ok)
        let back = try MemCodec.decoder.decode(MemManifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertEqual(back.coverage.map { iso($0.to) }, "2026-03-01T00:00:00Z")   // round-trips through the codec
    }

    func testScopesEnumerateContextIDsSortedAndUnique() async throws {
        let store = ScopedStore()
        for (i, ctx) in ["ctx_team", "ctx_personal", "ctx_team", nil, ""].enumerated() {
            var e = TransferTextAdapter.parseEpisodes("[2026-01-0\(i + 1)] - m\(i)", now: fixed)[0]
            e.contextID = ctx
            await store.add(e)
        }
        await store.add(PortableContext(id: "ctx_org", label: "Org", parentID: nil, archived: false, createdAt: fixed))
        let dir = tmp("scopes")
        let m = try await BundleExporter().export(store, to: dir)
        XCTAssertEqual(m.scopes, ["ctx_org", "ctx_personal", "ctx_team"])   // sorted, de-duplicated, empty/nil skipped
        XCTAssertEqual(m.coverage.map { iso($0.from) }, "2026-01-01T00:00:00Z")
        XCTAssertEqual(m.coverage.map { iso($0.to) }, "2026-01-05T00:00:00Z")
        XCTAssertEqual(try onDisk(dir)["scopes"] as? [String], m.scopes)
    }

    func testIncrementalCoverageDescribesOnlyTheBundle() async throws {
        let store = InMemoryStore()
        var eps = TransferTextAdapter.parseEpisodes("[2024-01-01] - old\n[2026-06-01] - new\n", now: fixed)
        eps[0].ingestionTime = Date(timeIntervalSince1970: 1_704_153_600)   // 2024-01-02
        eps[1].ingestionTime = Date(timeIntervalSince1970: 1_780_444_800)   // 2026-06-02
        for e in eps { await store.seedEpisode(e) }
        let dir = tmp("incr")
        let m = try await BundleExporter().export(store, to: dir, mode: .incremental, since: Date(timeIntervalSince1970: 1_735_689_600)) // 2025-01-01
        XCTAssertEqual(m.counts["episode"], 1)
        XCTAssertEqual(m.coverage.map { iso($0.from) }, "2026-06-01T00:00:00Z")
        XCTAssertEqual(m.coverage.map { iso($0.to) }, "2026-06-01T00:00:00Z")
    }

    func testEmptyBundleOmitsCoverageAndScopesButHasDigest() async throws {
        let dir = tmp("empty")
        let m = try await BundleExporter().export(InMemoryStore(), to: dir)
        XCTAssertNil(m.coverage); XCTAssertNil(m.scopes)
        XCTAssertEqual(m.bundleDigest, Hashing.sha256Hex(try Data(contentsOf: dir.appendingPathComponent("CHECKSUMS"))))
        XCTAssertTrue(BundleValidator().validate(bundle: dir).ok)
    }

    func testValidatorVerifiesBundleDigest() async throws {
        let store = InMemoryStore()
        for e in try sampleEpisodes() { await store.seedEpisode(e) }
        let dir = tmp("tamper")
        _ = try await BundleExporter().export(store, to: dir)
        let cURL = dir.appendingPathComponent("CHECKSUMS")
        var data = try Data(contentsOf: cURL)
        data.append(contentsOf: Array((String(repeating: "0", count: 64) + "  items/evil.jsonl\n").utf8))   // smuggled line
        try data.write(to: cURL)
        XCTAssertTrue(BundleValidator().validate(bundle: dir).issues.contains { $0.contains("bundleDigest mismatch") })

        _ = try await BundleExporter().export(store, to: dir)
        let mURL = dir.appendingPathComponent("manifest.json")
        var m = try MemCodec.decoder.decode(MemManifest.self, from: Data(contentsOf: mURL))
        m.bundleDigest = String(repeating: "f", count: 64)                 // manifest claims a digest that isn't true
        try MemCodec.encoder.encode(m).write(to: mURL)
        XCTAssertTrue(BundleValidator().validate(bundle: dir).issues.contains { $0.contains("bundleDigest mismatch") })

        _ = try await BundleExporter().export(store, to: dir)
        try FileManager.default.removeItem(at: cURL)
        XCTAssertTrue(BundleValidator().validate(bundle: dir).issues.contains { $0.contains("CHECKSUMS is missing") })
    }

    /// The shipped 1.0.0 fixtures have none of the 1.1 fields — a 1.1 reader must accept them.
    func test10BundlesRemainValidAndImportable() async throws {
        let fixture = root.appendingPathComponent("Conformance/fixtures/sample.mem")
        let res = BundleValidator().validate(bundle: fixture)
        XCTAssertTrue(res.ok, "\(res.issues)")
        XCTAssertTrue(res.manifest?.format.hasPrefix("1.0") ?? false)
        XCTAssertNil(res.manifest?.specURL); XCTAssertNil(res.manifest?.coverage)
        XCTAssertNil(res.manifest?.scopes); XCTAssertNil(res.manifest?.bundleDigest)
        let store = InMemoryStore()
        _ = try await BundleImporter().importBundle(store, from: fixture)
        let n = await store.episodeCount()
        XCTAssertGreaterThan(n, 0)
    }
}
