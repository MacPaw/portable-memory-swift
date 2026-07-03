import XCTest
@testable import PortableMemory

/// Loads the shared, language-neutral conformance vectors in `Conformance/vectors/`
/// (byte-identical to the Python repo) and proves this SDK reproduces them. The vectors
/// are the cross-implementation oracle: if canonicalization drifts, this fails at once.
final class ConformanceVectorsTests: XCTestCase {

    private var vectorsDir: URL {
        // Tests/PortableMemoryTests/<this> → repo root is three levels up.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Conformance/vectors")
    }

    private struct Vector: Decodable { let name: String; let input: JSONValue; let canonical: String; let sha256: String }
    private struct Doc: Decodable { let vectors: [Vector] }
    private struct Key: Decodable { let publicKeyHex: String; let privateKeyHex: String }

    private func hex(_ s: String) -> Data {
        var d = Data(); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return d
    }

    func testCanonicalJSONVectors() throws {
        let data = try Data(contentsOf: vectorsDir.appendingPathComponent("canonical-json.json"))
        let doc = try JSONDecoder().decode(Doc.self, from: data)
        XCTAssertFalse(doc.vectors.isEmpty, "no vectors loaded")
        for v in doc.vectors {
            let out = String(decoding: try MemCodec.encoder.encode(v.input), as: UTF8.self)
            XCTAssertEqual(out, v.canonical, "vector: \(v.name)")
            XCTAssertEqual(Hashing.sha256Hex(Data(out.utf8)), v.sha256, "vector sha: \(v.name)")
        }
    }

    func testSignedFixtureVerifiesAndRejects() throws {
        let key = try JSONDecoder().decode(Key.self,
            from: Data(contentsOf: vectorsDir.appendingPathComponent("signing-test-key.json")))
        let signed = vectorsDir.appendingPathComponent("signed.mem")
        let trusted = PortableVerifyingKey(rawRepresentation: hex(key.publicKeyHex))
        let wrong = PortableSigningKey().verifyingKey
        XCTAssertTrue(BundleValidator().validate(bundle: signed, trustedKeys: [trusted]).ok)
        XCTAssertFalse(BundleValidator().validate(bundle: signed, trustedKeys: [wrong]).ok)
    }

    func testSignedFixtureSignVerifyRoundTrip() throws {
        let key = try JSONDecoder().decode(Key.self,
            from: Data(contentsOf: vectorsDir.appendingPathComponent("signing-test-key.json")))
        let signing = PortableSigningKey(rawRepresentation: hex(key.privateKeyHex))
        XCTAssertEqual(signing.verifyingKey.hex, key.publicKeyHex)
        let signed = vectorsDir.appendingPathComponent("signed.mem")
        let manifest = try Data(contentsOf: signed.appendingPathComponent("manifest.json"))
        // Signatures are not byte-reproducible across implementations, so verify (not match).
        let token = try PortableSigning.detachedToken(for: manifest, key: signing)
        let trusted = PortableVerifyingKey(rawRepresentation: hex(key.publicKeyHex))
        XCTAssertTrue(PortableSigning.verify(token: token, for: manifest, trusted: [trusted]))
    }
}
