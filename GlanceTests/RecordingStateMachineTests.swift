import XCTest
@testable import Glance

final class RecordingStateMachineTests: XCTestCase {
    func testFullLifecycleWithCountdown() {
        var machine = RecordingStateMachine()
        XCTAssertTrue(machine.handle(.requestStart(countdown: 3)))
        XCTAssertEqual(machine.phase, .countingDown(remaining: 3))
        XCTAssertTrue(machine.handle(.countdownTick))
        XCTAssertEqual(machine.phase, .countingDown(remaining: 2))
        XCTAssertTrue(machine.handle(.countdownTick))
        XCTAssertTrue(machine.handle(.countdownTick))
        XCTAssertEqual(machine.phase, .starting)
        XCTAssertTrue(machine.handle(.captureDidStart))
        XCTAssertEqual(machine.phase, .recording)
        XCTAssertTrue(machine.handle(.pause))
        XCTAssertEqual(machine.phase, .paused)
        XCTAssertTrue(machine.handle(.resume))
        XCTAssertTrue(machine.handle(.stop))
        XCTAssertEqual(machine.phase, .finishing)
        XCTAssertTrue(machine.handle(.finishDidComplete))
        XCTAssertEqual(machine.phase, .idle)
    }

    func testZeroCountdownStartsImmediately() {
        var machine = RecordingStateMachine()
        machine.handle(.requestStart(countdown: 0))
        XCTAssertEqual(machine.phase, .starting)
    }

    func testDuplicateStartIsRejected() {
        var machine = RecordingStateMachine()
        XCTAssertTrue(machine.handle(.requestStart(countdown: 0)))
        XCTAssertFalse(machine.handle(.requestStart(countdown: 0)))
        machine.handle(.captureDidStart)
        XCTAssertFalse(machine.handle(.requestStart(countdown: 3)))
        XCTAssertEqual(machine.phase, .recording)
    }

    func testDoubleStopIsRejected() {
        var machine = RecordingStateMachine()
        machine.handle(.requestStart(countdown: 0))
        machine.handle(.captureDidStart)
        XCTAssertTrue(machine.handle(.stop))
        XCTAssertFalse(machine.handle(.stop))
        XCTAssertEqual(machine.phase, .finishing)
    }

    func testPauseResumeOnlyInValidStates() {
        var machine = RecordingStateMachine()
        XCTAssertFalse(machine.handle(.pause))
        XCTAssertFalse(machine.handle(.resume))
        machine.handle(.requestStart(countdown: 0))
        XCTAssertFalse(machine.handle(.pause), "can't pause before capture starts")
        machine.handle(.captureDidStart)
        XCTAssertFalse(machine.handle(.resume))
        XCTAssertTrue(machine.handle(.pause))
        XCTAssertFalse(machine.handle(.pause))
        machine.handle(.stop)
        XCTAssertFalse(machine.handle(.resume), "can't resume while finishing")
    }

    func testCancelCountdownReturnsToIdle() {
        var machine = RecordingStateMachine()
        machine.handle(.requestStart(countdown: 5))
        machine.handle(.countdownTick)
        XCTAssertTrue(machine.handle(.cancelCountdown))
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertFalse(machine.handle(.countdownTick))
    }

    func testFailureWhileStartingReturnsToIdle() {
        var machine = RecordingStateMachine()
        machine.handle(.requestStart(countdown: 0))
        XCTAssertTrue(machine.handle(.failure))
        XCTAssertEqual(machine.phase, .idle)
    }

    func testFailureWhileRecordingStillFinalizes() {
        var machine = RecordingStateMachine()
        machine.handle(.requestStart(countdown: 0))
        machine.handle(.captureDidStart)
        machine.handle(.pause)
        XCTAssertTrue(machine.handle(.failure))
        XCTAssertEqual(machine.phase, .finishing)
    }

    func testStopDuringCountdownIsRejected() {
        var machine = RecordingStateMachine()
        machine.handle(.requestStart(countdown: 3))
        XCTAssertFalse(machine.handle(.stop))
        XCTAssertFalse(machine.handle(.captureDidStart))
    }

    func testPhaseFlags() {
        XCTAssertFalse(RecordingPhase.idle.isBusy)
        XCTAssertTrue(RecordingPhase.starting.isBusy)
        XCTAssertTrue(RecordingPhase.paused.isCapturing)
        XCTAssertFalse(RecordingPhase.finishing.isCapturing)
    }
}
