import Foundation

/// OpenAI / ChatGPT. Maps a ChatGPT data export onto portable episodes. The native
/// export (Settings → Data controls → Export) delivers `conversations.json`: an array of
/// conversation objects, each with a `mapping` tree of message nodes. Each visible
/// user/assistant turn with text becomes one episode; the conversation id/title, message
/// id, role, model, and timestamps are preserved into `metadata` (namespaced `openai_*`)
/// so a later `.mem` export stays lossless.
///
/// Accepted shapes (tolerant, like `Mem0Adapter`): the full export (a JSON array of
/// conversations), a single conversation object, `{conversations:[…]}`, or — as a
/// fallback — a flat "saved memories" list (bare strings, or objects with
/// `memory`/`content`/`text`), each mapped to a note episode.
public enum OpenAIAdapter {
    /// Roles that carry user-facing memory. System prompts and tool plumbing are skipped.
    private static let memoryRoles: Set<String> = ["user", "assistant"]

    public static func parseEpisodes(_ data: Data) throws -> [PortableEpisode] {
        let root = try JSONSerialization.jsonObject(with: data)

        if let conversations = conversations(in: root) {
            return conversations.flatMap { episodes(fromConversation: $0) }
        }
        // Fallback: a flat list of "saved memories".
        return memoryItems(in: root).compactMap { episode(fromMemory: $0) }
    }

    // MARK: - Shape detection

    /// The conversation objects in `root`, or nil when this isn't a conversations export.
    private static func conversations(in root: Any) -> [[String: Any]]? {
        if let dict = root as? [String: Any] {
            if dict["mapping"] is [String: Any] { return [dict] }
            if let list = dict["conversations"] as? [[String: Any]] {
                return list.filter { $0["mapping"] is [String: Any] }
            }
            return nil
        }
        if let list = root as? [[String: Any]] {
            let convs = list.filter { $0["mapping"] is [String: Any] }
            return convs.isEmpty ? nil : convs
        }
        return nil
    }

    private static func memoryItems(in root: Any) -> [Any] {
        if let list = root as? [Any] { return list }
        if let dict = root as? [String: Any] {
            for key in ["memories", "results", "data"] {
                if let list = dict[key] as? [Any] { return list }
            }
        }
        return []
    }

    // MARK: - Conversations

    /// A ChatGPT epoch-seconds number → `Date`, else nil. JSON booleans are excluded
    /// (they bridge to NSNumber too, and `true` must not become 1970-01-01T00:00:01Z).
    /// Booleans are identified by `objCType == "c"` — a `value is Bool` check would
    /// misfire on Darwin for the NUMBERS 0 and 1, silently dropping their timestamps
    /// (a divergence from the Python adapter that the regeneration-branch test caught).
    private static func at(_ value: Any?) -> Date? {
        guard let n = value as? NSNumber else { return nil }
        if String(cString: n.objCType) == "c" { return nil }
        return Date(timeIntervalSince1970: n.doubleValue)
    }

    /// Concatenate the string parts of a message's content (skips non-text parts).
    private static func messageText(_ message: [String: Any]) -> String {
        guard let content = message["content"] as? [String: Any] else { return "" }
        if let parts = content["parts"] as? [Any] {
            return parts.compactMap { $0 as? String }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Some content types carry text under a different key.
        return (content["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func episodes(fromConversation conv: [String: Any]) -> [PortableEpisode] {
        let convID = (conv["conversation_id"] as? String) ?? (conv["id"] as? String)
        let convTitle = conv["title"] as? String
        guard let mapping = conv["mapping"] as? [String: Any] else { return [] }

        var rows: [(ts: Double, key: String, message: [String: Any])] = []
        for (nodeKey, nodeAny) in mapping {
            guard let node = nodeAny as? [String: Any],
                  let message = node["message"] as? [String: Any],
                  let role = (message["author"] as? [String: Any])?["role"] as? String,
                  memoryRoles.contains(role) else { continue }
            let meta = message["metadata"] as? [String: Any] ?? [:]
            if meta["is_visually_hidden_from_conversation"] as? Bool == true { continue }
            guard !messageText(message).isEmpty else { continue }
            // Sort by create_time; entries without one sort last, tie-broken by the
            // mapping node key — a deterministic order both reference SDKs reproduce
            // (dictionaries are unordered here, so document order is not portable).
            let ts = at(message["create_time"]).map(\.timeIntervalSince1970) ?? .infinity
            rows.append((ts, nodeKey, message))
        }
        rows.sort { ($0.ts, $0.key) < ($1.ts, $1.key) }
        return rows.map { episode(fromMessage: $0.message, convID: convID, convTitle: convTitle) }
    }

    private static func episode(fromMessage message: [String: Any],
                                convID: String?, convTitle: String?) -> PortableEpisode {
        let text = messageText(message)
        let role = (message["author"] as? [String: Any])?["role"] as? String
        let msgMeta = message["metadata"] as? [String: Any] ?? [:]
        let created = at(message["create_time"])
        let updated = at(message["update_time"])
        let now = Date()
        let msgID = message["id"] as? String

        var meta: [String: String] = [:]
        put(&meta, "openai_conversation_id", convID)
        put(&meta, "openai_conversation_title", convTitle)
        put(&meta, "openai_message_id", msgID)
        put(&meta, "openai_role", role)
        put(&meta, "openai_model", msgMeta["model_slug"] as? String)
        if let recipient = message["recipient"] as? String, recipient != "all" {
            put(&meta, "openai_recipient", recipient)
        }
        if let created {
            // Canonical whole-second UTC "Z" form — identical to the Python adapter's
            // output, so the same export maps to byte-identical metadata in both SDKs.
            put(&meta, "openai_create_time", isoZ.string(from: created))
        }

        return PortableEpisode(
            id: msgID.flatMap { $0.isEmpty ? nil : $0 } ?? "ep_\(UUID().uuidString.prefix(16))",
            eventTime: created ?? now,
            mentionTime: updated ?? created ?? now,
            ingestionTime: created ?? now,
            sourceType: "chat", sourceID: msgID, actors: [],
            summary: String(text.prefix(120)), details: text, sensitivity: "low",
            deletedAt: nil, metadata: meta, contextID: convID, categories: [],
            importance: 0.5, confidence: 0.7, lifecycleState: "HOT", extractionState: "done",
            lastAccessed: nil, accessCount: 0, pinned: false, expirationDate: nil,
            vaultRefs: [], speaker: role.flatMap { memoryRoles.contains($0) ? $0 : nil })
    }

    // MARK: - Saved-memories fallback

    /// A saved-memory entry (bare string or object) → a note episode, or nil.
    private static func episode(fromMemory item: Any) -> PortableEpisode? {
        let text: String
        let memID: String?
        if let s = item as? String {
            text = s; memID = nil
        } else if let o = item as? [String: Any] {
            text = (o["memory"] as? String) ?? (o["content"] as? String) ?? (o["text"] as? String) ?? ""
            memID = o["id"] as? String
        } else {
            return nil
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let now = Date()
        var meta = ["openai_source": "memory"]
        put(&meta, "openai_memory_id", memID)
        return PortableEpisode(
            id: memID.flatMap { $0.isEmpty ? nil : $0 } ?? "ep_\(UUID().uuidString.prefix(16))",
            eventTime: now, mentionTime: now, ingestionTime: now,
            sourceType: "note", sourceID: memID, actors: [],
            summary: String(text.prefix(120)), details: text, sensitivity: "low",
            deletedAt: nil, metadata: meta, contextID: nil, categories: [],
            importance: 0.5, confidence: 0.7, lifecycleState: "HOT", extractionState: "done",
            lastAccessed: nil, accessCount: 0, pinned: false, expirationDate: nil,
            vaultRefs: [], speaker: nil)
    }

    // MARK: - Helpers

    // ISO8601DateFormatter is a non-Sendable class but is safe for concurrent
    // formatting; a shared read-only instance avoids per-record allocation (same
    // pattern as `MemDate` in Format.swift).
    nonisolated(unsafe) private static let isoZ: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func put(_ meta: inout [String: String], _ key: String, _ value: String?) {
        if let value, !value.isEmpty { meta[key] = value }
    }
}
