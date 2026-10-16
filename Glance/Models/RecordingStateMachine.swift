import Foundation

enum RecordingPhase: Equatable {
    case idle
    case countingDown(remaining: Int)
    case starting
    case recording
    case paused
    case finishing

    /// True while a capture session exists or is being created/torn down.
    var isBusy: Bool { self != .idle }
    var isCapturing: Bool { self == .recording || self == .paused }

    var statusText: String {
        switch self {
        case .idle: return "Ready"
        case .countingDown(let remaining): return "Starting in \(remaining)…"
        case .starting: return "Starting…"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .finishing: return "Saving…"
        }
    }
}

enum RecordingEvent: Equatable {
    case requestStart(countdown: Int)
    case countdownTick
    case cancelCountdown
    case captureDidStart
    case pause
    case resume
    case stop
    case finishDidComplete
    case failure
}

/// Pure state machine guarding every recording transition. Rejected events are no-ops, which is
/// what prevents duplicate starts, double stops and pause/resume races from the UI or hotkeys.
struct RecordingStateMachine: Equatable {
    private(set) var phase: RecordingPhase = .idle

    @discardableResult
    mutating func handle(_ event: RecordingEvent) -> Bool {
        guard let next = Self.transition(from: phase, on: event) else { return false }
        phase = next
        return true
    }

    static func transition(from phase: RecordingPhase, on event: RecordingEvent) -> RecordingPhase? {
        switch (phase, event) {
        case (.idle, .requestStart(let countdown)):
            return countdown > 0 ? .countingDown(remaining: countdown) : .starting
        case (.countingDown(let remaining), .countdownTick):
            return remaining > 1 ? .countingDown(remaining: remaining - 1) : .starting
        case (.countingDown, .cancelCountdown), (.countingDown, .failure):
            return .idle
        case (.starting, .captureDidStart):
            return .recording
        case (.starting, .failure):
            return .idle
        case (.recording, .pause):
            return .paused
        case (.paused, .resume):
            return .recording
        case (.recording, .stop), (.paused, .stop):
            return .finishing
        case (.recording, .failure), (.paused, .failure):
            // Whatever was captured is still finalized.
            return .finishing
        case (.finishing, .finishDidComplete), (.finishing, .failure):
            return .idle
        default:
            return nil
        }
    }
}
