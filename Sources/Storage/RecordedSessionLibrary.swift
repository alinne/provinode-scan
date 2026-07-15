import Foundation
import ProvinodeRoomContracts
import UIKit

struct RecordedSessionSummary: Identifiable, Equatable, Sendable {
    let id: String
    let sessionId: String
    let sourceDeviceId: String
    let captureStartedAtUtc: String
    let captureEndedAtUtc: String
    let sampleCount: Int64
    let blobCount: Int64
    let exported: Bool
    let integrityStatus: String
    let sessionDirectory: URL
    let exportPath: URL?
    let observedSurfaceAreaSquareMeters: Double
    let roomWidthMeters: Double
    let roomLengthMeters: Double
    let roomHeightMeters: Double

    var durationSummary: String {
        guard let started = ISO8601DateFormatter.recordedSessionFractional.date(from: captureStartedAtUtc),
              let ended = ISO8601DateFormatter.recordedSessionFractional.date(from: captureEndedAtUtc)
        else {
            return "-"
        }

        return String(format: "%.1fs", max(0, ended.timeIntervalSince(started)))
    }

    var roomSizeSummary: String {
        guard roomWidthMeters > 0, roomLengthMeters > 0 else { return "Spatial bounds unavailable" }
        return String(format: "%.1f × %.1f × %.1f m", roomWidthMeters, roomLengthMeters, roomHeightMeters)
    }
}

enum RecordedSessionLibrary {
    struct SyncFile: Sendable {
        let descriptor: FinalizedCaptureUploadFile
        let url: URL
    }

    static func sessionsDirectory(rootDirectory: URL? = nil) throws -> URL {
        if let rootDirectory {
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            return rootDirectory
        }

        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        return base.appending(path: "ProvinodeScan/Sessions", directoryHint: .isDirectory)
    }

    static func exportDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("RoomCaptureExports", isDirectory: true)
    }

    static func list(rootDirectory: URL? = nil) throws -> [RecordedSessionSummary] {
        let root = try sessionsDirectory(rootDirectory: rootDirectory)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }

        return try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap(readSummary(at:))
            .sorted { $0.captureStartedAtUtc > $1.captureStartedAtUtc }
    }

    static func exportSummary(for sessionDirectory: URL) -> URL? {
        let path = exportDirectory()
            .appendingPathComponent("\(sessionDirectory.lastPathComponent).roomcapture", isDirectory: true)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    static func previewImage(for session: RecordedSessionSummary) -> UIImage? {
        let samplesUrl = session.sessionDirectory.appendingPathComponent("samples.log", conformingTo: .text)
        guard let content = try? String(contentsOf: samplesUrl, encoding: .utf8) else { return nil }

        for line in content.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(RoomCaptureSampleIndexEntry.self, from: data),
                  entry.sample_kind == .keyframeRgb
            else { continue }
            let imageUrl = session.sessionDirectory.appendingPathComponent(entry.blob_path)
            guard let imageData = try? Data(contentsOf: imageUrl) else { continue }
            return UIImage(data: imageData)
        }
        return nil
    }

    static func syncFiles(for session: RecordedSessionSummary) throws -> [SyncFile] {
        let root = session.sessionDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else {
            throw NSError(domain: "RecordedSessionLibrary", code: 5101, userInfo: [NSLocalizedDescriptionKey: "Could not enumerate the capture package."])
        }

        let urls = enumerator.compactMap { $0 as? URL }.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.path < $1.path }

        return try urls.enumerated().map { index, url in
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/") else {
                throw NSError(domain: "RecordedSessionLibrary", code: 5102, userInfo: [NSLocalizedDescriptionKey: "A capture file escaped the session directory."])
            }
            let relativePath = String(resolved.path.dropFirst(root.path.count + 1))
            let values = try resolved.resourceValues(forKeys: [.fileSizeKey])
            return SyncFile(
                descriptor: FinalizedCaptureUploadFile(
                    file_id: String(format: "%08d", index),
                    relative_path: relativePath,
                    byte_size: Int64(values.fileSize ?? 0),
                    sha256: try Sha256.hex(ofFile: resolved)),
                url: resolved)
        }
    }

    private static func readSummary(at sessionDirectory: URL) -> RecordedSessionSummary? {
        let manifestUrl = sessionDirectory.appendingPathComponent("session.manifest.json", conformingTo: .json)
        let integrityUrl = sessionDirectory.appendingPathComponent("integrity.json", conformingTo: .json)
        guard let manifestData = try? Data(contentsOf: manifestUrl),
              let manifest = try? JSONDecoder().decode(RoomCaptureSessionManifest.self, from: manifestData)
        else {
            return nil
        }

        let integrityStatus: String
        if let integrityData = try? Data(contentsOf: integrityUrl),
           let integrity = try? JSONDecoder().decode(SessionIntegrityManifest.self, from: integrityData)
        {
            integrityStatus = integrity.manifest_sha256 == Sha256.hex(of: manifestData) ? "verified" : "hash_mismatch"
        } else {
            integrityStatus = "missing"
        }

        let exportPath = exportSummary(for: sessionDirectory)
        return RecordedSessionSummary(
            id: manifest.session_id,
            sessionId: manifest.session_id,
            sourceDeviceId: manifest.source_device_id,
            captureStartedAtUtc: manifest.capture_started_at_utc,
            captureEndedAtUtc: manifest.capture_ended_at_utc,
            sampleCount: manifest.sample_count,
            blobCount: manifest.blob_count,
            exported: exportPath != nil,
            integrityStatus: integrityStatus,
            sessionDirectory: sessionDirectory,
            exportPath: exportPath,
            observedSurfaceAreaSquareMeters: Double(manifest.metadata?["observed_surface_area_m2"] ?? "") ?? 0,
            roomWidthMeters: Double(manifest.metadata?["room_width_m"] ?? "") ?? 0,
            roomLengthMeters: Double(manifest.metadata?["room_length_m"] ?? "") ?? 0,
            roomHeightMeters: Double(manifest.metadata?["room_height_m"] ?? "") ?? 0)
    }
}

private extension ISO8601DateFormatter {
    static var recordedSessionFractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
