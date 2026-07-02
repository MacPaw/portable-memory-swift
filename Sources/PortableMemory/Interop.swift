import Foundation

// MARK: - Cross-vendor lossless passthrough (spec §1 `ext`, §10)
//
// For a `.mem` bundle to be a LOSSLESS container for any vendor's memory, two things
// another system put in a bundle must survive a round-trip verbatim even though this
// engine doesn't model them:
//   • unknown FIELDS on an episode — captured into `ext` and re-merged on export;
//   • unknown KINDS (`items/<vendorKind>.jsonl`) — stored raw and re-emitted with each
//     record's bytes preserved (JSONL framing normalized to a single trailing `\n`).

/// A minimal, `Codable` JSON value tree. Foreign (`ext`) fields are schema-less JSON, so
/// they are carried as `JSONValue` and (re)serialized through `MemCodec` — the SAME
/// `JSONEncoder` used for native records. That is what makes the `ext` path produce
/// byte-identical canonical output to the native path: sorted keys, unescaped slashes,
/// and — critically — the SHORTEST round-tripping number form (`0.7`, not
/// `0.69999999999999996`). Using `JSONSerialization` here instead would reformat numbers
/// to full IEEE-754 precision and silently diverge from the canonical codec, breaking
/// cross-implementation checksums (spec §1, "Canonical JSON").
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Order matters: Bool before Int (so JSON `true` is a bool, not coerced), Int
        // before UInt64 (so common values stay Int), UInt64 before Double so integer
        // tokens in (Int64.max, UInt64.max] — e.g. 64-bit ids/hashes — keep exact
        // precision instead of collapsing to a lossy Double. Integer tokens beyond
        // UInt64.max still fall to Double; such values are not byte-stable across
        // implementations and are out of the format's supported integer range.
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let u = try? c.decode(UInt64.self) { self = .uint(u); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "value is not representable JSON")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .uint(let u): try c.encode(u)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

public enum Interop {
    /// The native JSON keys on a `PortableEpisode`. Any key found on an imported
    /// episode line that is NOT in this set is a foreign field → `ext`.
    public static let knownEpisodeKeys: Set<String> = {
        let e = PortableEpisode(
            id: "", eventTime: Date(timeIntervalSince1970: 0),
            mentionTime: Date(timeIntervalSince1970: 0),
            ingestionTime: Date(timeIntervalSince1970: 0),
            sourceType: "", sourceID: "", actors: [], summary: "", details: "",
            sensitivity: "", deletedAt: Date(timeIntervalSince1970: 0), metadata: [:],
            contextID: "", categories: [], importance: 0, confidence: 0,
            lifecycleState: "", extractionState: "", lastAccessed: Date(timeIntervalSince1970: 0),
            accessCount: 0, pinned: false, expirationDate: Date(timeIntervalSince1970: 0),
            vaultRefs: [], speaker: "")
        guard let data = try? MemCodec.encoder.encode(e),
              let obj = try? MemCodec.decoder.decode([String: JSONValue].self, from: data) else { return [] }
        return Set(obj.keys)
    }()

    /// From one raw episode JSONL line, return the canonical JSON of any foreign
    /// (non-native) keys — the `ext` to persist so it round-trips. nil when there are none.
    public static func extractEpisodeExt(line: Data) -> String? {
        guard let obj = try? MemCodec.decoder.decode([String: JSONValue].self, from: line) else { return nil }
        let extra = obj.filter { !knownEpisodeKeys.contains($0.key) }
        guard !extra.isEmpty, let data = try? MemCodec.encoder.encode(extra) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Merge persisted `ext` keys back into an episode's native JSON on export, without
    /// overriding any native key. Returns the original bytes unchanged when there is no
    /// ext (so ext-free exports stay byte-identical and deterministic). The merged object
    /// is re-encoded through `MemCodec`, so native and foreign fields share one canonical
    /// form (sorted keys, shortest numbers).
    public static func mergeEpisodeExt(nativeJSON: Data, extJSON: String?) -> Data {
        guard let extJSON, let extData = extJSON.data(using: .utf8),
              let ext = try? MemCodec.decoder.decode([String: JSONValue].self, from: extData), !ext.isEmpty,
              var obj = try? MemCodec.decoder.decode([String: JSONValue].self, from: nativeJSON)
        else { return nativeJSON }
        for (k, v) in ext where obj[k] == nil { obj[k] = v }
        guard let merged = try? MemCodec.encoder.encode(obj) else { return nativeJSON }
        return merged
    }
}
