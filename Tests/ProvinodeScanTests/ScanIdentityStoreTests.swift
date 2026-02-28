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
    }
}
