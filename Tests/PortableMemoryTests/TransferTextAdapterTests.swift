import XCTest
@testable import PortableMemory

/// Memory-transfer text adapter — parsing rules, determinism, rendering, and the shared
/// cross-SDK fixture (`Conformance/fixtures/transfer/`). Mirrors the Python suite
/// (`tests/test_adapter_transfer.py`) so the two SDKs' rules stay at parity.
final class TransferTextAdapterTests: XCTestCase {
    private let fixed = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z

    private var fixtureDir: URL {
        // Tests/PortableMemoryTests/<this> → repo root is three levels up.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Conformance/fixtures/transfer")
    }

    private func sample() throws -> String {
        try String(contentsOf: fixtureDir.appendingPathComponent("sample-export.txt"), encoding: .utf8)
    }

    private func parse(_ text: String? = nil, source: String? = nil) throws -> [PortableEpisode] {
        TransferTextAdapter.parseEpisodes(try text ?? sample(), source: source, now: fixed)
    }

    private func byLine(_ eps: [PortableEpisode]) -> [Int: PortableEpisode] {
        Dictionary(uniqueKeysWithValues: eps.map { (Int($0.metadata["transfer_line"]!)!, $0) })
    }

    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    // MARK: - Shape

    func testSampleShapeAndIdentity() throws {
        let eps = try parse(source: "chatgpt")
        // 8 entries before the first header + 3 under headers; the duplicate last line collapses.
        XCTAssertEqual(eps.count, 11)
        XCTAssertTrue(eps.allSatisfy { $0.id.hasPrefix("tx_") && $0.id.count == 27 })
        XCTAssertTrue(eps.allSatisfy { $0.sourceType == "note" && $0.speaker == nil })
        XCTAssertTrue(eps.allSatisfy { $0.metadata["transfer_source"] == "chatgpt" })
        XCTAssertTrue(eps.allSatisfy { $0.ingestionTime == fixed })
        XCTAssertEqual(Set(eps.map(\.id)).count, eps.count)
    }

    func testDatesSeparatorsAndRawPreservation() throws {
        let b = byLine(try parse())
        XCTAssertEqual(iso(b[1]!.eventTime), "2025-11-03T00:00:00Z")
        XCTAssertEqual(b[1]!.details, "Prefers concise answers: code first, explanation second.")
        XCTAssertEqual(b[1]!.metadata["transfer_date_raw"], "2025-11-03")
        XCTAssertTrue(b[2]!.details.hasPrefix("Works as Director"))          // en dash separator
        XCTAssertTrue(b[3]!.details.hasPrefix("Leads \"Portable Memory\""))  // em dash separator
        XCTAssertEqual(iso(b[4]!.eventTime), "2026-01-01T00:00:00Z")          // [Jan 2026]
        XCTAssertEqual(b[4]!.metadata["transfer_date_raw"], "Jan 2026")
        XCTAssertEqual(b[5]!.eventTime, fixed)                                // [date unknown] → undated → now
        XCTAssertEqual(b[5]!.metadata["transfer_date_raw"], "date unknown")
        XCTAssertTrue(b[5]!.details.contains("Київ"))                         // raw UTF-8 survives
        XCTAssertEqual(iso(b[8]!.eventTime), "2026-02-02T00:00:00Z")          // bare ISO date + separator
        XCTAssertEqual(b[8]!.metadata["transfer_date_raw"], "2026-02-02")
    }

    func testBulletsNumbersHeadersAndContinuations() throws {
        let b = byLine(try parse())
        XCTAssertEqual(b[6]!.details, "Prefers metric units and 24-hour time.")   // "- " stripped
        XCTAssertNil(b[6]!.metadata["transfer_date_raw"])
        XCTAssertEqual(b[7]!.details, "Has a dog named Bit.")                      // "1. " stripped
        XCTAssertEqual(b[11]!.categories, ["Communication preferences"])
        XCTAssertEqual(b[11]!.metadata["transfer_section"], "Communication preferences")
        XCTAssertEqual(b[11]!.details, "Tone: direct, no filler, no emoji.\nException: emoji are fine in casual chats.")
        XCTAssertEqual(b[11]!.summary, "Tone: direct, no filler, no emoji.")
        XCTAssertEqual(b[13]!.categories, ["Communication preferences"])
        XCTAssertEqual(b[16]!.categories, ["INSTRUCTIONS"])
        XCTAssertEqual(b[1]!.categories, [])
        XCTAssertNil(b[10]); XCTAssertNil(b[15])                                   // headers are not entries
    }

    func testProseOutsideFenceIgnoredAndDuplicatesCollapse() throws {
        let eps = try parse()
        XCTAssertFalse(eps.contains { $0.details.contains("complete set") || $0.details.contains("everything I have stored") })
        XCTAssertNil(byLine(eps)[17])   // exact repeat of line 1 → no second episode
        let single = TransferTextAdapter.parseEpisodes(
            "[2025-11-03] - Prefers concise answers: code first, explanation second.", now: fixed)
        XCTAssertEqual(byLine(eps)[1]!.id, single[0].id)
    }

    func testIdsAreDeterministicAndIndependentOfNow() throws {
        let text = try sample()
        let a = TransferTextAdapter.parseEpisodes(text, now: fixed)
        let b = TransferTextAdapter.parseEpisodes(text, now: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(a.map(\.id), b.map(\.id))
        XCTAssertEqual(a.map(\.id), TransferTextAdapter.parseEpisodes(Data(text.utf8), now: fixed).map(\.id))
    }

    // MARK: - Variants

    func testPlainTextWithoutFenceAndColonSeparator() throws {
        let eps = try parse("[2026-01-01] - a\n[2026-01-02]: b\n[2026-01-03]c\n")
        XCTAssertEqual(eps.map(\.details), ["a", "b", "c"])
        XCTAssertEqual(eps.map { iso($0.eventTime) }, ["2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z", "2026-01-03T00:00:00Z"])
    }

    func testProseParagraphMode() throws {
        let text = "You are a senior engineer who prefers\nterse answers.\n\n\nYou live in Kyiv and work on memory systems.\n"
        let eps = try parse(text)
        XCTAssertEqual(eps.map(\.details), [
            "You are a senior engineer who prefers\nterse answers.",
            "You live in Kyiv and work on memory systems.",
        ])
        XCTAssertEqual(eps.map { $0.metadata["transfer_line"]! }, ["1", "5"])
        XCTAssertTrue(eps.allSatisfy { $0.eventTime == fixed })
    }

    func testHeaderVariants() throws {
        let text = "## Projects\n[2026-01-01] - a\n**Tools**:\n- b\nPreferences:\n1. c\nGOALS\n2026-03-03 - d\n(2) e\n"
        let eps = try parse(text)
        XCTAssertEqual(eps.map(\.details), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(eps.map { $0.categories[0] }, ["Projects", "Tools", "Preferences", "GOALS", "GOALS"])
    }

    func testLinesThatLookLikeHeadersButAreNot() throws {
        let eps = try parse("- Favorite editor: Vim\nTone: direct, no filler\n[2026-01-01] - Uses: Python, Swift\n")
        XCTAssertEqual(eps.map(\.details), ["Favorite editor: Vim", "Tone: direct, no filler", "Uses: Python, Swift"])
        XCTAssertTrue(eps.allSatisfy { $0.categories.isEmpty })
    }

    func testMonthNameAndPartialDates() throws {
        let text = "[March 3rd, 2026] - a\n[3 March 2026] - b\n[Sept 2025] - c\n[2024] - d\n[2025-06] - e\n"
            + "[2026-01-15T10:20:30Z] - f\n[2026-02-30] - g\n[yesterday] - h\n[] - i\n"
        let b = byLine(try parse(text))
        XCTAssertEqual(iso(b[1]!.eventTime), "2026-03-03T00:00:00Z")
        XCTAssertEqual(iso(b[2]!.eventTime), "2026-03-03T00:00:00Z")
        XCTAssertEqual(iso(b[3]!.eventTime), "2025-09-01T00:00:00Z")
        XCTAssertEqual(iso(b[4]!.eventTime), "2024-01-01T00:00:00Z")
        XCTAssertEqual(iso(b[5]!.eventTime), "2025-06-01T00:00:00Z")
        XCTAssertEqual(iso(b[6]!.eventTime), "2026-01-15T10:20:30Z")
        XCTAssertEqual(b[7]!.eventTime, fixed); XCTAssertEqual(b[7]!.metadata["transfer_date_raw"], "2026-02-30")  // invalid → undated, raw kept
        XCTAssertEqual(b[8]!.eventTime, fixed); XCTAssertEqual(b[8]!.metadata["transfer_date_raw"], "yesterday")
        XCTAssertEqual(b[9]!.eventTime, fixed); XCTAssertNil(b[9]!.metadata["transfer_date_raw"])               // "[]" → no raw
        XCTAssertNotEqual(b[1]!.id, b[2]!.id)   // different content
    }

    func testEmptyAndNoise() throws {
        XCTAssertEqual(try parse("").count, 0)
        XCTAssertEqual(try parse("```\n```\n").count, 0)
        XCTAssertEqual(try parse("[2026-01-01]\n\n   \n").count, 0)   // bracket with no content → nothing
        XCTAssertEqual(try parse("Here you go:\n```\n- only\n```\n")[0].details, "only")
    }

    // MARK: - Rendering

    func testRenderRoundTrip() throws {
        let eps = try parse(source: "chatgpt")
        let text = TransferTextAdapter.renderText(eps)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "[2025-11-03] - Prefers concise answers: code first, explanation second.")
        XCTAssertTrue(lines.contains("  Exception: emoji are fine in casual chats."))   // continuation indented
        XCTAssertTrue(text.hasSuffix("\n"))
        let again = TransferTextAdapter.parseEpisodes(text, now: fixed)
        XCTAssertEqual(again.map(\.details), eps.map(\.details))
        // Dated entries keep their identity through a round trip; undated ones gain the render date.
        let dated = Set(eps.filter { $0.eventTime != fixed }.map(\.id))
        XCTAssertTrue(dated.isSubset(of: Set(again.map(\.id))))
    }

    func testRenderGroupedBySectionAndEmpty() throws {
        let text = TransferTextAdapter.renderText(try parse(), groupBySection: true)
        XCTAssertTrue(text.contains("## Communication preferences") && text.contains("## INSTRUCTIONS"))
        XCTAssertLessThan(text.range(of: "[2025-11-03] - Prefers")!.lowerBound, text.range(of: "## Communication preferences")!.lowerBound)
        XCTAssertEqual(TransferTextAdapter.renderText([]), "")
    }

    // MARK: - Cross-SDK parity

    /// Both SDKs must turn sample-export.txt into byte-identical items/episode.jsonl —
    /// the Python suite asserts the very same expected file.
    func testFixtureParityWithPython() async throws {
        let expected = try Data(contentsOf: fixtureDir.appendingPathComponent("expected-episode.jsonl"))
        let store = InMemoryStore()
        for e in try parse(source: "chatgpt") { await store.seedEpisode(e) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transfer-\(UUID().uuidString).mem")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await BundleExporter().export(store, to: dir)
        let got = try Data(contentsOf: dir.appendingPathComponent("items/episode.jsonl"))
        XCTAssertEqual(got, expected)
        XCTAssertEqual(got.filter { $0 == UInt8(ascii: "\n") }.count, 11)
    }
}
