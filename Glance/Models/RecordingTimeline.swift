import CoreMedia

/// Maps capture timestamps (host clock) onto the output file's timeline, removing paused spans.
/// Decisions are made from each sample's own presentation time, never its arrival order, so late
/// buffers from any source land in the right place.
struct RecordingTimeline: Equatable {
    struct Pause: Equatable {
        var start: CMTime
        var end: CMTime?
    }

    private(set) var startTime: CMTime?
    private(set) var pauses: [Pause] = []

    var hasStarted: Bool { startTime != nil }
    var isPaused: Bool { pauses.last.map { $0.end == nil } ?? false }

    mutating func start(at time: CMTime) {
        startTime = time
        pauses = []
    }

    @discardableResult
    mutating func pause(at time: CMTime) -> Bool {
        guard let startTime, !isPaused, time >= startTime else { return false }
        if let last = pauses.last, let end = last.end, time < end { return false }
        pauses.append(Pause(start: time, end: nil))
        return true
    }

    @discardableResult
    mutating func resume(at time: CMTime) -> Bool {
        guard isPaused, let open = pauses.last, time >= open.start else { return false }
        pauses[pauses.count - 1].end = time
        return true
    }

    /// Output-timeline position for a host-clock timestamp, or `nil` when the sample must be dropped
    /// (before start or inside a pause).
    func outputTime(for hostTime: CMTime) -> CMTime? {
        guard let startTime, hostTime.isNumeric, hostTime >= startTime else { return nil }
        var offset = CMTime.zero
        for pause in pauses {
            if hostTime < pause.start { break }
            guard let end = pause.end, hostTime >= end else { return nil }
            offset = offset + (end - pause.start)
        }
        return hostTime - startTime - offset
    }

    /// Recorded (unpaused) duration as of `now`.
    func recordedDuration(at now: CMTime) -> CMTime {
        guard let startTime, now >= startTime else { return .zero }
        var paused = CMTime.zero
        for pause in pauses where pause.start <= now {
            let end = min(pause.end ?? now, now)
            paused = paused + (end - pause.start)
        }
        return now - startTime - paused
    }
}

enum HostClock {
    static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }
}
