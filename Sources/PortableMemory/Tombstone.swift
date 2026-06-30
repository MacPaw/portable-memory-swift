import Foundation

// MARK: - Tombstones (spec §5 — the trust core)
//
// A deletion is not a row removal; it is a first-class, portable, monotonic record (it
// cannot be un-seen) that propagates everywhere the data — or anything derived from it
// — ever went. The tombstone carries proof-of-reach: the ids of every derived artifact
// removed and the cache keys evicted, so a deletion can be *verified* across replicas
// and external adopters, not merely asserted. This is the guarantee the standard rests
// on and the conformance gate (L2).

/// Proof-of-reach: the derived artifacts a single deletion removed. Recorded in the
/// tombstone and surfaced in the Evidence Pack as the verifiable statement that the
/// target is gone from every route.
public struct DerivedRefs: Codable, Sendable, Equatable {
    public var sentenceIDs: [String]
    public var factIDs: [String]
    public var edgeIDs: [String]              // edges deleted because their last evidence was removed
    public var entityIDs: [String]            // entities orphaned by those edge deletions
    public var chunkIDs: [String]
    public var episodeLinkCount: Int          // links severed
    public var embeddingCacheKeys: [String]   // sha256(model \0 text) keys evicted

    public init(sentenceIDs: [String] = [], factIDs: [String] = [],
                edgeIDs: [String] = [], entityIDs: [String] = [],
                chunkIDs: [String] = [], episodeLinkCount: Int = 0,
                embeddingCacheKeys: [String] = []) {
        self.sentenceIDs = sentenceIDs
        self.factIDs = factIDs
        self.edgeIDs = edgeIDs
        self.entityIDs = entityIDs
        self.chunkIDs = chunkIDs
        self.episodeLinkCount = episodeLinkCount
        self.embeddingCacheKeys = embeddingCacheKeys
    }

    public mutating func merge(_ other: DerivedRefs) {
        sentenceIDs += other.sentenceIDs
        factIDs += other.factIDs
        edgeIDs += other.edgeIDs
        entityIDs += other.entityIDs
        chunkIDs += other.chunkIDs
        episodeLinkCount += other.episodeLinkCount
        embeddingCacheKeys += other.embeddingCacheKeys
    }
}

public enum TombstoneOp: String, Codable, Sendable {
    case delete            // remove the item and every derived artifact
    case redact            // additionally purge the content text (erasure / GDPR Art. 17)
}

/// The portable deletion record (`audit/tombstones.jsonl`). On import, tombstones are
/// applied BEFORE any additions, so a bundle that also ships the (stale) rows can never
/// resurrect deleted content, and redaction always wins.
public struct Tombstone: Codable, Sendable {
    public var id: String
    public var op: TombstoneOp
    public var targetKind: String         // MemKind.rawValue of what was deleted
    public var targetID: String
    public var deletedAt: Date
    public var reason: String?
    public var actor: String
    public var derived: DerivedRefs
    public var signature: String?          // optional ed25519 over the canonical record (L3)

    public init(id: String, op: TombstoneOp, targetKind: String, targetID: String,
                deletedAt: Date, reason: String?, actor: String,
                derived: DerivedRefs, signature: String? = nil) {
        self.id = id
        self.op = op
        self.targetKind = targetKind
        self.targetID = targetID
        self.deletedAt = deletedAt
        self.reason = reason
        self.actor = actor
        self.derived = derived
        self.signature = signature
    }
}

/// One row of the portable audit trail (`audit/log.jsonl`). The Evidence Pack (spec §6)
/// is an exportable subset of these plus tombstones plus provenance.
public struct PortableAuditRecord: Codable, Sendable {
    public var ts: Date
    public var actor: String
    public var op: String
    public var targetID: String
    public var reason: String?

    public init(ts: Date, actor: String, op: String, targetID: String, reason: String?) {
        self.ts = ts; self.actor = actor; self.op = op
        self.targetID = targetID; self.reason = reason
    }
}
