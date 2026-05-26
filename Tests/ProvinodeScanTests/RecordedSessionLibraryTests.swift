import Foundation
import ProvinodeRoomContracts
@testable import ProvinodeScan
import XCTest

final class RecordedSessionLibraryTests: XCTestCase {
    func testLibraryListsRecordedSessionsAndExportStatus() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sessionId = ULID.generate()
        let recorder = try SessionRecorder(
            sessionId: sessionId,
            sourceDeviceId: "scan-device",
            producerVersion: "0.1.0",
            rootDirectory: tempRoot)
        let payload = Data("payload".utf8)
        let hash = Sha256.hex(of: payload)
        let envelope = CaptureSampleEnvelope(
            session_id: sessionId,
            sample_seq: 0,
            capture_time_ns: 100,
            clock_id: "test-clock",
            sample_kind: .heartbeat,
            hash_sha256: hash,
            payload_ref: "blobs/sha256/\(hash)",
            metadata: nil)

        try await recorder.record(envelope: envelope, payload: payload)
        let sessionDirectory = try await recorder.finalize()
        let exportRoot = RecordedSessionLibrary.exportDirectory()
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let exportPath = exportRoot.appendingPathComponent("\(sessionDirectory.lastPathComponent).roomcapture", isDirectory: true)
        if FileManager.default.fileExists(atPath: exportPath.path) {
            try FileManager.default.removeItem(at: exportPath)
        }
        try FileManager.default.copyItem(at: sessionDirectory, to: exportPath)
        defer { try? FileManager.default.removeItem(at: exportPath) }

        let items = try RecordedSessionLibrary.list(rootDirectory: tempRoot)

        let session = try XCTUnwrap(items.first)
        XCTAssertEqual(session.sessionId, sessionId)
        XCTAssertEqual(session.sourceDeviceId, "scan-device")
        XCTAssertEqual(session.integrityStatus, "verified")
        XCTAssertTrue(session.exported)
        XCTAssertEqual(session.exportPath?.lastPathComponent, "\(sessionId).roomcapture")
    }
}
