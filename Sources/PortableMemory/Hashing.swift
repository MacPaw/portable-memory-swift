import Foundation
import Crypto

/// Canonical content hashing for the portable format. Lowercase-hex SHA-256 over the
/// deterministic JSON encoding of a record gives a stable `content_hash` used as a
/// dedupe key, cache key, and merge-idempotency check, and over a file's bytes for the
/// `CHECKSUMS` integrity manifest. Same bytes everywhere → same hash everywhere.
/// Backed by swift-crypto, so it runs identically on Apple platforms and Linux.
public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    /// sha256(model ∥ NUL ∥ text) — the conventional embedding-cache key, restated here
    /// so a deletion can reconstruct and evict the exact cache entries a piece of
    /// content produced (deletion-propagation, spec §5).
    public static func embeddingCacheKey(model: String, text: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(model.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(text.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A portable record whose `contentHash` is computed over its own canonical encoding
/// with the hash field blanked (a hash cannot cover itself).
public protocol PortableHashable: Codable {
    var contentHash: String { get set }
}

public extension PortableHashable {
    func withContentHash() -> Self {
        var blanked = self
        blanked.contentHash = ""
        let hex = (try? MemCodec.encoder.encode(blanked)).map { Hashing.sha256Hex($0) } ?? ""
        var out = self
        out.contentHash = "sha256:" + hex
        return out
    }

    func contentHashMatches() -> Bool {
        withContentHash().contentHash == contentHash
    }
}
