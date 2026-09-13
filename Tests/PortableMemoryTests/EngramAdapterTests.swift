import XCTest
@testable import PortableMemory

/// Engram (PLUR) adapter + the YAML-subset reader — mapping rules, losslessness, rendering,
/// robustness, and the shared cross-SDK fixture (`Conformance/fixtures/engram/`). Mirrors
/// the Python suites (`tests/test_adapter_engram.py`, `tests/test_yaml_subset.py`,
/// `tests/test_fuzz_robustness.py`).
final class EngramAdapterTests: XCTestCase {
    private let fixed = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z

    private var fixtureDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Conformance/fixtures/engram")
    }

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: fixtureDir.appendingPathComponent(name), encoding: .utf8)
    }

    private func parse(_ text: String) -> [PortableEpisode] { EngramAdapter.parseEpisodes(text, now: fixed) }

    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    // MARK: - YAML subset

    func testYAMLScalarsCoreSchemaTyping() {
        guard case .object(let doc) = YAMLSubset.load(
            "a: 5\nb: -7\nc: +3\nd: 0.85\ne: 1.0\nf: 1e3\ng: true\nh: False\ni: null\nj: ~\nk:\n"
            + "l: 2026-01-30\nm: 12:30\nn: 0x1F\no: yes\np: 1.\nq: .5\nr: \"7\"\ns: '0.5'\n") else { return XCTFail("not a mapping") }
        XCTAssertEqual(doc["a"], .int(5)); XCTAssertEqual(doc["b"], .int(-7)); XCTAssertEqual(doc["c"], .int(3))
        XCTAssertEqual(doc["d"], .double(0.85)); XCTAssertEqual(doc["e"], .double(1.0)); XCTAssertEqual(doc["f"], .double(1000))
        XCTAssertEqual(doc["g"], .bool(true)); XCTAssertEqual(doc["h"], .bool(false))
        XCTAssertEqual(doc["i"], .null); XCTAssertEqual(doc["j"], .null); XCTAssertEqual(doc["k"], .null)
        XCTAssertEqual(doc["l"], .string("2026-01-30"))                       // dates stay strings
        XCTAssertEqual(doc["m"], .string("12:30")); XCTAssertEqual(doc["n"], .string("0x1F")); XCTAssertEqual(doc["o"], .string("yes"))
        XCTAssertEqual(doc["p"], .string("1.")); XCTAssertEqual(doc["q"], .string(".5"))
        XCTAssertEqual(doc["r"], .string("7")); XCTAssertEqual(doc["s"], .string("0.5"))
    }

    func testYAMLQuotesBlocksFlowsCommentsDocuments() {
        guard case .object(let q) = YAMLSubset.load(
            "a: \"line\\nbreak \\\"q\\\" \\u00e9 \\\\ end\"\nb: 'it''s # not a comment'\nc: \"has: colon\" # comment\nd: don't stop  # apostrophe\n") else { return XCTFail() }
        XCTAssertEqual(q["a"], .string("line\nbreak \"q\" é \\ end"))
        XCTAssertEqual(q["b"], .string("it's # not a comment"))
        XCTAssertEqual(q["c"], .string("has: colon")); XCTAssertEqual(q["d"], .string("don't stop"))

        guard case .object(let b) = YAMLSubset.load(
            "lit: |\n  one\n  two\n\nlit_strip: |-\n  a\n  b\n\n\nlit_keep: |+\n  a\n\n\nfold: >\n  one\n  two\n\n  three\nfold_strip: >-\n  x\n  y\nafter: 1\n") else { return XCTFail() }
        XCTAssertEqual(b["lit"], .string("one\ntwo\n")); XCTAssertEqual(b["lit_strip"], .string("a\nb"))
        XCTAssertEqual(b["lit_keep"], .string("a\n\n\n")); XCTAssertEqual(b["fold"], .string("one two\nthree\n"))
        XCTAssertEqual(b["fold_strip"], .string("x y")); XCTAssertEqual(b["after"], .int(1))

        guard case .object(let f) = YAMLSubset.load(
            "a: {positive: 3, negative: 0, neutral: 2}\nb: [\"x, y\", 'z', 4, true, null]\nc: [\n  1,\n  2,\n]\nd: {k: [1, {n: 2}], e: }\n") else { return XCTFail() }
        XCTAssertEqual(f["a"], .object(["positive": .int(3), "negative": .int(0), "neutral": .int(2)]))
        XCTAssertEqual(f["b"], .array([.string("x, y"), .string("z"), .int(4), .bool(true), .null]))
        XCTAssertEqual(f["c"], .array([.int(1), .int(2)]))
        XCTAssertEqual(f["d"], .object(["k": .array([.int(1), .object(["n": .int(2)])]), "e": .null]))

        XCTAssertEqual(YAMLSubset.load("%YAML 1.2\n---\n# c\na: 1 # t\nb: 2\n...\n"), .object(["a": .int(1), "b": .int(2)]))
        XCTAssertEqual(YAMLSubset.load("---\n- 1\n---\n- 2\n"), .array([.array([.int(1)]), .array([.int(2)])]))
        XCTAssertEqual(YAMLSubset.load(""), .null)
        XCTAssertEqual(YAMLSubset.load("- id: 1\n  tags: [a, b]\n  meta:\n    k: v\n- id: 2\n-\n  id: 3\n- plain\n- [1, 2]\n"),
                       .array([.object(["id": .int(1), "tags": .array([.string("a"), .string("b")]), "meta": .object(["k": .string("v")])]),
                               .object(["id": .int(2)]), .object(["id": .int(3)]), .string("plain"), .array([.int(1), .int(2)])]))
        XCTAssertEqual(YAMLSubset.load("s: first part\n  second part\nu: https://example.com/a:b\nnext: 1\n"),
                       .object(["s": .string("first part second part"), "u": .string("https://example.com/a:b"), "next": .int(1)]))
        for garbage in ["just text", "[unbalanced", "{a: [1,", ": weird", "- - -", "\t\ttabs: 1", "a:\n\tb: 1"] {
            _ = YAMLSubset.load(garbage)   // must not trap
        }
        XCTAssertEqual(YAMLSubset.load("[unbalanced"), .array([.string("unbalanced")]))   // lenient: unclosed flow list
        var deep = YAMLSubset.load(String(repeating: "[", count: 500))                       // nesting capped → string tail
        for _ in 0..<64 {
            guard case .array(let inner) = deep, inner.count == 1 else { return XCTFail("expected single-item nesting") }
            deep = inner[0]
        }
    }

    // MARK: - The spec's own example

    func testSpecExampleFieldMappingAndLosslessMetadata() throws {
        let eps = parse(try fixture("engrams.yaml"))
        XCTAssertEqual(eps.map(\.id), ["ENG-2026-0131-001", "ENG-2026-0302-001", "META-2026-0401-001"])
        let e = eps[0]
        XCTAssertEqual(e.details, "Validate org-mode syntax before writing to .org files.\nThree incidents of malformed entries in January 2026 caused\ndata loss. Always parse and validate before write.\n")
        XCTAssertEqual(e.summary, "Validate org-mode syntax before writing to .org files.")
        XCTAssertEqual(iso(e.eventTime), "2026-01-31T00:00:00Z"); XCTAssertEqual(iso(e.mentionTime), "2026-01-31T00:00:00Z")
        XCTAssertEqual(e.ingestionTime, fixed)
        XCTAssertEqual(e.lastAccessed.map(iso), "2026-01-30T00:00:00Z")
        XCTAssertEqual(e.accessCount, 5); XCTAssertEqual(e.importance, 0.85); XCTAssertEqual(e.confidence, 0.9)
        XCTAssertEqual(e.categories, ["org-mode", "validation"]); XCTAssertEqual(e.contextID, "agent:dip-preparer")
        XCTAssertEqual(e.lifecycleState, "HOT"); XCTAssertEqual(e.sourceType, "note"); XCTAssertFalse(e.pinned)
        XCTAssertNil(e.expirationDate); XCTAssertNil(e.speaker)

        let m = e.metadata
        XCTAssertEqual(m["engram_record"], "engram"); XCTAssertEqual(m["engram_version"], "2"); XCTAssertEqual(m["engram_polarity"], "do")
        XCTAssertEqual(m["engram_activation"], "{\"frequency\":5,\"last_accessed\":\"2026-01-30\",\"retrieval_strength\":0.85,\"storage_strength\":0.6}")
        XCTAssertEqual(m["engram_feedback_signals"], "{\"negative\":0,\"neutral\":2,\"positive\":3}")
        XCTAssertEqual(m["engram_contraindications"], "[\"Quick scratch notes that won't be parsed\"]")
        XCTAssertEqual(m["engram_entities"], "[{\"name\":\"org-mode\",\"type\":\"technology\"}]")
        XCTAssertEqual(m["engram_source"], "user/personal")
        XCTAssertNil(m["engram_id"]); XCTAssertNil(m["engram_statement"])

        let cand = eps[1]
        XCTAssertEqual(cand.categories, ["portable-memory", "vocabulary"])
        XCTAssertEqual(cand.expirationDate.map(iso), "2027-03-02T00:00:00Z"); XCTAssertEqual(iso(cand.eventTime), "2026-03-02T00:00:00Z")
        XCTAssertEqual(cand.metadata["engram_provenance"], "{\"chain\":[],\"license\":\"MIT\",\"origin\":\"session\",\"signature\":null}")

        let meta = eps[2]
        XCTAssertEqual(meta.details, "Memory that cannot be exported is not owned; prefer stores whose contents round-trip through an open format.")
        XCTAssertEqual(meta.metadata["engram_rationale"], "Vendor lock-in through memory is the strongest lock-in in software.\n")
        XCTAssertEqual(iso(meta.eventTime), "2026-04-01T09:30:00Z"); XCTAssertEqual(iso(meta.mentionTime), "2026-04-15T16:45:30Z")
        XCTAssertEqual(meta.lastAccessed.map(iso), "2026-04-15T00:00:00Z"); XCTAssertEqual(meta.lifecycleState, "COLD")
        XCTAssertEqual(meta.metadata["engram_activation"], "{\"frequency\":0,\"last_accessed\":\"2026-04-15\",\"retrieval_strength\":0.4,\"storage_strength\":1}")
        XCTAssertEqual(meta.metadata["engram_pinned"], "false"); XCTAssertEqual(meta.metadata["engram_consolidated"], "true")
    }

    func testPackWrappedRootAndPlurEpisodes() throws {
        let pack = parse(try fixture("pack.yaml"))
        XCTAssertEqual(pack.map(\.id), ["ENG-PACK-PM-001", "ENG-PACK-PM-002"])
        XCTAssertTrue(pack[0].details.hasPrefix("Before switching assistants, export memory to a .mem bundle and validate it;"))
        XCTAssertFalse(pack[0].details.contains("\n")); XCTAssertTrue(pack[0].pinned); XCTAssertEqual(pack[0].importance, 0.95)
        XCTAssertEqual(pack[0].metadata["engram_commitment"], "locked"); XCTAssertEqual(pack[0].eventTime, fixed)
        XCTAssertTrue(pack[1].details.hasSuffix("Don't just remove the row.")); XCTAssertEqual(pack[1].accessCount, 3)

        let eps = parse(try fixture("episodes.yaml"))
        XCTAssertEqual(eps.map(\.id), ["EP-2026-0201-001", "EP-2026-0201-002"])
        XCTAssertEqual(eps[0].sourceType, "event"); XCTAssertEqual(eps[0].speaker, "claude-code"); XCTAssertEqual(eps[0].contextID, "sess-7f3a")
        XCTAssertEqual(iso(eps[0].eventTime), "2026-02-01T10:00:00Z"); XCTAssertEqual(eps[0].metadata["engram_channel"], "terminal")
        XCTAssertEqual(iso(eps[1].eventTime), "2026-02-01T16:30:00Z")   // fraction dropped, +02:00 → UTC
        XCTAssertEqual(eps[1].summary, "Decided: tombstones are applied before additions on import.")
    }

    func testShapesIdsAndRobustness() {
        let single = "{\"id\": \"ENG-X\", \"status\": \"active\", \"type\": \"behavioral\", \"scope\": \"global\", \"statement\": \"s\"}"
        XCTAssertEqual(parse(single).map(\.id), ["ENG-X"])
        XCTAssertEqual(parse("{\"engrams\": [\(single)]}").map(\.id), ["ENG-X"])
        XCTAssertEqual(parse("---\n- id: A\n  statement: a\n---\n- id: B\n  statement: b\n").map(\.id), ["A", "B"])
        let dup = parse("- statement: same text\n- statement: same text\n- statement: other\n")
        XCTAssertEqual(dup.count, 2); XCTAssertTrue(dup[0].id.hasPrefix("eng_")); XCTAssertEqual(dup[0].id.count, 28)
        XCTAssertEqual(dup[0].id, parse("- statement: same text\n")[0].id)
        let odd = parse("- id: A\n  statement: ok\n  activation: {retrieval_strength: 7, frequency: -2}\n  episodic: {confidence: 11}\n- statement: ''\n- 42\n- id: B\n  statement: [not, text]\n")
        XCTAssertEqual(odd.map(\.id), ["A", "B"])
        XCTAssertEqual(odd[0].importance, 1.0); XCTAssertEqual(odd[0].accessCount, 0); XCTAssertEqual(odd[0].confidence, 0.7)
        XCTAssertEqual(odd[1].details, "[\"not\",\"text\"]")
        XCTAssertEqual(parse("").count, 0); XCTAssertEqual(parse("just prose").count, 0); XCTAssertEqual(parse("[]").count, 0)
    }

    // MARK: - Rendering

    func testRenderRestoresEngramsExactlyAndReimportsIdentically() throws {
        for name in ["engrams.yaml", "pack.yaml"] {
            let text = try fixture(name)
            let eps = parse(text)
            let rendered = EngramAdapter.renderYAML(eps)
            guard case .array(let back) = YAMLSubset.load(rendered) else { return XCTFail("render is not a list") }
            let root = YAMLSubset.load(text)
            let originals: [JSONValue]
            if case .object(let o) = root, case .array(let list)? = o["engrams"] { originals = list } else if case .array(let list) = root { originals = list } else { return XCTFail() }
            XCTAssertEqual(back.count, originals.count)
            for (b, o) in zip(back, originals) { XCTAssertEqual(EngramAdapter.canonical(b), EngramAdapter.canonical(o)) }
            let again = parse(rendered)
            XCTAssertEqual(try again.map { try MemCodec.line($0) }, try eps.map { try MemCodec.line($0) })
        }
    }

    func testRenderSynthesizesValidEngramsAndOtherKinds() throws {
        let plain = TransferTextAdapter.parseEpisodes("## Preferences\n[2026-01-15] - Likes terse answers.\n", now: fixed)
        guard case .array(let doc) = YAMLSubset.load(EngramAdapter.renderYAML(plain)), case .object(let eng) = doc[0] else { return XCTFail() }
        for key in ["id", "status", "type", "scope", "statement"] { XCTAssertNotNil(eng[key], key) }
        XCTAssertEqual(eng["statement"], .string("Likes terse answers.")); XCTAssertEqual(eng["tags"], .array([.string("Preferences")]))
        XCTAssertEqual(eng["temporal"], .object(["learned_at": .string("2026-01-15")])); XCTAssertEqual(eng["source"], .string("portable-memory"))

        let eps = parse(try fixture("episodes.yaml"))
        guard case .array(let epDoc) = YAMLSubset.load(EngramAdapter.renderYAML(eps, kind: .episodes)) else { return XCTFail() }
        XCTAssertEqual(epDoc[0], .object(["id": .string("EP-2026-0201-001"), "timestamp": .string("2026-02-01T10:00:00Z"),
                                          "summary": .string("Migrated the team's shared memory from mem0 to a .mem bundle; 412 episodes, checksums verified."),
                                          "agent": .string("claude-code"), "channel": .string("terminal"), "session_id": .string("sess-7f3a")]))
        XCTAssertTrue(EngramAdapter.renderYAML(parse(try fixture("pack.yaml")), wrapped: true).hasPrefix("engrams:\n  - id: \"ENG-PACK-PM-001\"\n"))
        XCTAssertEqual(EngramAdapter.renderYAML([]), "[]\n")
        XCTAssertEqual(YAMLSubset.load(EngramAdapter.renderYAML(eps)), .array([]))   // PLUR episodes are not engrams
        XCTAssertEqual(EngramAdapter.renderYAML(parse(try fixture("engrams.yaml"))), EngramAdapter.renderYAML(parse(try fixture("engrams.yaml"))))
    }

    // MARK: - Fuzz / robustness (seeded, deterministic)

    func testParsersNeverTrapAndAreDeterministic() {
        var state: UInt64 = 20_260_913
        func next() -> UInt64 { state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return state >> 33 }
        let tokens = ["- id: A", "id: B", "statement: |", "statement: >-", "  text line", "tags: [a, b]", "tags:", "- x", "activation:",
                      "  retrieval_strength: 0.9", "{k: v}", "[1, 2,", "]", "}", "engrams:", "- summary: s", "  timestamp: 2026-02-01T10:00:00Z",
                      "'quoted", "\"dq\\\"", "# comment", "---", "...", "null", "~", "true", "1e3", "Київ: 🙂", "", "[2026-01-15] - m", "## S", "```"]
        let noise = Array("abc:[]{}-#|>'\"\\ \n\t  й🙂")
        for _ in 0..<200 {
            var lines: [String] = []
            for _ in 0..<Int(next() % 12) {
                var parts: [String] = []
                for _ in 0..<(1 + Int(next() % 3)) { parts.append(tokens[Int(next() % UInt64(tokens.count))]) }
                if next() % 3 == 0 { parts.append(String((0..<(1 + Int(next() % 5))).map { _ in noise[Int(next() % UInt64(noise.count))] })) }
                lines.append(["", " ", "  ", "    "][Int(next() % 4)] + parts.joined(separator: " "))
            }
            let text = lines.joined(separator: "\n")
            XCTAssertEqual(YAMLSubset.load(text), YAMLSubset.load(text))
            let a = parse(text), b = parse(text)
            XCTAssertEqual(a.map(\.id), b.map(\.id))
            XCTAssertEqual(Set(a.map(\.id)).count, a.count)
            for e in a { XCTAssertNoThrow(try MemCodec.line(e)) }
            let again = parse(EngramAdapter.renderYAML(a))
            XCTAssertEqual(again.map(\.id), a.filter { $0.metadata["engram_record"] != "episode" }.map(\.id))
            let t = TransferTextAdapter.parseEpisodes(text, now: fixed)
            XCTAssertEqual(t.map(\.id), TransferTextAdapter.parseEpisodes(text, now: fixed).map(\.id))
        }
        for text in ["\u{0}\u{1}\u{2}", "\u{FEFF}- id: A\n  statement: bom", String(repeating: "a", count: 20000),
                     String(repeating: "[", count: 500), String(repeating: "- ", count: 300), String(repeating: "|\n", count: 50)] {
            _ = parse(text); _ = YAMLSubset.load(text); _ = TransferTextAdapter.parseEpisodes(text, now: fixed)
        }
    }

    // MARK: - Cross-SDK parity

    /// Both SDKs must turn the three fixture files into byte-identical `items/episode.jsonl`,
    /// and render the five engrams to byte-identical YAML — the Python suite asserts the
    /// very same expected files.
    func testFixtureParityWithPython() async throws {
        var episodes: [PortableEpisode] = []
        for name in ["engrams.yaml", "pack.yaml", "episodes.yaml"] { episodes += parse(try fixture(name)) }
        let store = InMemoryStore()
        for e in episodes { await store.seedEpisode(e) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("engram-\(UUID().uuidString).mem")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await BundleExporter().export(store, to: dir)
        let got = try Data(contentsOf: dir.appendingPathComponent("items/episode.jsonl"))
        XCTAssertEqual(got, try Data(contentsOf: fixtureDir.appendingPathComponent("expected-episode.jsonl")))
        XCTAssertEqual(got.filter { $0 == UInt8(ascii: "\n") }.count, 7)

        let engrams = episodes.filter { $0.metadata["engram_record"] == "engram" }
        XCTAssertEqual(EngramAdapter.renderYAML(engrams), try fixture("expected-render.yaml"))
    }
}
