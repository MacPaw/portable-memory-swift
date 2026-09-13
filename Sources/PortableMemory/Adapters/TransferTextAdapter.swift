import Foundation

/// Memory-transfer text — the de-facto cross-vendor interchange today.
///
/// Since March 2026 the major assistants move memory between each other by *prompt*, not
/// by file. Claude (claude.com/import-memory) and Gemini (gemini.google/import-memory)
/// hand the user a prompt to run in the source assistant — "List every memory you have
/// stored about me … Output everything in a single code block … Format each entry as:
/// [date saved, if available] - memory content" — and the user pastes the result into the
/// destination's import box. ChatGPT has no memory export at all, and Claude's own export
/// ("View and edit your memory") is free text too.
///
/// That pasted text is lossy prose with no identity, no structure, and no way to delete —
/// exactly the failure mode Portable Memory exists to fix. This adapter is the on-ramp:
/// `parseEpisodes` maps the text onto portable episodes (one per entry, preserving the
/// bracketed date verbatim, the section a header put it under, and the line number) with
/// **deterministic** ids, so pasting the same export twice merges instead of duplicating
/// and both reference SDKs produce byte-identical bundles from the same text; `renderText`
/// is the reverse — any episodes → the `[date] - content` block every importer accepts.
///
/// The parsing rules are mirrored line-for-line by the Python `TransferTextAdapter`
/// (`portable_memory/adapters/transfer.py`) and pinned by the shared fixture in
/// `Conformance/fixtures/transfer/`:
///  * text with fenced ``` blocks → only the fenced content is read; otherwise every line;
///  * entries `[date] - content` (separator `-`, `–`, `—` or `:`), bare `2026-01-15 - content`,
///    bulleted (`-`, `*`, `•`) or numbered (`1.`, `1)`, `(1)`) lines, and undated lines;
///    unrecognized bracket text (`[date unknown]`) is kept verbatim and the entry is undated;
///  * dates `YYYY-MM-DD[THH:MM:SSZ]`, `YYYY-MM`, `YYYY`, `Month YYYY`, `Month D, YYYY`, `D Month YYYY`;
///  * headers (`## Preferences`, `**Projects**`, `Preferences:`, `TOOLS`) set the section;
///  * indented lines continue the previous entry;
///  * text with no entry markers at all is read as blank-line-separated paragraphs.
public enum TransferTextAdapter {
    private static let bullets: [String] = ["-", "*", "•", "–", "—"]
    private static let separators: Set<Character> = ["-", "–", "—", ":"]
    private static let digits: Set<Character> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
    private static let months: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
        "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7,
        "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9, "oct": 10, "october": 10,
        "nov": 11, "november": 11, "dec": 12, "december": 12,
    ]
    private static let idPrefix = "tx_"

    struct Entry {
        var line: Int            // 1-based line number within the parsed body
        var section: String?     // the most recent header, verbatim
        var dateRaw: String?     // bracket (or bare-ISO) text, verbatim
        var content: String      // continuation lines joined with "\n"
    }

    // MARK: - Public API

    /// Parse pasted memory-transfer text into episodes. `source` names the assistant the
    /// text came from (`"chatgpt"`, `"claude"`, `"gemini"`, …) and is recorded as
    /// `metadata["transfer_source"]`; `now` is the ingestion instant (and the event time of
    /// undated entries) — inject it for reproducible output; ids never depend on it.
    public static func parseEpisodes(_ text: String, source: String? = nil, now: Date = Date()) -> [PortableEpisode] {
        var seen = Set<String>()
        var out: [PortableEpisode] = []
        for entry in entries(bodyLines(text)) {
            let ep = episode(entry, source: source, now: now)
            if seen.insert(ep.id).inserted { out.append(ep) }   // exact repeats keep the first
        }
        return out
    }

    /// UTF-8 bytes convenience.
    public static func parseEpisodes(_ data: Data, source: String? = nil, now: Date = Date()) -> [PortableEpisode] {
        parseEpisodes(String(decoding: data, as: UTF8.self), source: source, now: now)
    }

    /// Render episodes as paste-ready `[YYYY-MM-DD] - content` lines. Continuation lines
    /// are indented by two spaces (what `parseEpisodes` reads back as a continuation). With
    /// `groupBySection` the first category becomes a `## Section` header; the standard
    /// export prompt asks *not* to group, so the default is a flat list.
    public static func renderText(_ episodes: [PortableEpisode], groupBySection: Bool = false) -> String {
        var out: [String] = []
        if groupBySection {
            var order: [String] = []
            var groups: [String: [PortableEpisode]] = [:]
            for e in episodes {
                let key = e.categories.first ?? ""
                if groups[key] == nil { groups[key] = []; order.append(key) }
                groups[key]!.append(e)
            }
            for (i, key) in order.enumerated() {
                if i > 0 { out.append("") }
                if !key.isEmpty { out.append("## " + key) }
                out += renderLines(groups[key] ?? [])
            }
        } else {
            out = renderLines(episodes)
        }
        return out.isEmpty ? "" : out.joined(separator: "\n") + "\n"
    }

    // MARK: - Body

    /// The lines to parse: the contents of all fenced blocks if any, else every line.
    static func bodyLines(_ text: String) -> [String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var inside = false, sawFence = false
        var fenced: [String] = []
        for line in lines {
            if strip(line).hasPrefix("```") { sawFence = true; inside.toggle(); continue }
            if inside { fenced.append(line) }
        }
        return sawFence ? fenced : lines
    }

    static func entries(_ lines: [String]) -> [Entry] {
        guard lines.contains(where: isMarker) else { return paragraphs(lines) }
        var out: [Entry] = []
        var section: String? = nil
        var current: Int? = nil        // index into `out` of the entry accepting continuations
        for (i, raw) in lines.enumerated() {
            let stripped = strip(raw)
            if stripped.isEmpty { current = nil; continue }
            if let c = current, let first = raw.first, first == " " || first == "\t" {
                out[c].content += "\n" + stripped
                continue
            }
            let (text, bulleted) = stripBullet(stripped)
            if let name = header(text, bulleted: bulleted) { section = name; current = nil; continue }
            let (dateRaw, content) = splitDate(text)
            if content.isEmpty { current = nil; continue }
            out.append(Entry(line: i + 1, section: section, dateRaw: dateRaw, content: content))
            current = out.count - 1
        }
        return out
    }

    static func paragraphs(_ lines: [String]) -> [Entry] {
        var out: [Entry] = []
        var buf: [String] = []
        var start = 0
        for (i, raw) in lines.enumerated() {
            let s = strip(raw)
            if !s.isEmpty {
                if buf.isEmpty { start = i + 1 }
                buf.append(s)
            } else if !buf.isEmpty {
                out.append(Entry(line: start, section: nil, dateRaw: nil, content: buf.joined(separator: "\n")))
                buf = []
            }
        }
        if !buf.isEmpty { out.append(Entry(line: start, section: nil, dateRaw: nil, content: buf.joined(separator: "\n"))) }
        return out
    }

    static func isMarker(_ line: String) -> Bool {
        let s = strip(line)
        if s.isEmpty { return false }
        let (text, bulleted) = stripBullet(s)
        return bulleted || text.hasPrefix("[") || header(text, bulleted: bulleted) != nil || bareISO(text) != nil
    }

    // MARK: - Line pieces

    /// Remove one leading list marker (`- `, `* `, `• `, `1. `, `1) `, `(1) `).
    static func stripBullet(_ s: String) -> (String, Bool) {
        for b in bullets where s.hasPrefix(b + " ") {
            return (lstrip(s.dropFirst(b.count)), true)
        }
        let body: Substring = s.hasPrefix("(") ? s.dropFirst() : Substring(s)
        var i = body.startIndex
        var n = 0
        while i < body.endIndex, n < 3, digits.contains(body[i]) { i = body.index(after: i); n += 1 }
        if n > 0, i < body.endIndex, body[i] == "." || body[i] == ")" {
            let after = body.index(after: i)
            if after < body.endIndex, body[after] == " " {
                return (lstrip(body[body.index(after: after)...]), true)
            }
        }
        return (s, false)
    }

    /// The section name if `text` is a header line, else nil.
    static func header(_ text: String, bulleted: Bool) -> String? {
        if bulleted || text.isEmpty || text.hasPrefix("[") { return nil }
        if text.hasPrefix("#") {
            let name = strip(String(text.drop(while: { $0 == "#" })))
            return name.isEmpty ? nil : name
        }
        if text.hasPrefix("**") {
            let inner = strip(rstripColons(text))
            if inner.hasSuffix("**"), inner.count > 4 {
                let name = strip(rstripColons(strip(String(inner.dropFirst(2).dropLast(2)))))
                return name.isEmpty ? nil : name
            }
            return nil
        }
        if hasSeparator(text) || bareISO(text) != nil { return nil }
        let words = text.split(whereSeparator: { $0.isWhitespace })
        if text.hasSuffix(":"), words.count <= 8 {
            let name = strip(String(text.dropLast()))
            return name.isEmpty ? nil : name
        }
        let letters = text.filter { $0.isLetter }
        if letters.count >= 3, words.count <= 6, letters.allSatisfy({ $0.isUppercase }) { return text }
        return nil
    }

    static func hasSeparator(_ text: String) -> Bool {
        text.contains(" - ") || text.contains(" – ") || text.contains(" — ")
    }

    static func isISODate<S: StringProtocol>(_ s: S) -> Bool {
        let c = Array(s)
        guard c.count == 10, c[4] == "-", c[7] == "-" else { return false }
        return [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy { digits.contains(c[$0]) }
    }

    /// `2026-01-15 - content` / `2026-01-15: content` → (date token, content).
    static func bareISO(_ text: String) -> (String, String)? {
        guard isISODate(text.prefix(10)) else { return nil }
        var token: String
        var rest: String
        if let sp = text.firstIndex(of: " ") {
            token = String(text[..<sp])
            rest = lstrip(text[text.index(after: sp)...])
        } else {
            token = text
            rest = ""
        }
        if let last = token.last, separators.contains(last) {
            token.removeLast()
            return (token, strip(rest))
        }
        if let first = rest.first, separators.contains(first) {
            return (token, strip(lstrip(rest.dropFirst())))
        }
        return nil
    }

    /// `[date] - content` → (date text or nil, content).
    static func splitDate(_ text: String) -> (String?, String) {
        if text.hasPrefix("[") {
            if let end = text.firstIndex(of: "]") {
                let dateRaw = strip(String(text[text.index(after: text.startIndex)..<end]))
                var rest = lstrip(text[text.index(after: end)...])
                if let first = rest.first, separators.contains(first) { rest = lstrip(rest.dropFirst()) }
                return (dateRaw.isEmpty ? nil : dateRaw, strip(rest))
            }
            return (nil, text)
        }
        if let (date, content) = bareISO(text) { return (date, strip(content)) }
        return (nil, text)
    }

    // MARK: - Dates

    static func parseDate(_ raw: String) -> Date? {
        let s = strip(raw)
        if s.isEmpty { return nil }
        let c = Array(s)
        if c.count >= 10, isISODate(s.prefix(10)) {
            let y = Int(String(c[0..<4]))!, m = Int(String(c[5..<7]))!, d = Int(String(c[8..<10]))!
            if c.count == 20, c[10] == "T", c[13] == ":", c[16] == ":", c[19] == "Z",
               [11, 12, 14, 15, 17, 18].allSatisfy({ digits.contains(c[$0]) }) {
                let hh = Int(String(c[11..<13]))!, mm = Int(String(c[14..<16]))!, ss = Int(String(c[17..<19]))!
                if hh <= 23, mm <= 59, ss <= 59 { return ymd(y, m, d, hh, mm, ss) }
            }
            return ymd(y, m, d)
        }
        if c.count == 7, c[4] == "-", [0, 1, 2, 3, 5, 6].allSatisfy({ digits.contains(c[$0]) }) {
            return ymd(Int(String(c[0..<4]))!, Int(String(c[5..<7]))!, 1)
        }
        if c.count == 4, c.allSatisfy({ digits.contains($0) }) {
            return ymd(Int(s)!, 1, 1)
        }
        let tokens = s.replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if tokens.count == 2, let m = months[tokens[0].lowercased()], let y = int4(tokens[1]) {
            return ymd(y, m, 1)
        }
        if tokens.count == 3 {
            if let m = months[tokens[0].lowercased()], let d = day(tokens[1]), let y = int4(tokens[2]) { return ymd(y, m, d) }
            if let d = day(tokens[0]), let m = months[tokens[1].lowercased()], let y = int4(tokens[2]) { return ymd(y, m, d) }
        }
        return nil
    }

    static func int4(_ t: String) -> Int? {
        t.count == 4 && t.allSatisfy({ digits.contains($0) }) ? Int(t) : nil
    }

    static func day(_ token: String) -> Int? {
        var t = token.lowercased()
        for suffix in ["st", "nd", "rd", "th"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(2))
            break
        }
        return (1...2).contains(t.count) && t.allSatisfy({ digits.contains($0) }) ? Int(t) : nil
    }

    /// A UTC instant, or nil when the calendar fields are out of range (the Python SDK's
    /// `datetime` raises on Feb 30; `Calendar` would roll it over, so validate by hand).
    static func ymd(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 0, _ mm: Int = 0, _ ss: Int = 0) -> Date? {
        guard (1...9999).contains(y), (1...12).contains(m), (1...daysInMonth(y, m)).contains(d) else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        comps.hour = hh; comps.minute = mm; comps.second = ss
        return utcCalendar.date(from: comps)
    }

    static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default: return (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28
        }
    }

    // Proleptic Gregorian (ISO 8601) so pre-1582 dates match Python's `datetime`.
    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    // MARK: - Episodes

    static func episode(_ e: Entry, source: String?, now: Date) -> PortableEpisode {
        let parsed = e.dateRaw.flatMap(parseDate)
        let dateKey = parsed.map { String(isoZ.string(from: $0).prefix(10)) } ?? ""
        // Deterministic identity: the same dated memory text always maps to the same id, in
        // both SDKs, so repeated pastes merge and cross-SDK bundles are byte-identical.
        let id = idPrefix + String(Hashing.sha256Hex(dateKey + "\n" + e.content).prefix(24))
        var meta: [String: String] = ["transfer_line": String(e.line)]
        put(&meta, "transfer_source", source)
        put(&meta, "transfer_date_raw", e.dateRaw)
        put(&meta, "transfer_section", e.section)
        let when = parsed ?? now
        let firstLine = e.content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return PortableEpisode(
            id: id,
            eventTime: when, mentionTime: when, ingestionTime: now,
            sourceType: "note", sourceID: nil, actors: [],
            summary: String(firstLine.prefix(120)), details: e.content, sensitivity: "low",
            deletedAt: nil, metadata: meta, contextID: nil,
            categories: e.section.map { [$0] } ?? [],
            importance: 0.5, confidence: 0.7, lifecycleState: "HOT", extractionState: "done",
            lastAccessed: nil, accessCount: 0, pinned: false, expirationDate: nil,
            vaultRefs: [], speaker: nil)
    }

    static func renderLines(_ episodes: [PortableEpisode]) -> [String] {
        var out: [String] = []
        for e in episodes {
            let text = e.details.isEmpty ? e.summary : e.details
            if strip(text).isEmpty { continue }
            let parts = text.components(separatedBy: "\n")
            let date = String(isoZ.string(from: e.eventTime).prefix(10))
            out.append("[\(date)] - \(parts[0])")
            for p in parts.dropFirst() { out.append("  " + p) }
        }
        return out
    }

    // MARK: - Helpers

    private static func strip(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lstrip<S: StringProtocol>(_ s: S) -> String {
        String(s.drop(while: { $0.isWhitespace }))
    }

    private static func rstripColons(_ s: String) -> String {
        var t = Substring(s)
        while t.last == ":" { t = t.dropLast() }
        return String(t)
    }

    private static func put(_ meta: inout [String: String], _ key: String, _ value: String?) {
        if let value, !value.isEmpty { meta[key] = value }
    }

    // ISO8601DateFormatter is a non-Sendable class but is safe for concurrent formatting;
    // a shared read-only instance avoids per-record allocation (same pattern as the other
    // adapters and `MemDate`).
    nonisolated(unsafe) private static let isoZ: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
