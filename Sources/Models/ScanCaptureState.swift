import Foundation

enum ScanCaptureState: String, CaseIterable {
    case unpaired
    case paired
    case ready
    case streaming
    case recording
    case exported
    case error
}
