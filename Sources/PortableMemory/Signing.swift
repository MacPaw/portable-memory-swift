import Foundation
import Crypto

// MARK: - Bundle & tombstone authenticity (spec §1.2, §7, L3)
//
// Checksums (CHECKSUMS / manifest.files[].sha256) give INTEGRITY — they detect
// corruption in transit. They do NOT give AUTHENTICITY: anyone who can edit a file can
// recompute its public SHA-256 and rewrite the manifest. Ed25519 signatures close that
// gap. Signing the manifest (which transitively covers every file via its hash) proves
// the WHOLE bundle came from a holder of the private key; signing a tombstone proves a
// specific deletion is genuine. Keys are distributed out of band; this package provides
// only the primitives + the wire format.
//
// Signature token wire format:  ed25519:<publicKeyHex>:<signatureHex>
// The public key travels with the signature so a verifier can select which trusted key
// to check against — but verification only succeeds when that key is in the caller's
// trusted set, so a self-signed swap is rejected.

/// An Ed25519 private (signing) key, carried as raw bytes so the type stays `Sendable`.
public struct PortableSigningKey: Sendable {
    public let rawRepresentation: Data

    /// Generate a fresh key.
    public init() { self.rawRepresentation = Curve25519.Signing.PrivateKey().rawRepresentation }
    /// Reconstruct from a stored 32-byte raw representation.
    public init(rawRepresentation: Data) { self.rawRepresentation = rawRepresentation }

    public var verifyingKey: PortableVerifyingKey {
        let raw = (try? Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation))?
            .publicKey.rawRepresentation ?? Data()
        return PortableVerifyingKey(rawRepresentation: raw)
    }

    func signature(for data: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation).signature(for: data)
    }
}

/// An Ed25519 public (verifying) key, carried as raw bytes (`Sendable`, `Equatable`).
public struct PortableVerifyingKey: Sendable, Equatable {
    public let rawRepresentation: Data
    public init(rawRepresentation: Data) { self.rawRepresentation = rawRepresentation }

    public var hex: String { Hex.encode(rawRepresentation) }

    func isValid(_ signature: Data, for data: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawRepresentation) else { return false }
        return key.isValidSignature(signature, for: data)
    }
}

public enum PortableSigning {
    /// Produce a detached signature TOKEN (`ed25519:<pubHex>:<sigHex>`) over `data`.
    public static func detachedToken(for data: Data, key: PortableSigningKey) throws -> String {
        let sig = try key.signature(for: data)
        return "ed25519:\(key.verifyingKey.hex):\(Hex.encode(sig))"
    }

    /// Verify a detached signature token over `data`. Succeeds only when the token's
    /// embedded public key is present in `trusted` AND the signature checks out. An empty
    /// `trusted` set fails closed (nothing is trusted, so nothing verifies).
    public static func verify(token: String, for data: Data, trusted: [PortableVerifyingKey]) -> Bool {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "ed25519",
              let pub = Hex.decode(String(parts[1])), let sig = Hex.decode(String(parts[2])) else { return false }
        let vk = PortableVerifyingKey(rawRepresentation: pub)
        guard trusted.contains(vk) else { return false }
        return vk.isValid(sig, for: data)
    }
}

/// Signing helpers for the portable deletion record (L3). The signature covers the
/// tombstone's canonical bytes with the `signature` field itself absent.
public extension Tombstone {
    func signed(by key: PortableSigningKey) throws -> Tombstone {
        var unsigned = self; unsigned.signature = nil
        let data = try MemCodec.encoder.encode(unsigned)
        var out = self
        out.signature = try PortableSigning.detachedToken(for: data, key: key)
        return out
    }

    func signatureIsValid(trusted: [PortableVerifyingKey]) -> Bool {
        guard let signature else { return false }
        var unsigned = self; unsigned.signature = nil
        guard let data = try? MemCodec.encoder.encode(unsigned) else { return false }
        return PortableSigning.verify(token: signature, for: data, trusted: trusted)
    }
}

enum Hex {
    static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
    static func decode(_ string: String) -> Data? {
        let chars = Array(string)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            out.append(UInt8(hi << 4 | lo))
            i += 2
        }
        return out
    }
}
