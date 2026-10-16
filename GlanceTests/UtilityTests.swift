import CoreMedia
import XCTest
@testable import Glance

final class FileNamerTests: XCTestCase {
    func testBaseNameFormat() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_760_000_000) // 2025-10-09 08:53:20 UTC
        XCTAssertEqual(RecordingFileNamer.baseName(for: date, calendar: calendar), "Glance Recording 2025-10-09 at 08.53.20")
    }

    func testUniqueURLAppendsCounter() {
        let dir = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        let taken: Set<String> = ["/tmp/x/Clip.mp4", "/tmp/x/Clip 2.mp4"]
        let url = RecordingFileNamer.uniqueURL(in: dir, baseName: "Clip") { taken.contains($0.path) }
        XCTAssertEqual(url.lastPathComponent, "Clip 3.mp4")
    }

    func testNameValidation() {
        XCTAssertEqual(RecordingFileNamer.validate("  Demo  "), .valid("Demo"))
        XCTAssertEqual(RecordingFileNamer.validate("   "), .empty)
        XCTAssertEqual(RecordingFileNamer.validate("a/b"), .invalidCharacters)
        XCTAssertEqual(RecordingFileNamer.validate("a:b"), .invalidCharacters)
        XCTAssertEqual(RecordingFileNamer.validate(".hidden"), .invalidCharacters)
        XCTAssertEqual(RecordingFileNamer.validate(String(repeating: "x", count: 300)), .tooLong)
    }
}

final class DiskSpaceTests: XCTestCase {
    func testThresholds() {
        XCTAssertTrue(DiskSpace.hasRoomToStart(availableBytes: nil))
        XCTAssertFalse(DiskSpace.hasRoomToStart(availableBytes: 10_000_000))
        XCTAssertTrue(DiskSpace.hasRoomToStart(availableBytes: 50_000_000_000))
        XCTAssertFalse(DiskSpace.shouldStopRecording(availableBytes: nil))
        XCTAssertTrue(DiskSpace.shouldStopRecording(availableBytes: 100_000_000))
        XCTAssertFalse(DiskSpace.shouldStopRecording(availableBytes: 5_000_000_000))
    }

    func testAvailableBytesForMissingFolderUsesParentVolume() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID())/nested")
        XCTAssertNotNil(DiskSpace.availableBytes(at: missing))
    }
}

final class AudioLevelMeterTests: XCTestCase {
    func testSineRMS() {
        let buffer = TestMedia.sineBuffer(frequency: 1000, amplitude: 0.5, channels: 2, frames: 4800, sampleRate: 48_000,
                                          startFrame: 0, pts: .zero)
        let rms = try! XCTUnwrap(AudioLevelMeter.rms(of: buffer))
        XCTAssertEqual(rms, 0.5 / sqrt(2), accuracy: 0.01)
    }

    func testSilenceAndNormalization() {
        let silent = TestMedia.sineBuffer(frequency: 1000, amplitude: 0, channels: 1, frames: 480, sampleRate: 48_000,
                                          startFrame: 0, pts: .zero)
        XCTAssertEqual(AudioLevelMeter.rms(of: silent), 0)
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: 0), 0)
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: 0.0001), 0)
        let mid = AudioLevelMeter.normalizedLevel(rms: 0.05)
        XCTAssertGreaterThan(mid, 0.2)
        XCTAssertLessThan(mid, 0.8)
    }
}

final class SettingsTests: XCTestCase {
    func testDecodingOldSettingsFillsDefaults() throws {
        let json = #"{"quality":"hd720","countdownSeconds":5}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(RecordingSettings.self, from: json)
        XCTAssertEqual(settings.quality, .hd720)
        XCTAssertEqual(settings.countdownSeconds, 5)
        XCTAssertEqual(settings.frameRate, .fps30)
        XCTAssertTrue(settings.capturesMicrophone)
        XCTAssertEqual(settings.cameraLayout, CameraOverlayLayout())
    }

    func testUnknownEnumValueFallsBack() throws {
        let json = #"{"quality":"8k","codec":"av1"}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(RecordingSettings.self, from: json)
        XCTAssertEqual(settings.quality, .hd1080)
        XCTAssertEqual(settings.codec, .h264)
    }

    func testRoundTrip() throws {
        var settings = RecordingSettings()
        settings.cameraLayout.shape = .roundedRectangle
        settings.selectedMicrophoneID = "mic-1"
        settings.systemAudioVolume = 0.4
        let decoded = try JSONDecoder().decode(RecordingSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    @MainActor
    func testStorePersists() {
        let defaults = UserDefaults(suiteName: "GlanceTests-\(UUID())")!
        let store = SettingsStore(defaults: defaults)
        store.settings.frameRate = .fps60
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.settings.frameRate, .fps60)
    }

    func testFinalizeOptionVolumes() {
        let options = FinalizeOptions(systemVolume: 0.3, microphoneVolume: 1.2)
        XCTAssertEqual(options.volume(for: .system), 0.3)
        XCTAssertEqual(options.volume(for: .microphone), 1.2)
        XCTAssertEqual(options.volume(for: nil), 1)
    }
}

final class RetimeTests: XCTestCase {
    func testRetimeShiftsPresentationTime() {
        let buffer = TestMedia.sineBuffer(frequency: 440, amplitude: 0.1, channels: 2, frames: 1024, sampleRate: 48_000,
                                          startFrame: 0, pts: CMTime(seconds: 500, preferredTimescale: 48_000))
        let retimed = MediaWriter.retime(buffer, to: CMTime(seconds: 1.5, preferredTimescale: 48_000))
        XCTAssertEqual(retimed?.presentationTimeStamp.seconds ?? -1, 1.5, accuracy: 1e-6)
        XCTAssertEqual(retimed?.numSamples, 1024)
    }
}
