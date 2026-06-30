import Foundation

// MARK: - Portable record DTOs (items/<kind>.jsonl)
//
// One DTO per kind. Enum-like fields (sourceType, sensitivity, lifecycleState, entity
// type, …) are plain strings so a foreign vendor's value is never forced into another
// engine's enum — vendor neutrality. Source text is the portable truth; embeddings are
// not inlined here (the receiver re-embeds, spec §2). The episode is the atomic,
// cross-vendor unit and additionally carries `ext` for foreign fields (see Interop).

public struct PortableEpisode: Codable, Sendable {
    public var id: String
    public var eventTime: Date
    public var mentionTime: Date
    public var ingestionTime: Date
    public var sourceType: String
    public var sourceID: String?
    public var actors: [String]
    public var summary: String
    public var details: String
    public var sensitivity: String
    public var deletedAt: Date?
    public var metadata: [String: String]
    public var contextID: String?
    public var categories: [String]
    public var importance: Double
    public var confidence: Double
    public var lifecycleState: String
    public var extractionState: String
    public var lastAccessed: Date?
    public var accessCount: Int
    public var pinned: Bool
    public var expirationDate: Date?
    public var vaultRefs: [String]
    public var speaker: String?

    public init(id: String, eventTime: Date, mentionTime: Date, ingestionTime: Date,
                sourceType: String, sourceID: String?, actors: [String], summary: String,
                details: String, sensitivity: String, deletedAt: Date?,
                metadata: [String: String], contextID: String?, categories: [String],
                importance: Double, confidence: Double, lifecycleState: String,
                extractionState: String, lastAccessed: Date?, accessCount: Int,
                pinned: Bool, expirationDate: Date?, vaultRefs: [String], speaker: String?) {
        self.id = id; self.eventTime = eventTime; self.mentionTime = mentionTime
        self.ingestionTime = ingestionTime; self.sourceType = sourceType
        self.sourceID = sourceID; self.actors = actors; self.summary = summary
        self.details = details; self.sensitivity = sensitivity; self.deletedAt = deletedAt
        self.metadata = metadata; self.contextID = contextID; self.categories = categories
        self.importance = importance; self.confidence = confidence
        self.lifecycleState = lifecycleState; self.extractionState = extractionState
        self.lastAccessed = lastAccessed; self.accessCount = accessCount; self.pinned = pinned
        self.expirationDate = expirationDate; self.vaultRefs = vaultRefs; self.speaker = speaker
    }
}

public struct PortableEntity: Codable, Sendable {
    public var id: String
    public var type: String
    public var canonicalName: String
    public var aliases: [String]
    public var summary: String
    public var sensitivity: String
    public var updatedAt: Date
    public init(id: String, type: String, canonicalName: String, aliases: [String],
                summary: String, sensitivity: String, updatedAt: Date) {
        self.id = id; self.type = type; self.canonicalName = canonicalName
        self.aliases = aliases; self.summary = summary; self.sensitivity = sensitivity
        self.updatedAt = updatedAt
    }
}

public struct PortableEdge: Codable, Sendable {
    public var id: String
    public var srcEntityID: String
    public var dstEntityID: String
    public var edgeType: String
    public var tValidFrom: Date
    public var tValidTo: Date?
    public var ingestionTime: Date
    public var confidence: Double
    public var evidenceEpisodeIDs: [String]
    public var supersededBy: String?
    public init(id: String, srcEntityID: String, dstEntityID: String, edgeType: String,
                tValidFrom: Date, tValidTo: Date?, ingestionTime: Date, confidence: Double,
                evidenceEpisodeIDs: [String], supersededBy: String?) {
        self.id = id; self.srcEntityID = srcEntityID; self.dstEntityID = dstEntityID
        self.edgeType = edgeType; self.tValidFrom = tValidFrom; self.tValidTo = tValidTo
        self.ingestionTime = ingestionTime; self.confidence = confidence
        self.evidenceEpisodeIDs = evidenceEpisodeIDs; self.supersededBy = supersededBy
    }
}

public struct PortableFact: Codable, Sendable {
    public var id: String
    public var episodeID: String
    public var subject: String
    public var predicate: String
    public var object: String
    public var text: String
    public var eventTime: Date?
    public var tValidFrom: Date
    public var tValidTo: Date?
    public var supersededBy: String?
    public var confidence: Double
    public var importance: Double
    public var speaker: String?
    public var reconciledAt: Date?
    public var lastReinforcedAt: Date?
    public var prunedAt: Date?
    public var createdAt: Date
    public init(id: String, episodeID: String, subject: String, predicate: String,
                object: String, text: String, eventTime: Date?, tValidFrom: Date,
                tValidTo: Date?, supersededBy: String?, confidence: Double, importance: Double,
                speaker: String?, reconciledAt: Date?, lastReinforcedAt: Date?,
                prunedAt: Date?, createdAt: Date) {
        self.id = id; self.episodeID = episodeID; self.subject = subject
        self.predicate = predicate; self.object = object; self.text = text
        self.eventTime = eventTime; self.tValidFrom = tValidFrom; self.tValidTo = tValidTo
        self.supersededBy = supersededBy; self.confidence = confidence; self.importance = importance
        self.speaker = speaker; self.reconciledAt = reconciledAt
        self.lastReinforcedAt = lastReinforcedAt; self.prunedAt = prunedAt; self.createdAt = createdAt
    }
}

public struct PortableFactLink: Codable, Sendable {
    public var srcFactID: String
    public var dstFactID: String
    public var linkType: String
    public var createdAt: Date
    public init(srcFactID: String, dstFactID: String, linkType: String, createdAt: Date) {
        self.srcFactID = srcFactID; self.dstFactID = dstFactID
        self.linkType = linkType; self.createdAt = createdAt
    }
}

public struct PortableEpisodeLink: Codable, Sendable {
    public var srcEpisodeID: String
    public var dstEpisodeID: String
    public var linkType: String
    public var weight: Double
    public init(srcEpisodeID: String, dstEpisodeID: String, linkType: String, weight: Double) {
        self.srcEpisodeID = srcEpisodeID; self.dstEpisodeID = dstEpisodeID
        self.linkType = linkType; self.weight = weight
    }
}

public struct PortableResource: Codable, Sendable {
    public var id: String
    public var uri: String
    public var mimeType: String
    public var contentHash: String
    public var title: String
    public var summary: String
    public var created: Date
    public var modified: Date
    public init(id: String, uri: String, mimeType: String, contentHash: String,
                title: String, summary: String, created: Date, modified: Date) {
        self.id = id; self.uri = uri; self.mimeType = mimeType; self.contentHash = contentHash
        self.title = title; self.summary = summary; self.created = created; self.modified = modified
    }
}

public struct PortableChunk: Codable, Sendable {
    public var id: String
    public var resourceID: String
    public var position: Int
    public var text: String
    public var sensitivity: String
    public var contextPrefix: String?
    public init(id: String, resourceID: String, position: Int, text: String,
                sensitivity: String, contextPrefix: String?) {
        self.id = id; self.resourceID = resourceID; self.position = position
        self.text = text; self.sensitivity = sensitivity; self.contextPrefix = contextPrefix
    }
}

public struct PortableCore: Codable, Sendable {
    public var id: String          // profile block id (e.g. human | persona)
    public var content: String
    public var charBudget: Int
    public var version: Int
    public init(id: String, content: String, charBudget: Int, version: Int) {
        self.id = id; self.content = content; self.charBudget = charBudget; self.version = version
    }
}

public struct PortableProcedure: Codable, Sendable {
    public var id: String
    public var name: String
    public var triggerPattern: String
    public var steps: [String]
    public var successCount: Int
    public var failureCount: Int
    public var lastUsed: Date?
    public var enabled: Bool
    public init(id: String, name: String, triggerPattern: String, steps: [String],
                successCount: Int, failureCount: Int, lastUsed: Date?, enabled: Bool) {
        self.id = id; self.name = name; self.triggerPattern = triggerPattern; self.steps = steps
        self.successCount = successCount; self.failureCount = failureCount
        self.lastUsed = lastUsed; self.enabled = enabled
    }
}

public struct PortableContext: Codable, Sendable {
    public var id: String
    public var label: String
    public var parentID: String?
    public var archived: Bool
    public var createdAt: Date
    public init(id: String, label: String, parentID: String?, archived: Bool, createdAt: Date) {
        self.id = id; self.label = label; self.parentID = parentID
        self.archived = archived; self.createdAt = createdAt
    }
}

public struct PortableCommunity: Codable, Sendable {
    public var id: String
    public var label: String
    public var summary: String
    public var memberEntityIDs: [String]
    public init(id: String, label: String, summary: String, memberEntityIDs: [String]) {
        self.id = id; self.label = label; self.summary = summary; self.memberEntityIDs = memberEntityIDs
    }
}

public struct PortableCategory: Codable, Sendable {
    public var name: String
    public var description: String
    public init(name: String, description: String) { self.name = name; self.description = description }
}

public struct PortablePreference: Codable, Sendable {
    public var key: String
    public var value: String
    public init(key: String, value: String) { self.key = key; self.value = value }
}

/// A reference to a vault secret. Carries encryption metadata so a receiver knows how
/// the value is protected, but NEVER the plaintext or ciphertext — the encrypted value
/// stays in the originating vault unless an explicit, authorized, encrypted transfer is
/// negotiated (spec §7). Import restores the metadata skeleton only.
public struct PortableSecretRef: Codable, Sendable {
    public var id: String
    public var label: String
    public var sensitivity: String
    public var category: String
    public var preview: String
    public var encryptionMetadata: String   // encryption metadata, NOT the value
    public var createdAt: Date
    public var lastAccessed: Date?
    public init(id: String, label: String, sensitivity: String, category: String,
                preview: String, encryptionMetadata: String, createdAt: Date, lastAccessed: Date?) {
        self.id = id; self.label = label; self.sensitivity = sensitivity; self.category = category
        self.preview = preview; self.encryptionMetadata = encryptionMetadata
        self.createdAt = createdAt; self.lastAccessed = lastAccessed
    }
}

/// Outcome of an import/merge.
public struct MemImportReport: Codable, Sendable {
    public var tombstonesApplied: Int
    public var applied: [String: Int]
    public var skippedIdempotent: Int
    public var skippedTombstoned: Int
    public var reembedded: Int
    public var warnings: [String]
    public init(tombstonesApplied: Int = 0, applied: [String: Int] = [:],
                skippedIdempotent: Int = 0, skippedTombstoned: Int = 0,
                reembedded: Int = 0, warnings: [String] = []) {
        self.tombstonesApplied = tombstonesApplied
        self.applied = applied
        self.skippedIdempotent = skippedIdempotent
        self.skippedTombstoned = skippedTombstoned
        self.reembedded = reembedded
        self.warnings = warnings
    }
}
