import CoreMedia
import XCTest
@testable import Glance

final class RecordingTimelineTests: XCTestCase {
    private func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000) }

    func testNothingBeforeStart() {
        var timeline = RecordingTimeline()
        XCTAssertNil(timeline.outputTime(for: t(5)))
        timeline.start(at: t(10))
        XCTAssertNil(timeline.outputTime(for: t(9.99)), "samples captured before start are dropped")
        XCTAssertEqual(timeline.outputTime(for: t(10)), .zero)
        XCTAssertEqual(timeline.outputTime(for: t(12.5))?.seconds ?? -1, 2.5, accuracy: 1e-6)
    }

    func testPauseRemovesGap() {
        var timeline = RecordingTimeline()
        timeline.start(at: t(100))
        XCTAssertTrue(timeline.pause(at: t(103)))
        XCTAssertNil(timeline.outputTime(for: t(104)), "samples inside a pause are dropped")
        XCTAssertTrue(timeline.resume(at: t(110)))
        XCTAssertEqual(timeline.outputTime(for: t(110))?.seconds ?? -1, 3, accuracy: 1e-6)
        XCTAssertEqual(timeline.outputTime(for: t(111))?.seconds ?? -1, 4, accuracy: 1e-6)
    }

    func testLateSampleFromBeforePauseKeepsOriginalPosition() {
        // A buffer captured before the pause but delivered after resume (out-of-order arrival).
        var timeline = RecordingTimeline()
        timeline.start(at: t(0))
        timeline.pause(at: t(5))
        timeline.resume(at: t(9))
        XCTAssertEqual(timeline.outputTime(for: t(4.9))?.seconds ?? -1, 4.9, accuracy: 1e-6)
    }

    func testMultiplePauses() {
        var timeline = RecordingTimeline()
        timeline.start(at: t(0))
        timeline.pause(at: t(2)); timeline.resume(at: t(3))
        timeline.pause(at: t(5)); timeline.resume(at: t(10))
        XCTAssertEqual(timeline.outputTime(for: t(11))?.seconds ?? -1, 5, accuracy: 1e-6)
        XCTAssertEqual(timeline.recordedDuration(at: t(12)).seconds, 6, accuracy: 1e-6)
    }

    func testRecordedDurationWhilePaused() {
        var timeline = RecordingTimeline()
        timeline.start(at: t(0))
        timeline.pause(at: t(4))
        XCTAssertTrue(timeline.isPaused)
        XCTAssertEqual(timeline.recordedDuration(at: t(60)).seconds, 4, accuracy: 1e-6)
    }

    func testInvalidPauseResumeSequences() {
        var timeline = RecordingTimeline()
        XCTAssertFalse(timeline.pause(at: t(1)), "can't pause before start")
        timeline.start(at: t(10))
        XCTAssertFalse(timeline.resume(at: t(11)), "can't resume when not paused")
        XCTAssertFalse(timeline.pause(at: t(9)), "can't pause before start time")
        XCTAssertTrue(timeline.pause(at: t(12)))
        XCTAssertFalse(timeline.pause(at: t(13)), "double pause is ignored")
        XCTAssertFalse(timeline.resume(at: t(11)), "can't resume before pausing")
        XCTAssertTrue(timeline.resume(at: t(14)))
        XCTAssertFalse(timeline.pause(at: t(13.5)), "can't pause in the past")
    }

    func testOutputIsMonotonicAcrossPause() {
        var timeline = RecordingTimeline()
        timeline.start(at: t(0))
        timeline.pause(at: t(1)); timeline.resume(at: t(3))
        let before = timeline.outputTime(for: t(0.99))!
        let after = timeline.outputTime(for: t(3.0))!
        XCTAssertLessThan(before, after)
    }
}
