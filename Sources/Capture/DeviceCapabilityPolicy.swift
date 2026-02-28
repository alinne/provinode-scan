import ARKit
import Foundation

enum DeviceCapabilityPolicyError: LocalizedError {
    case unsupportedIos
    case unsupportedDevice

    var errorDescription: String? {
        switch self {
        case .unsupportedIos:
            return "Requires iOS 17.0 or newer."
        case .unsupportedDevice:
            return "Requires a LiDAR-capable iPhone Pro device."
        }
    }
}

struct DeviceCapabilityPolicy {
    static func enforce() throws {
        guard #available(iOS 17.0, *) else {
            throw DeviceCapabilityPolicyError.unsupportedIos
        }

        #if targetEnvironment(simulator)
        // Simulator path uses synthetic capture fixtures for development/testing.
        return
        #else

        guard ARWorldTrackingConfiguration.isSupported else {
            throw DeviceCapabilityPolicyError.unsupportedDevice
        }

        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            throw DeviceCapabilityPolicyError.unsupportedDevice
        }

        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            throw DeviceCapabilityPolicyError.unsupportedDevice
        }
        #endif
    }
}
