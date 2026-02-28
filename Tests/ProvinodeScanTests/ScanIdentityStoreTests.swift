import CryptoKit
import XCTest
@testable import ProvinodeScan

final class ScanIdentityStoreTests: XCTestCase {
    func testIdentityPersistsAcrossReloads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store1 = try ScanIdentityStore(rootDirectory: root)
        let identity1 = store1.material()

        let store2 = try ScanIdentityStore(rootDirectory: root)
        let identity2 = store2.material()

        XCTAssertEqual(identity1.deviceId, identity2.deviceId)
        XCTAssertEqual(identity1.certFingerprintSha256, identity2.certFingerprintSha256)
        XCTAssertEqual(identity1.signingPublicKeyB64, identity2.signingPublicKeyB64)
        XCTAssertEqual(identity1.signingPrivateKeyRawB64, identity2.signingPrivateKeyRawB64)
    }

    func testClientTlsIdentityPersistsAcrossReloads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-mtls-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store1 = try ScanIdentityStore(rootDirectory: root)
        XCTAssertNil(store1.clientTlsIdentity())

        try store1.persistClientTlsIdentity(
            pkcs12Data: Data([0x01, 0x02, 0x03]),
            password: "secret",
            certFingerprintSha256: String(repeating: "a", count: 64))

        let store2 = try ScanIdentityStore(rootDirectory: root)
        let mtls = store2.clientTlsIdentity()
        XCTAssertNotNil(mtls)
        XCTAssertEqual(mtls?.pkcs12Data, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(mtls?.password, "secret")
        XCTAssertEqual(mtls?.certFingerprintSha256, String(repeating: "a", count: 64))

        let rawFile = try String(contentsOf: root.appendingPathComponent("scan-identity.json"), encoding: .utf8)
        XCTAssertFalse(rawFile.contains("secret"))
        XCTAssertFalse(rawFile.contains("AQID")) // base64(0x01,0x02,0x03)
        XCTAssertTrue(rawFile.contains("client_tls_encrypted_blob_b64"))
    }

    func testLegacyClientTlsFieldsAreMigratedToEncryptedBlob() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-mtls-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileUrl = root.appendingPathComponent("scan-identity.json")
        let privateKeyB64 = P256.Signing.PrivateKey().rawRepresentation.base64EncodedString()
        let legacyJson = """
        {
          "device_id": "01JLEGACYDEVICE00000000000000",
          "signing_private_key_raw_b64": "\(privateKeyB64)",
          "client_tls_pkcs12_b64": "AQID",
          "client_tls_password": "legacy-secret",
          "client_tls_cert_fingerprint_sha256": "\(String(repeating: "b", count: 64))"
        }
        """
        guard let legacyData = legacyJson.data(using: .utf8) else {
            XCTFail("Could not encode legacy fixture JSON.")
            return
        }
        try legacyData.write(to: fileUrl, options: .atomic)

        let store = try ScanIdentityStore(rootDirectory: root)
        let mtls = store.clientTlsIdentity()
        XCTAssertNotNil(mtls)
        XCTAssertEqual(mtls?.pkcs12Data, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(mtls?.password, "legacy-secret")
        XCTAssertEqual(mtls?.certFingerprintSha256, String(repeating: "b", count: 64))

        let migrated = try String(contentsOf: fileUrl, encoding: .utf8)
        XCTAssertTrue(migrated.contains("client_tls_encrypted_blob_b64"))
        XCTAssertFalse(migrated.contains("legacy-secret"))
        XCTAssertFalse(migrated.contains("\"client_tls_pkcs12_b64\" : \"AQID\""))
    }
}
