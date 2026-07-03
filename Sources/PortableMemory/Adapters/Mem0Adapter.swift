import Foundation

// MARK: - Vendor adapters (cross-provider ingest)
//
// The format is a superset container: an adapter maps a foreign export onto portable
// episodes, and whatever it doesn't model is preserved in `metadata` (namespaced) so a
// later `.mem` export stays lossless. Adapters are pure (no host): they produce
// `[PortableEpisode]` that a host then imports.

/// mem0 (https://github.com/mem0ai/mem0). Maps its export — a JSON array, or
/// `{results:[…]}` / `{memories:[…]}` (the platform's paginated envelope also wraps
/// `results`) — onto portable episodes. Missing/extra fields are handled gracefully.
///
/// mem0's promoted per-memory keys (OSS `promoted_payload_keys`) are `user_id`,
/// `agent_id`, `run_id`, `actor_id`, `role`, `attributed_to`, and `expiration_date` —
/// all read here; `expiration_date` (normalized `YYYY-MM-DD`) additionally maps onto
/// the episode's own `expirationDate`. Any OTHER top-level key (`score`, `immutable`,
/// `memory_type`, future platform fields, …) is swept into `mem0_<key>` metadata so
/// nothing a mem0 version emits is ever dropped. Graph `relations` (returned alongside
/// `results` when graph memory is enabled) are NOT mapped in v1 — adapters return
/// episodes only; entity/edge promotion is a possible follow-up.
public enum Mem0Adapter {
    /// Top-level mem0 keys the mapping reads explicitly; everything else is swept into
    /// `mem0_<key>` metadata.
    static let handledKeys: Set<String> = [
        "memory", "text", "data", "role", "user_id", "agent_id", "actor_id", "run_id",
        "created_at", "updated_at", "metadata", "categories", "id", "hash",
        "attributed_to", "expiration_date",
    ]

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
        // mem0 normalizes expiration_date to date-only "YYYY-MM-DD".
        let isoDateOnly = ISO8601DateFormatter()
        isoDateOnly.formatOptions = [.withFullDate]
        isoDateOnly.timeZone = TimeZone(identifier: "UTC")
        let parse: (String?) -> Date? = { s in
            guard let s else { return nil }
            return isoFractional.date(from: s) ?? isoPlain.date(from: s) ?? isoDateOnly.date(from: s)
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
        // Date-only "YYYY-MM-DD" parses as midnight UTC; the raw string is also
        // preserved in metadata below.
        let expiration = parse(o["expiration_date"] as? String)

        var actors: [String] = []
        for a in [userId, agentId, actorId] where (a?.isEmpty == false) { actors.append(a!) }

        var meta: [String: String] = [:]
        if let m = o["metadata"] as? [String: Any] { for (k, v) in m { meta[k] = stringify(v) } }
        let provenance: [String: Any?] = [
            "mem0_id": o["id"], "mem0_hash": o["hash"], "mem0_role": role,
            "mem0_user_id": userId, "mem0_agent_id": agentId, "mem0_actor_id": actorId,
            "mem0_run_id": runId, "mem0_created_at": o["created_at"], "mem0_updated_at": o["updated_at"],
            "mem0_attributed_to": o["attributed_to"], "mem0_expiration_date": o["expiration_date"],
        ]
        for (k, v) in provenance { if let s = v as? String, !s.isEmpty { meta[k] = s } }
        // Lossless sweep: any top-level key the mapping doesn't recognize (score,
        // immutable, memory_type, future platform fields, …) is preserved as
        // mem0_<key>. Nulls are skipped — mem0 emits e.g. "expiration_date": null.
        // Never overwrites user metadata or provenance that already claimed a key.
        for (k, v) in o where !handledKeys.contains(k) && !(v is NSNull) {
            let key = "mem0_\(k)"
            if meta[key] == nil { meta[key] = stringify(v) }
        }

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
            lastAccessed: nil, accessCount: 0, pinned: false, expirationDate: expiration,
            vaultRefs: [], speaker: (role == "user" || role == "assistant") ? role : nil)
    }

    static func stringify(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        // Containers: serialize through the CANONICAL codec so the string matches the
        // Python adapter byte-for-byte. JSONSerialization alone reformats doubles to
        // full IEEE-754 precision ("0.69999999999999996"); round-tripping its bytes
        // through JSONValue + MemCodec restores the shortest canonical form ("0.7").
        if let data = try? JSONSerialization.data(withJSONObject: v),
           let jv = try? MemCodec.decoder.decode(JSONValue.self, from: data),
           let out = try? MemCodec.encoder.encode(jv) {
            return String(decoding: out, as: UTF8.self)
        }
        return String(describing: v)
    }
}
