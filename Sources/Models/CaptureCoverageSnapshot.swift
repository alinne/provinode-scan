import CoreGraphics
import Foundation

struct CaptureCoverageCell: Hashable, Sendable {
    let x: Int
    let z: Int
}

struct CaptureCoverageSnapshot: Equatable, Sendable {
    var observedSurfaceAreaSquareMeters: Double = 0
    var widthMeters: Double = 0
    var lengthMeters: Double = 0
    var heightMeters: Double = 0
    var meshAnchorCount: Int = 0
    var observedCells: Set<CaptureCoverageCell> = []
    var visitedCells: Set<CaptureCoverageCell> = []

    var hasSpatialCoverage: Bool {
        meshAnchorCount > 0 && !observedCells.isEmpty
    }
}
