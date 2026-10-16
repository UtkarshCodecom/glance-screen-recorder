import AVFoundation
import XCTest
@testable import Glance

final class AudioClockAlignerTests: XCTestCase {
    private func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000) }
    private let tenMs = CMTime(value: 480, timescale: 48_000)

    func testHostClockSourceIsUntouched() {
        var aligner = AudioClockAligner()
        // Buffer stamped 1000.000 s, 10 ms long, arriving 30 ms later: normal capture latency.
        XCTAssertEqual(aligner.hostTime(for: t(1000), duration: tenMs, arrivedAt: t(1000.04)), t(1000))
        XCTAssertFalse(aligner.isRealigned)
        XCTAssertEqual(aligner.hostTime(for: t(1000.01), duration: tenMs, arrivedAt: t(1000.05)), t(1000.01))
    }

    func testForeignClockIsReanchoredConsistently() {
        var aligner = AudioClockAligner()
        // Stamped near zero (another clock) while the host clock reads 5000 s.
        let first = aligner.hostTime(for: t(2.0), duration: tenMs, arrivedAt: t(5000.03))
        XCTAssertTrue(aligner.isRealigned)
        XCTAssertEqual(first.seconds, 5000.02, accuracy: 1e-6)
        // Later buffers keep their spacing: one buffer later maps to exactly 10 ms later.
        let second = aligner.hostTime(for: t(2.01), duration: tenMs, arrivedAt: t(5000.2))
        XCTAssertEqual((second - first).seconds, 0.01, accuracy: 1e-5, "within one audio sample (20.8 µs)")
    }

    func testInvalidDurationStillAligns() {
        var aligner = AudioClockAligner()
        let host = aligner.hostTime(for: t(1), duration: .invalid, arrivedAt: t(900))
        XCTAssertEqual(host.seconds, 900, accuracy: 1e-6)
    }

    func testReanchoredSamplesLandInsideTheTimeline() {
        // Regression: buffers on a foreign clock used to be dropped as "before start", silencing the mic.
        var timeline = RecordingTimeline()
        timeline.start(at: t(5000))
        XCTAssertNil(timeline.outputTime(for: t(2.5)), "unaligned timestamp would be dropped")
        var aligner = AudioClockAligner()
        let aligned = aligner.hostTime(for: t(2.5), duration: tenMs, arrivedAt: t(5001.01))
        XCTAssertEqual(timeline.outputTime(for: aligned)?.seconds ?? -1, 1.0, accuracy: 1e-6)
    }

    func testStatsSummaryAndSignal() {
        var stats = AudioSourceStats()
        XCTAssertFalse(stats.hasAudibleSignal)
        stats.received = 3
        stats.peakRMS = 0.02
        XCTAssertTrue(stats.hasAudibleSignal)
        XCTAssertTrue(stats.summary.contains("received=3"))
    }

    func testSourceRoles() {
        XCTAssertEqual(AudioSource.system.role, .system)
        XCTAssertEqual(AudioSource.screenCaptureKitMicrophone.role, .microphone)
        XCTAssertEqual(AudioSource.fallbackMicrophone.role, .microphone)
    }

    func testSystemDefaultInputMatchesACaptureDevice() throws {
        guard let uid = DeviceManager.systemDefaultInputUID() else {
            throw XCTSkip("No default input device on this machine")
        }
        let ids = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                                   position: .unspecified).devices.map(\.uniqueID)
        XCTAssertTrue(ids.contains(uid), "Core Audio default input UID should be usable as an AVCaptureDevice uniqueID")
    }
}
