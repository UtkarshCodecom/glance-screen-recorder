import Foundation

enum RecorderError: LocalizedError, Equatable {
    case screenPermissionDenied
    case noDisplayAvailable
    case sourceUnavailable(String)
    case insufficientDiskSpace(availableBytes: Int64)
    case outputDirectoryUnavailable(String)
    case captureStartTimedOut
    case captureFailed(String)
    case writerFailed(String)
    case noVideoFrames
    case exportFailed(String)
    case verificationFailed(String)
    case cameraUnavailable(String)
    case microphoneUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .screenPermissionDenied: return "Screen Recording permission is required"
        case .noDisplayAvailable: return "No display is available to record"
        case .sourceUnavailable: return "The selected screen source is no longer available"
        case .insufficientDiskSpace: return "Not enough disk space"
        case .outputDirectoryUnavailable: return "Can't save to the recordings folder"
        case .captureStartTimedOut: return "Screen capture didn't start"
        case .captureFailed: return "Screen capture stopped unexpectedly"
        case .writerFailed: return "The video couldn't be written"
        case .noVideoFrames: return "Nothing was recorded"
        case .exportFailed: return "The recording couldn't be finalized"
        case .verificationFailed: return "The saved recording failed verification"
        case .cameraUnavailable: return "The camera couldn't start"
        case .microphoneUnavailable: return "The microphone couldn't start"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .screenPermissionDenied:
            return "Open System Settings › Privacy & Security › Screen & System Audio Recording, enable Glance, then quit and reopen Glance.\n\nAlready enabled? macOS ties this permission to the exact app build. Select Glance in that list, remove it with the − button, then reopen Glance and allow it again."
        case .noDisplayAvailable:
            return "Connect or wake a display and try again."
        case .sourceUnavailable(let detail):
            return "\(detail) Pick another display or window."
        case .insufficientDiskSpace(let available):
            let formatted = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Only \(formatted) is free. Free up space or choose another recordings folder in Settings."
        case .outputDirectoryUnavailable(let detail):
            return "\(detail) Choose another folder in Settings › General."
        case .captureStartTimedOut:
            return "macOS didn't deliver any screen frames. Check Screen Recording permission and try again."
        case .captureFailed(let detail), .writerFailed(let detail), .exportFailed(let detail),
             .verificationFailed(let detail), .cameraUnavailable(let detail), .microphoneUnavailable(let detail):
            return detail
        case .noVideoFrames:
            return "The recording ended before any frames were captured."
        }
    }
}
