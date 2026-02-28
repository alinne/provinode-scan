import Foundation

struct ScanSessionMetrics {
    var emittedSamples: Int64 = 0
    var droppedSamples: Int64 = 0
    var keyframeCount: Int64 = 0
    var depthCount: Int64 = 0
    var meshCount: Int64 = 0
    var avgKeyframeFps: Double = 0
}
