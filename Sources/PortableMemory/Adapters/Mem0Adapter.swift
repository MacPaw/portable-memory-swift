import Foundation

// MARK: - Vendor adapters (cross-provider ingest)
//
// The format is a superset container: an adapter maps a foreign export onto portable
// episodes, and whatever it doesn't model is preserved in `metadata` (namespaced) so a
// later `.mem` export stays lossless. Adapters are pure (no host): they produce
// `[PortableEpisode]` that a host then imports.

/// mem0 (https://github.com/mem0ai/mem0). Maps its export — a JSON array, or
/// `{results:[…]}` / `{memories:[…]}` — onto portable episodes. Missing/extra fields
/// are handled gracefully; the original `id`, `hash`, role, and ids are preserved.
public enum Mem0Adapter {
    public static func parseEpisodes(_ data: Data) throws -> [PortableEpisode] {
        let root = try JSONSerialization.jsonObject(with: data)
        let items: [[String: Any]]
        if let arr = root as? [[String: Any]] {
            items = arr
        } else if let dict = root as? [String: Any] {
            items = (dict["results"] as? [[String: Any]])
                ?? (dict["memories"] as? [[String: Any]])
                ?? (dict["data"] as? [[String: Any]]) ?? []
        } else {
            items = []
        }
        // Build the ISO-8601 parsers ONCE per call, not per record — a hot path for
        // large exports (ISO8601DateFormatter is expensive to allocate/configure).
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        let parse: (String?) -> Date? = { s in
            guard let s else { return nil }
            return isoFractional.date(from: s) ?? isoPlain.date(from: s)
        }
        return items.compactMap { mapOne($0, parse: parse) }
    }

    static func mapOne(_ o: [String: Any], parse: (String?) -> Date?) -> PortableEpisode? {
        let text = (o["memory"] as? String) ?? (o["text"] as? String) ?? (o["data"] as? String) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let role = o["role"] as? String
        let userId = o["user_id"] as? String
        let agentId = o["agent_id"] as? String
        let actorId = o["actor_id"] as? String
        let runId = o["run_id"] as? String
        let created = parse(o["created_at"] as? String) ?? Date()
        let updated = parse(o["updated_at"] as? String)

        var actors: [String] = []
        for a in [userId, agentId, actorId] where (a?.isEmpty == false) { actors.append(a!) }

        var meta: [String: String] = [:]
        if let m = o["metadata"] as? [String: Any] { for (k, v) in m { meta[k] = stringify(v) } }
        let provenance: [String: Any?] = [
            "mem0_id": o["id"], "mem0_hash": o["hash"], "mem0_role": role,
            "mem0_user_id": userId, "mem0_agent_id": agentId, "mem0_actor_id": actorId,
            "mem0_run_id": runId, "mem0_created_at": o["created_at"], "mem0_updated_at": o["updated_at"],
        ]
        for (k, v) in provenance { if let s = v as? String, !s.isEmpty { meta[k] = s } }

        let categories = (o["categories"] as? [Any])?.compactMap { $0 as? String } ?? []
        let id = (o["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "ep_\(UUID().uuidString.prefix(16))"

        return PortableEpisode(
            id: id, eventTime: created, mentionTime: updated ?? created, ingestionTime: created,
            sourceType: role != nil ? "chat" : "text",
            sourceID: o["id"] as? String, actors: actors,
            summary: String(text.prefix(120)), details: text, sensitivity: "low",
            deletedAt: nil, metadata: meta,
            contextID: (runId?.isEmpty == false) ? runId : nil, categories: categories,
            importance: 0.5, confidence: 0.7, lifecycleState: "HOT", extractionState: "done",
            lastAccessed: nil, accessCount: 0, pinned: false, expirationDate: nil,
            vaultRefs: [], speaker: (role == "user" || role == "assistant") ? role : nil)
    }

    static func stringify(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return String(describing: v)
    }
}
