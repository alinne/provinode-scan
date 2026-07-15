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
        let sessionDirectory = try await recorder.finalize(extraMetadata: [
            "observed_surface_area_m2": "14.25",
            "room_width_m": "4.5",
            "room_length_m": "3.25",
            "room_height_m": "2.7"
        ])
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
        XCTAssertEqual(session.observedSurfaceAreaSquareMeters, 14.25, accuracy: 0.001)
        XCTAssertEqual(session.roomWidthMeters, 4.5, accuracy: 0.001)
        XCTAssertEqual(session.roomLengthMeters, 3.25, accuracy: 0.001)
        XCTAssertEqual(session.roomHeightMeters, 2.7, accuracy: 0.001)
        XCTAssertEqual(session.roomSizeSummary, "4.5 × 3.2 × 2.7 m")

        let syncFiles = try RecordedSessionLibrary.syncFiles(for: session)
        let filesByPath = Dictionary(uniqueKeysWithValues: syncFiles.map { ($0.descriptor.relative_path, $0) })
        XCTAssertNotNil(filesByPath["session.manifest.json"])
        XCTAssertNotNil(filesByPath["samples.log"])
        XCTAssertNotNil(filesByPath["integrity.json"])
        for file in syncFiles {
            XCTAssertEqual(file.descriptor.byte_size, Int64(try Data(contentsOf: file.url).count))
            XCTAssertEqual(file.descriptor.sha256, try Sha256.hex(ofFile: file.url))
            XCTAssertEqual(file.descriptor.sha256.count, 64)
        }
    }
}
