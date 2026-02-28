import ARKit
import CoreImage
import Foundation
import ProvinodeRoomContracts
import UIKit

@MainActor
final class RoomCapturePipeline: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var metrics = ScanSessionMetrics()

    private let session: ARSession
    private let ciContext = CIContext(options: nil)
    private let sequencer = SampleSequencer()
    private let recorder: SessionRecorder
    private let transport: QuicTransportClient?
    private let sessionId: String
    private let sourceDeviceId: String
    private let clockId = "arkit.monotonic.v1"

    private var frameCounter: Int64 = 0
    private var lastKeyframeTimestamp: TimeInterval = 0
    private var lastMeshTimestamp: TimeInterval = 0
    private var keyframeIntervalSec: TimeInterval = 0.25
    private var meshIntervalSec: TimeInterval = 0.8
    private var depthStride = 1
    private var dropNonKeyframes = false

    init(sessionId: String, sourceDeviceId: String, recorder: SessionRecorder, transport: QuicTransportClient?) {
        self.session = ARSession()
        self.recorder = recorder
        self.transport = transport
        self.sessionId = sessionId
        self.sourceDeviceId = sourceDeviceId
        super.init()
        self.session.delegate = self
    }

    func start() throws {
        try DeviceCapabilityPolicy.enforce()

        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics.insert(.sceneDepth)
        configuration.sceneReconstruction = .mesh
        configuration.environmentTexturing = .automatic

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    func stop() async throws -> URL {
        session.pause()
        isRunning = false

        let stopHeartbeatPayload = Data("session_end".utf8)
        await emit(
            kind: .heartbeat,
            captureTimeNs: Int64(DispatchTime.now().uptimeNanoseconds),
            payload: stopHeartbeatPayload,
            metadata: [
                "session_end": "true",
                "frame_counter": String(frameCounter)
            ])

        let summaryMetadata = [
            "samples_total": String(metrics.emittedSamples),
            "samples_dropped": String(metrics.droppedSamples)
        ]
        return try await recorder.finalize(extraMetadata: summaryMetadata)
    }

    func applyBackpressureHint(_ hint: BackpressureHint) {
        keyframeIntervalSec = hint.target_keyframe_fps <= 0 ? 1.0 : max(0.1, 1.0 / Double(hint.target_keyframe_fps))
        depthStride = max(1, hint.depth_stride)
        meshIntervalSec = max(0.1, Double(hint.mesh_update_interval_ms) / 1000.0)
        dropNonKeyframes = hint.drop_non_keyframes
    }

    private func process(frame: ARFrame) async {
        frameCounter += 1
        let captureTimeNs = Int64(frame.timestamp * 1_000_000_000)

        await emitPose(frame: frame, captureTimeNs: captureTimeNs)
        await emitIntrinsics(frame: frame, captureTimeNs: captureTimeNs)

        let shouldEmitKeyframe = frame.timestamp - lastKeyframeTimestamp >= keyframeIntervalSec
        if shouldEmitKeyframe, let keyframePayload = keyframePayload(from: frame.capturedImage) {
            lastKeyframeTimestamp = frame.timestamp
            await emit(kind: .keyframeRgb, captureTimeNs: captureTimeNs, payload: keyframePayload, metadata: ["mime": "image/jpeg"])
            metrics.keyframeCount += 1
        }

        if !dropNonKeyframes,
           frameCounter % Int64(depthStride) == 0,
           let depthPayload = depthPayload(from: frame.sceneDepth?.depthMap)
        {
            await emit(kind: .depthFrame, captureTimeNs: captureTimeNs, payload: depthPayload, metadata: ["format": "depth32f"])
            metrics.depthCount += 1
        }

        if !dropNonKeyframes,
           frame.timestamp - lastMeshTimestamp >= meshIntervalSec,
           let meshPayload = meshPayload(from: frame.anchors) {
            lastMeshTimestamp = frame.timestamp
            await emit(kind: .meshAnchorBatch, captureTimeNs: captureTimeNs, payload: meshPayload, metadata: ["format": "mesh_anchor_batch_v2"])
            metrics.meshCount += 1
        }

        metrics.avgKeyframeFps = metrics.keyframeCount > 0 ? Double(metrics.keyframeCount) / max(frame.timestamp, 1) : 0

        if frameCounter % 30 == 0 {
            let heartbeat = Data("heartbeat".utf8)
            await emit(kind: .heartbeat, captureTimeNs: captureTimeNs, payload: heartbeat, metadata: ["frame_counter": String(frameCounter)])
        }
    }

    private func emitPose(frame: ARFrame, captureTimeNs: Int64) async {
        let transform = frame.camera.transform
        let posePayload = PosePayload(matrix: transform.toArray())
        guard let payload = try? JSONEncoder().encode(posePayload) else { return }
        await emit(kind: .cameraPose, captureTimeNs: captureTimeNs, payload: payload, metadata: nil)
    }

    private func emitIntrinsics(frame: ARFrame, captureTimeNs: Int64) async {
        let intrinsics = IntrinsicsPayload(
            matrix: frame.camera.intrinsics.toArray3x3(),
            resolution: [Int(frame.camera.imageResolution.width), Int(frame.camera.imageResolution.height)])
        guard let payload = try? JSONEncoder().encode(intrinsics) else { return }
        await emit(kind: .intrinsics, captureTimeNs: captureTimeNs, payload: payload, metadata: nil)
    }

    private func emit(kind: CaptureSampleKind, captureTimeNs: Int64, payload: Data, metadata: [String: String]?) async {
        let hash = Sha256.hex(of: payload)
        let sampleSeq = await sequencer.next()

        var metadataWithSource = metadata ?? [:]
        metadataWithSource["source_device_id"] = sourceDeviceId

        let envelope = CaptureSampleEnvelope(
            session_id: sessionId,
            sample_seq: sampleSeq,
            capture_time_ns: captureTimeNs,
            clock_id: clockId,
            sample_kind: kind,
            hash_sha256: hash,
            payload_ref: "blobs/sha256/\(hash)",
            metadata: metadataWithSource)

        do {
            try await recorder.record(envelope: envelope, payload: payload)
            if let transport {
                try await transport.sendSample(envelope: envelope, payload: payload)
            }
            metrics.emittedSamples += 1
        } catch {
            metrics.droppedSamples += 1
            NSLog("Failed to emit sample \(sampleSeq): \(error.localizedDescription)")
        }
    }

    private func keyframePayload(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8)
    }

    private func depthPayload(from depthMap: CVPixelBuffer?) -> Data? {
        guard let depthMap else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let byteCount = bytesPerRow * height
        return Data(bytes: baseAddress, count: byteCount)
    }

    private func meshPayload(from anchors: [ARAnchor]) -> Data? {
        let meshEntries = anchors.compactMap { anchor -> MeshAnchorGeometryPayload? in
            guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
            let vertices = extractMeshVertices(meshAnchor.geometry.vertices)
            let faceIndices = extractFaceIndices(meshAnchor.geometry.faces)
            guard !vertices.isEmpty, !faceIndices.isEmpty else {
                return nil
            }

            return MeshAnchorGeometryPayload(
                identifier: meshAnchor.identifier.uuidString,
                transform: meshAnchor.transform.toArray(),
                vertices: vertices,
                faceIndices: faceIndices)
        }

        guard !meshEntries.isEmpty else { return nil }
        return try? JSONEncoder().encode(meshEntries)
    }

    private func extractMeshVertices(_ source: ARGeometrySource) -> [Float] {
        var result: [Float] = []
        result.reserveCapacity(source.count * 3)

        let baseAddress = source.buffer.contents()
        for index in 0..<source.count {
            let pointer = baseAddress
                .advanced(by: source.offset + source.stride * index)
                .assumingMemoryBound(to: SIMD3<Float>.self)
            let vertex = pointer.pointee
            result.append(vertex.x)
            result.append(vertex.y)
            result.append(vertex.z)
        }

        return result
    }

    private func extractFaceIndices(_ element: ARGeometryElement) -> [UInt32] {
        var result: [UInt32] = []
        let totalIndices = element.count * element.indexCountPerPrimitive
        result.reserveCapacity(totalIndices)

        let baseAddress = element.buffer.contents()
        for index in 0..<totalIndices {
            let offset = index * element.bytesPerIndex
            let pointer = baseAddress.advanced(by: offset)
            switch element.bytesPerIndex {
            case 1:
                result.append(UInt32(pointer.assumingMemoryBound(to: UInt8.self).pointee))
            case 2:
                result.append(UInt32(pointer.assumingMemoryBound(to: UInt16.self).pointee))
            case 4:
                result.append(pointer.assumingMemoryBound(to: UInt32.self).pointee)
            default:
                continue
            }
        }

        return result
    }
}

extension RoomCapturePipeline: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { [weak self] in
            await self?.process(frame: frame)
        }
    }
}

private actor SampleSequencer {
    private var current: Int64 = 0

    func next() -> Int64 {
        defer { current += 1 }
        return current
    }
}

private struct PosePayload: Codable {
    let matrix: [Float]
}

private struct IntrinsicsPayload: Codable {
    let matrix: [Float]
    let resolution: [Int]
}

private struct MeshAnchorGeometryPayload: Codable {
    let identifier: String
    let transform: [Float]
    let vertices: [Float]
    let faceIndices: [UInt32]

    enum CodingKeys: String, CodingKey {
        case identifier
        case transform
        case vertices
        case faceIndices = "face_indices"
    }
}

private extension simd_float4x4 {
    func toArray() -> [Float] {
        [columns.0.x, columns.0.y, columns.0.z, columns.0.w,
         columns.1.x, columns.1.y, columns.1.z, columns.1.w,
         columns.2.x, columns.2.y, columns.2.z, columns.2.w,
         columns.3.x, columns.3.y, columns.3.z, columns.3.w]
    }
}

private extension simd_float3x3 {
    func toArray3x3() -> [Float] {
        [columns.0.x, columns.0.y, columns.0.z,
         columns.1.x, columns.1.y, columns.1.z,
         columns.2.x, columns.2.y, columns.2.z]
    }
}
