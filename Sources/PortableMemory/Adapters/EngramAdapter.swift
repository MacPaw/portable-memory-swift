import Foundation

/// Engram (PLUR) ingest adapter — `engrams.yaml` / `episodes.yaml` ↔ portable episodes.
///
/// The Engram Specification (plur.ai/spec.html, v2.1, Apache-2.0) models one atomic unit of
/// learned knowledge per *engram*: a `statement` with `type` (behavioral / terminological /
/// procedural / architectural), `scope`, `status`, tags and domain, an `activation` block
/// (retrieval/storage strength, access frequency, last access), `temporal` validity,
/// `episodic` weight/confidence, entities, associations, provenance, and open
/// `structured_data`. Engrams live in YAML files — a bare list per the spec, or wrapped in an
/// `engrams:` key as PLUR's own pack files are written. Timestamped events live in a sibling
/// `episodes.yaml` (`id`, `timestamp`, `summary`, `agent`, `channel`, `session_id`).
///
/// Engrams are complementary to Portable Memory, not competing: they describe *what an agent
/// learned*; a `.mem` bundle gives that knowledge checksums, signatures, cross-vendor merge,
/// and provable deletion. This adapter is the bridge in both directions:
///  * `parseEpisodes` maps each engram onto one portable episode — the statement is the
///    episode text; `temporal.learned_at` (else `created_at`) is the event time; `activation`
///    feeds `lastAccessed` / `accessCount` / `importance`; `episodic.confidence` (1–10) becomes
///    `confidence`; `tags` become categories; `scope` becomes the context id;
///    `temporal.valid_until` the expiration; `pinned` is pinned. PLUR episodes map onto event
///    episodes (`agent` → speaker, `session_id` → context id). **Every** top-level key is
///    preserved verbatim as `metadata["engram_<key>"]` — strings as they are, everything else
///    as canonical JSON — so nothing is lost.
///  * `renderYAML` is the reverse: episodes → spec-shaped YAML. Episodes that came from
///    engrams are restored exactly; other episodes are synthesized into valid engrams.
///
/// Mirrors the Python `EngramAdapter` line-for-line; `Conformance/fixtures/engram/` pins
/// byte-identical output across both SDKs.
public enum EngramAdapter {
    private static let metaPrefix = "engram_"
    private static let recordKey = "engram_record"

    /// status → lifecycleState, and back. `candidate` engrams are live knowledge too.
    private static let lifecycle: [String: String] = ["active": "HOT", "candidate": "HOT", "dormant": "COLD", "retired": "ARCHIVED"]
    private static let status: [String: String] = ["HOT": "active", "COLD": "dormant", "ARCHIVED": "retired"]

    /// Engram keys whose values are strings in the spec — restored as-is (`"null"` → null).
    private static let stringKeys: Set<String> = [
        "id", "status", "type", "scope", "visibility", "polarity", "created_at", "updated_at",
        "statement", "rationale", "source", "pack", "abstract", "derived_from", "domain",
        "claim_class", "content_hash", "commitment", "locked_at", "locked_reason", "summary",
    ]
    /// Emission order for engram keys (the spec's order); anything else follows, sorted.
    private static let keyOrder: [String] = [
        "id", "version", "status", "type", "scope", "visibility", "polarity", "statement",
        "rationale", "contraindications", "tags", "domain", "consolidated", "pinned", "activation",
        "entities", "temporal", "episodic", "usage", "associations", "relations", "knowledge_type",
        "knowledge_anchors", "dual_coding", "source", "provenance", "attribution", "claim_class",
        "derivation_count", "pack", "abstract", "derived_from", "feedback_signals", "exchange",
        "structured_data", "insight", "commitment", "created_at", "updated_at", "summary",
        "content_hash",
    ]
    private static let episodeKeyOrder: [String] = ["id", "timestamp", "summary", "agent", "channel", "session_id"]

    public enum Kind: String, Sendable { case engrams, episodes }

    // MARK: - Public API

    /// Parse engrams (and PLUR episodes) from YAML or JSON text. `now` is the ingestion
    /// instant (and the event time of undated entries) — inject it for reproducible output.
    public static func parseEpisodes(_ text: String, now: Date = Date()) -> [PortableEpisode] {
        parseEpisodes(load(text), now: now)
    }

    /// UTF-8 bytes convenience.
    public static func parseEpisodes(_ data: Data, now: Date = Date()) -> [PortableEpisode] {
        parseEpisodes(String(decoding: data, as: UTF8.self), now: now)
    }

    /// Parse already-decoded content: a bare array of engrams, `{"engrams": […]}`,
    /// `{"episodes": […]}`, a single engram, or an array of documents.
    public static func parseEpisodes(_ root: JSONValue, now: Date = Date()) -> [PortableEpisode] {
        var engrams: [[String: JSONValue]] = []
        var plurEpisodes: [[String: JSONValue]] = []
        collect(root, &engrams, &plurEpisodes)
        var out: [PortableEpisode] = []
        var seen = Set<String>()
        for e in engrams {
            if let ep = fromEngram(e, now: now), seen.insert(ep.id).inserted { out.append(ep) }
        }
        for p in plurEpisodes {
            if let ep = fromPlurEpisode(p, now: now), seen.insert(ep.id).inserted { out.append(ep) }
        }
        return out
    }

    /// Render episodes as Engram-spec YAML. `.engrams` (default) writes an `engrams.yaml`:
    /// episodes that came from engrams are restored from their `engram_*` metadata exactly;
    /// any other episode is synthesized into a valid engram. `.episodes` writes a PLUR
    /// `episodes.yaml`. `wrapped` nests the list under an `engrams:` / `episodes:` key, as
    /// PLUR's pack files do; the default is the spec's bare-list root.
    public static func renderYAML(_ episodes: [PortableEpisode], kind: Kind = .engrams, wrapped: Bool = false) -> String {
        var items: [JSONValue] = []
        for e in episodes {
            if kind == .episodes {
                items.append(.object(episodeToPlurEpisode(e)))
            } else if e.metadata[recordKey] != "episode" {
                items.append(.object(episodeToEngram(e)))
            }
        }
        var lines: [String]
        if wrapped {
            lines = [kind.rawValue + ":"] + (items.isEmpty ? ["  []"] : emitSequence(items, 2))
        } else {
            lines = items.isEmpty ? ["[]"] : emitSequence(items, 0)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Loading / collecting

    static func load(_ text: String) -> JSONValue {
        let head = text.drop(while: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })
        if let first = head.first, first == "[" || first == "{",
           let value = try? MemCodec.decoder.decode(JSONValue.self, from: Data(text.utf8)) {
            return value
        }
        return YAMLSubset.load(text)
    }

    private static func collect(_ node: JSONValue, _ engrams: inout [[String: JSONValue]], _ plurEpisodes: inout [[String: JSONValue]]) {
        switch node {
        case .array(let items):
            for item in items {
                switch item {
                case .array, .object: collect(item, &engrams, &plurEpisodes)
                default: break
                }
            }
        case .object(let obj):
            if case .array? = obj["engrams"] {
                collectWrapped(obj, &engrams, &plurEpisodes)
            } else if case .array? = obj["episodes"] {
                collectWrapped(obj, &engrams, &plurEpisodes)
            } else if obj["statement"] != nil {
                engrams.append(obj)
            } else if obj["summary"] != nil, obj["timestamp"] != nil || obj["agent"] != nil || obj["session_id"] != nil {
                plurEpisodes.append(obj)
            }
        default:
            break
        }
    }

    private static func collectWrapped(_ obj: [String: JSONValue], _ engrams: inout [[String: JSONValue]], _ plurEpisodes: inout [[String: JSONValue]]) {
        if case .array(let list)? = obj["engrams"] {
            for e in list { if case .object(let o) = e { engrams.append(o) } }
        }
        if case .array(let list)? = obj["episodes"] {
            for p in list { if case .object(let o) = p { plurEpisodes.append(o) } }
        }
    }

    // MARK: - Engram → episode

    private static func fromEngram(_ e: [String: JSONValue], now: Date) -> PortableEpisode? {
        let statement: String
        switch e["statement"] {
        case .string(let s)?: statement = s
        case nil, .null?: statement = ""
        case let other?: statement = stringify(other)
        }
        var ident = str(e["id"]) ?? ""
        if ident.isEmpty {
            if statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            ident = "eng_" + String(Hashing.sha256Hex(statement).prefix(24))
        }
        let temporal = obj(e["temporal"])
        let activation = obj(e["activation"])
        let episodic = obj(e["episodic"])

        let eventTime = date(temporal["learned_at"]) ?? date(e["created_at"]) ?? now
        let mentionTime = date(e["updated_at"]) ?? eventTime
        let confidence = int(episodic["confidence"])
        let statusText = str(e["status"]) ?? ""
        let summary = str(e["summary"])

        var meta: [String: String] = [recordKey: "engram"]
        for (key, value) in e where key != "id" && key != "statement" {
            meta[metaPrefix + key] = stringify(value)
        }
        let firstLine = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let tags: [String] = {
            if case .array(let list)? = e["tags"] { return list.compactMap { str($0) } }
            return []
        }()
        let scope = str(e["scope"]).flatMap { $0.isEmpty ? nil : $0 }

        return PortableEpisode(
            id: ident,
            eventTime: eventTime, mentionTime: mentionTime, ingestionTime: now,
            sourceType: "note", sourceID: nil, actors: [],
            summary: String((summary ?? firstLine).prefix(120)), details: statement, sensitivity: "low",
            deletedAt: nil, metadata: meta, contextID: scope, categories: tags,
            importance: unit(activation["retrieval_strength"], 0.5),
            confidence: (confidence != nil && confidence! >= 1 && confidence! <= 10) ? Double(confidence!) / 10 : 0.7,
            lifecycleState: lifecycle[statusText] ?? "HOT", extractionState: "done",
            lastAccessed: date(activation["last_accessed"]),
            accessCount: max(int(activation["frequency"]) ?? 0, 0),
            pinned: e["pinned"] == .bool(true),
            expirationDate: date(temporal["valid_until"]),
            vaultRefs: [], speaker: nil)
    }

    private static func fromPlurEpisode(_ p: [String: JSONValue], now: Date) -> PortableEpisode? {
        guard let summary = str(p["summary"]), !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let ts = str(p["timestamp"]) ?? ""
        var ident = str(p["id"]) ?? ""
        if ident.isEmpty { ident = "epx_" + String(Hashing.sha256Hex(ts + "\n" + summary).prefix(24)) }
        let when = date(ts.isEmpty ? nil : .string(ts)) ?? now
        var meta: [String: String] = [recordKey: "episode"]
        for (key, value) in p where key != "id" && key != "summary" {
            meta[metaPrefix + key] = stringify(value)
        }
        let firstLine = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let agent = str(p["agent"]).flatMap { $0.isEmpty ? nil : $0 }
        let session = str(p["session_id"]).flatMap { $0.isEmpty ? nil : $0 }
        return PortableEpisode(
            id: ident,
            eventTime: when, mentionTime: when, ingestionTime: now,
            sourceType: "event", sourceID: nil, actors: [],
            summary: String(firstLine.prefix(120)), details: summary, sensitivity: "low",
            deletedAt: nil, metadata: meta, contextID: session, categories: [],
            importance: 0.5, confidence: 0.7, lifecycleState: "HOT", extractionState: "done",
            lastAccessed: nil, accessCount: 0, pinned: false, expirationDate: nil,
            vaultRefs: [], speaker: agent)
    }

    // MARK: - Episode → engram / PLUR episode

    private static func restored(_ e: PortableEpisode) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (key, value) in e.metadata where key != recordKey && key.hasPrefix(metaPrefix) {
            let name = String(key.dropFirst(metaPrefix.count))
            out[name] = unstringify(name, value)
        }
        return out
    }

    private static func episodeToEngram(_ e: PortableEpisode) -> [String: JSONValue] {
        let isEngram = e.metadata[recordKey] == "engram"
        var obj = isEngram ? restored(e) : [:]
        obj["id"] = .string(e.id)
        let statement = e.details.isEmpty ? e.summary : e.details
        obj["statement"] = .string(statement)
        if isEngram { return obj }
        // Synthesize a valid engram (required: id, status, type, scope, statement).
        if obj["version"] == nil { obj["version"] = .int(2) }
        if obj["status"] == nil { obj["status"] = .string(status[e.lifecycleState] ?? "active") }
        if obj["type"] == nil { obj["type"] = .string("terminological") }
        if obj["scope"] == nil { obj["scope"] = .string(e.contextID ?? "global") }
        let firstLine = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if !e.summary.isEmpty, e.summary != String(firstLine.prefix(120)), obj["summary"] == nil {
            obj["summary"] = .string(e.summary)
        }
        if !e.categories.isEmpty, obj["tags"] == nil { obj["tags"] = .array(e.categories.map { .string($0) }) }
        if e.pinned { obj["pinned"] = .bool(true) }
        var activation: [String: JSONValue] = [
            "retrieval_strength": .double(e.importance),
            "storage_strength": .double(e.importance),
            "frequency": .int(e.accessCount),
        ]
        if let last = e.lastAccessed { activation["last_accessed"] = .string(String(isoZ.string(from: last).prefix(10))) }
        obj["activation"] = .object(activation)
        var temporal: [String: JSONValue] = ["learned_at": .string(String(isoZ.string(from: e.eventTime).prefix(10)))]
        if let exp = e.expirationDate { temporal["valid_until"] = .string(String(isoZ.string(from: exp).prefix(10))) }
        obj["temporal"] = .object(temporal)
        if obj["source"] == nil { obj["source"] = .string("portable-memory") }
        return obj
    }

    private static func episodeToPlurEpisode(_ e: PortableEpisode) -> [String: JSONValue] {
        var obj = e.metadata[recordKey] == "episode" ? restored(e) : [:]
        obj["id"] = .string(e.id)
        obj["summary"] = .string(e.details.isEmpty ? e.summary : e.details)
        if obj["timestamp"] == nil { obj["timestamp"] = .string(isoZ.string(from: e.eventTime)) }
        if let speaker = e.speaker, !speaker.isEmpty, obj["agent"] == nil { obj["agent"] = .string(speaker) }
        if let ctx = e.contextID, !ctx.isEmpty, obj["session_id"] == nil { obj["session_id"] = .string(ctx) }
        return obj
    }

    private static func unstringify(_ key: String, _ s: String) -> JSONValue {
        if stringKeys.contains(key) { return s == "null" ? .null : .string(s) }
        if key == "record" { return .string(s) }
        if let value = try? MemCodec.decoder.decode(JSONValue.self, from: Data(s.utf8)) { return value }
        return .string(s)
    }

    // MARK: - YAML emitter (deterministic, spec-shaped)

    private static func orderedKeys(_ obj: [String: JSONValue], _ order: [String]) -> [String] {
        order.filter { obj[$0] != nil } + obj.keys.filter { !order.contains($0) }.sorted()
    }

    private static func emitSequence(_ items: [JSONValue], _ indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        var out: [String] = []
        for item in items {
            switch item {
            case .object(let obj):
                let body = emitMapping(obj, indent + 2)
                if let first = body.first {
                    out.append(pad + "- " + String(first.dropFirst(indent + 2)))
                    out.append(contentsOf: body.dropFirst())
                } else {
                    out.append(pad + "- {}")
                }
            case .array(let list):
                if allScalars(list) {
                    out.append(pad + "- " + flowList(list))
                } else {
                    out.append(pad + "-")
                    out.append(contentsOf: emitSequence(list, indent + 2))
                }
            default:
                out.append(contentsOf: emitScalarLines(pad + "- ", item, indent + 2))
            }
        }
        return out
    }

    private static func emitMapping(_ obj: [String: JSONValue], _ indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        var out: [String] = []
        let order = (obj["timestamp"] != nil && obj["statement"] == nil) ? episodeKeyOrder : keyOrder
        for key in orderedKeys(obj, order) {
            let value = obj[key]!
            let head = pad + emitKey(key) + ":"
            switch value {
            case .object(let nested):
                if nested.isEmpty {
                    out.append(head + " {}")
                } else {
                    out.append(head)
                    out.append(contentsOf: emitMapping(nested, indent + 2))
                }
            case .array(let list):
                if list.isEmpty {
                    out.append(head + " []")
                } else if allScalars(list) {
                    out.append(head + " " + flowList(list))
                } else {
                    out.append(head)
                    out.append(contentsOf: emitSequence(list, indent + 2))
                }
            default:
                out.append(contentsOf: emitScalarLines(head + " ", value, indent + 2))
            }
        }
        return out
    }

    /// `prefix` + scalar; multi-line strings become literal block scalars.
    private static func emitScalarLines(_ prefix: String, _ value: JSONValue, _ indent: Int) -> [String] {
        if case .string(let s) = value, s.contains("\n"), blockable(s) {
            var body = Substring(s)
            while body.last == "\n" { body = body.dropLast() }
            let trailing = s.count - body.count
            let indicator = trailing == 0 ? "|-" : (trailing == 1 ? "|" : "|+")
            let pad = String(repeating: " ", count: indent)
            var trimmedPrefix = Substring(prefix)
            while trimmedPrefix.last == " " { trimmedPrefix = trimmedPrefix.dropLast() }
            var lines = [String(trimmedPrefix) + " " + indicator]
            for ln in body.components(separatedBy: "\n") { lines.append(ln.isEmpty ? "" : pad + ln) }
            if trailing > 1 { lines.append(contentsOf: Array(repeating: "", count: trailing - 1)) }
            return lines
        }
        return [prefix + emitScalar(value)]
    }

    private static func blockable(_ s: String) -> Bool {
        if s.hasPrefix(" ") || s.hasPrefix("\t") { return false }
        return !s.components(separatedBy: "\n").contains { $0.hasPrefix(" ") || $0.hasPrefix("\t") }
    }

    private static func allScalars(_ items: [JSONValue]) -> Bool {
        items.allSatisfy { item in
            switch item {
            case .object, .array: return false
            case .string(let s): return !s.contains("\n")
            default: return true
            }
        }
    }

    private static func flowList(_ items: [JSONValue]) -> String {
        "[" + items.map(emitScalar).joined(separator: ", ") + "]"
    }

    private static func emitKey(_ key: String) -> String {
        guard let first = key.first, first != "-", first != ".",
              key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." || $0 == "/" })
        else { return quote(key) }
        return key
    }

    private static func emitScalar(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .uint(let u): return String(u)
        case .double: return canonical(value)
        case .string(let s): return quote(s)
        case .array, .object: return quote(canonical(value))
        }
    }

    /// JSON-style double quoting, identical to Python's `json.dumps(s, ensure_ascii=False)`.
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{8}": out += "\\b"
            case "\u{C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += "\\u" + String(format: "%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - Helpers

    /// Strings pass through; everything else is canonical JSON (bools as `true`/`false`,
    /// `null`, numbers in shortest form, containers with sorted keys) — reversible exactly.
    static func stringify(_ value: JSONValue) -> String {
        if case .string(let s) = value { return s }
        return canonical(value)
    }

    static func canonical(_ value: JSONValue) -> String {
        guard let data = try? MemCodec.encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func obj(_ v: JSONValue?) -> [String: JSONValue] {
        if case .object(let o)? = v { return o }
        return [:]
    }

    private static func str(_ v: JSONValue?) -> String? {
        if case .string(let s)? = v { return s }
        return nil
    }

    private static func int(_ v: JSONValue?) -> Int? {
        switch v {
        case .int(let i)?: return i
        case .uint(let u)?: return Int(exactly: u)
        case .double(let d)?: return d.rounded() == d ? Int(exactly: d) : nil
        default: return nil
        }
    }

    private static func unit(_ v: JSONValue?, _ fallback: Double) -> Double {
        let d: Double
        switch v {
        case .int(let i)?: d = Double(i)
        case .uint(let u)?: d = Double(u)
        case .double(let x)?: d = x
        default: return fallback
        }
        return min(max(d, 0.0), 1.0)
    }

    /// `YYYY-MM-DD` or RFC 3339 (`T` or space, optional fraction, `Z` or `±HH:MM`) → UTC.
    static func date(_ v: JSONValue?) -> Date? {
        guard case .string(let raw)? = v else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = Array(s)
        let digits: Set<Character> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
        if c.count == 10, TransferTextAdapter.isISODate(s) {
            return TransferTextAdapter.ymd(Int(String(c[0..<4]))!, Int(String(c[5..<7]))!, Int(String(c[8..<10]))!)
        }
        guard c.count >= 19, TransferTextAdapter.isISODate(s.prefix(10)), c[10] == "T" || c[10] == " ",
              c[13] == ":", c[16] == ":", [11, 12, 14, 15, 17, 18].allSatisfy({ digits.contains(c[$0]) }) else { return nil }
        guard let base = TransferTextAdapter.ymd(Int(String(c[0..<4]))!, Int(String(c[5..<7]))!, Int(String(c[8..<10]))!,
                                                  Int(String(c[11..<13]))!, Int(String(c[14..<16]))!, Int(String(c[17..<19]))!)
        else { return nil }
        var rest = Array(c[19...])
        if rest.first == "." {
            var k = 1
            while k < rest.count, digits.contains(rest[k]) { k += 1 }
            rest = Array(rest[k...])
        }
        if rest.isEmpty || rest == ["Z"] || rest == ["z"] { return base }
        if rest.count == 6, rest[0] == "+" || rest[0] == "-", rest[3] == ":",
           [1, 2, 4, 5].allSatisfy({ digits.contains(rest[$0]) }) {
            let minutes = Int(String(rest[1..<3]))! * 60 + Int(String(rest[4..<6]))!
            return rest[0] == "+" ? base.addingTimeInterval(TimeInterval(-minutes * 60))
                                  : base.addingTimeInterval(TimeInterval(minutes * 60))
        }
        return nil
    }

    nonisolated(unsafe) private static let isoZ: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
