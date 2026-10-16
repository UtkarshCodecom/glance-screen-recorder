import CoreMedia

/// Keeps one audio source's timestamps on the host clock shared with the screen frames.
///
/// The first buffer decides: if its presentation time is within `tolerance` of its arrival time
/// (minus its own duration), the source is already on the host clock and nothing changes. Otherwise
/// the source uses another clock domain, and every buffer is shifted by the offset measured on that
/// first buffer, so samples are re-anchored instead of being dropped as "before start".
struct AudioClockAligner: Equatable {
    static let tolerance = CMTime(seconds: 1, preferredTimescale: 1_000_000)

    private(set) var offset: CMTime?

    var isRealigned: Bool { (offset ?? .zero) != .zero }

    mutating func hostTime(for presentationTime: CMTime, duration: CMTime, arrivedAt arrival: CMTime) -> CMTime {
        if let offset { return presentationTime + offset }
        let expectedStart = arrival - (duration.isNumeric ? duration : .zero)
        let delta = expectedStart - presentationTime
        let measured = (delta.isNumeric && CMTimeAbsoluteValue(delta) > Self.tolerance) ? delta : .zero
        offset = measured
        return presentationTime + measured
    }
}

/// Per-source audio counters used for health checks and the end-of-recording diagnostics log.
struct AudioSourceStats: Equatable {
    var received = 0
    var appended = 0
    var droppedOutsideTimeline = 0
    var rejectedByWriter = 0
    var peakRMS: Float = 0
    var clockOffsetSeconds: Double = 0

    var hasAudibleSignal: Bool { peakRMS > 0 }

    var summary: String {
        String(format: "received=%d appended=%d dropped(timeline)=%d rejected(writer)=%d peakRMS=%.4f clockOffset=%.3fs",
               received, appended, droppedOutsideTimeline, rejectedByWriter, peakRMS, clockOffsetSeconds)
    }
}
