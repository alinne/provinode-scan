import Foundation

struct ScanSessionMetrics {
    var emittedSamples: Int64 = 0
    var droppedSamples: Int64 = 0
    var keyframeCount: Int64 = 0
    var depthCount: Int64 = 0
    var meshCount: Int64 = 0
    var avgKeyframeFps: Double = 0
    var captureDurationSeconds: Double = 0
    var poseConfidence: Double = 0

    var depthPerKeyframe: Double {
        guard keyframeCount > 0 else { return 0 }
        return Double(depthCount) / Double(keyframeCount)
    }

    var meshPerKeyframe: Double {
        guard keyframeCount > 0 else { return 0 }
        return Double(meshCount) / Double(keyframeCount)
    }

    var depthCoverageScore: Double {
        min(1.0, depthPerKeyframe / 2.8)
    }

    var meshCoverageScore: Double {
        min(1.0, meshPerKeyframe / 0.28)
    }

    var structuralCoverageScore: Double {
        let keyframeSignal = min(1.0, Double(keyframeCount) / 40.0)
        let durationSignal = min(1.0, captureDurationSeconds / 30.0)
        return min(1.0, (depthCoverageScore * 0.35) +
                        (meshCoverageScore * 0.35) +
                        (keyframeSignal * 0.15) +
                        (durationSignal * 0.15))
    }

    var perimeterCoverageScore: Double {
        let keyframeSignal = min(1.0, Double(keyframeCount) / 42.0)
        let durationSignal = min(1.0, captureDurationSeconds / 32.0)
        let fpsSignal = min(1.0, avgKeyframeFps / 4.5)
        return min(1.0, (keyframeSignal * 0.45) +
                        (durationSignal * 0.35) +
                        (fpsSignal * 0.20))
    }

    var twinMatchReadinessScore: Double {
        let poseSignal = min(1.0, max(0.0, poseConfidence))
        return ((structuralCoverageScore * 0.40) +
                (perimeterCoverageScore * 0.25) +
                (poseSignal * 0.20) +
                (meshCoverageScore * 0.15)) * 100.0
    }

    var twinQualityScore: Double {
        let keyframeSignal = min(1.0, Double(keyframeCount) / 36.0)
        let depthSignal = min(1.0, Double(depthCount) / 90.0)
        let meshSignal = min(1.0, Double(meshCount) / 18.0)
        let poseSignal = min(1.0, max(0.0, poseConfidence))
        let durationSignal = min(1.0, captureDurationSeconds / 28.0)
        let balanceSignal = min(1.0, min(depthPerKeyframe / 3.0, max(0.25, meshPerKeyframe / 0.35)))
        return ((keyframeSignal * 0.14) +
                (depthSignal * 0.16) +
                (meshSignal * 0.16) +
                (poseSignal * 0.15) +
                (durationSignal * 0.08) +
                (balanceSignal * 0.09) +
                (structuralCoverageScore * 0.12) +
                (perimeterCoverageScore * 0.10)) * 100.0
    }
}
