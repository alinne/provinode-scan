import Foundation
import ProvinodeRoomContracts
@testable import ProvinodeScan
import XCTest

final class SessionRecorderTests: XCTestCase {
    func testRecorderWritesManifestAndIntegrity() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sessionId = ULID.generate()
        let recorder = try SessionRecorder(
            sessionId: sessionId,
            sourceDeviceId: "test-device",
            producerVersion: "0.1.0",
            rootDirectory: tempRoot)

        let payload = Data("payload".utf8)
        let hash = Sha256.hex(of: payload)

        let envelope = CaptureSampleEnvelope(
            session_id: sessionId,
            sample_seq: 0,
            capture_time_ns: 123,
            clock_id: "test-clock",
            sample_kind: .heartbeat,
            hash_sha256: hash,
            payload_ref: "blobs/sha256/\(hash)",
            metadata: nil)

        try await recorder.record(envelope: envelope, payload: payload)
        let sessionDirectory = try await recorder.finalize(extraMetadata: [
            RoomMetadataKeys.pairedPeerDeviceId: "desktop-1",
            RoomMetadataKeys.pairedPeerCertFingerprintSha256: String(repeating: "f", count: 64)
        ])

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent("session.manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent("integrity.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent("samples.log").path))

        let manifestData = try Data(contentsOf: sessionDirectory.appendingPathComponent("session.manifest.json"))
        let manifest = try JSONDecoder().decode(RoomCaptureSessionManifest.self, from: manifestData)
        XCTAssertEqual(manifest.metadata?[RoomMetadataKeys.roomSessionId], sessionId)
        XCTAssertEqual(manifest.metadata?[RoomMetadataKeys.sourceDeviceId], "test-device")
        XCTAssertEqual(manifest.metadata?[RoomMetadataKeys.pairedPeerDeviceId], "desktop-1")
        XCTAssertEqual(
            manifest.metadata?[RoomMetadataKeys.pairedPeerCertFingerprintSha256],
            String(repeating: "f", count: 64))
    }

    func testUlidHasExpectedLength() {
        XCTAssertEqual(ULID.generate().count, 26)
    }
}
