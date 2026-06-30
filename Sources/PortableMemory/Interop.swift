import Foundation

// MARK: - Cross-vendor lossless passthrough (spec §1 `ext`, §10)
//
// For a `.mem` bundle to be a LOSSLESS container for any vendor's memory, two things
// another system put in a bundle must survive a round-trip verbatim even though this
// engine doesn't model them:
//   • unknown FIELDS on an episode — captured into `ext` and re-merged on export;
//   • unknown KINDS (`items/<vendorKind>.jsonl`) — stored raw and re-emitted byte-for-byte.

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
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return Set(obj.keys)
    }()

    /// From one raw episode JSONL line, return the JSON of any foreign (non-native)
    /// keys — the `ext` to persist so it round-trips. nil when there are none.
    public static func extractEpisodeExt(line: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        let extra = obj.filter { !knownEpisodeKeys.contains($0.key) }
        guard !extra.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Merge persisted `ext` keys back into an episode's native JSON on export, without
    /// overriding any native key. Returns the original bytes unchanged when there is no
    /// ext (so ext-free exports stay byte-identical and deterministic).
    public static func mergeEpisodeExt(nativeJSON: Data, extJSON: String?) -> Data {
        guard let extJSON, let extData = extJSON.data(using: .utf8),
              let ext = try? JSONSerialization.jsonObject(with: extData) as? [String: Any], !ext.isEmpty,
              var obj = try? JSONSerialization.jsonObject(with: nativeJSON) as? [String: Any]
        else { return nativeJSON }
        for (k, v) in ext where obj[k] == nil { obj[k] = v }
        guard let merged = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            return nativeJSON
        }
        return merged
    }
}
