import AVFoundation
import XCTest
@testable import Glance

/// Drives the real writer → compositor → finalizer path with synthetic screen, camera and audio
/// (no permissions required) and validates the resulting MP4.
final class PipelineIntegrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GlanceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Simulates 3 s of capture with a 1 s pause in the middle: the output should be ~2 s long,
    /// with one enabled mixed audio track and composited video.
    func testRecordWithPauseProducesMixedMP4() async throws {
        let intermediate = directory.appendingPathComponent("capture.mov")
        let size = CGSize(width: 640, height: 360)
        let fps = 30
        let writer = try MediaWriter(configuration: .init(url: intermediate, videoSize: size, frameRate: fps,
                                                          codec: .h264, audioRoles: [.system, .microphone]))
        try writer.start()

        let compositor = VideoCompositor()
        let screen = TestMedia.solidPixelBuffer(width: 1280, height: 720, bgra: (200, 80, 40, 255))
        let camera = TestMedia.solidPixelBuffer(width: 1280, height: 720, bgra: (40, 200, 80, 255))
        let layout = CameraOverlayLayout()

        // Host-clock style timestamps starting at an arbitrary offset.
        let base = CMTime(seconds: 1000, preferredTimescale: 1_000_000_000)
        var timeline = RecordingTimeline()
        timeline.start(at: base)
        let sampleRate = 48_000.0
        let chunk = 1024
        var systemFrame = 0
        var micFrame = 0

        let totalDuration = 3.0
        let pauseStart = 1.0
        let pauseEnd = 2.0
        var t = 0.0
        let step = 1.0 / Double(fps)
        var paused = false
        while t < totalDuration {
            let host = base + CMTime(seconds: t, preferredTimescale: 1_000_000_000)
            if !paused && t >= pauseStart && t < pauseEnd { timeline.pause(at: host); paused = true }
            if paused && t >= pauseEnd { timeline.resume(at: host); paused = false }

            if let out = timeline.outputTime(for: host), let pb = writer.makeVideoBuffer() {
                compositor.render(screen: screen, camera: camera, layout: layout, into: pb)
                writer.appendVideo(pb, at: out)
            }
            // Audio for this video tick (system stereo, mic mono — as ScreenCaptureKit delivers them).
            while Double(systemFrame) / sampleRate < t + step {
                let pts = base + CMTime(value: CMTimeValue(systemFrame), timescale: 48_000)
                let sb = TestMedia.sineBuffer(frequency: 440, amplitude: 0.3, channels: 2, frames: chunk,
                                              sampleRate: sampleRate, startFrame: systemFrame, pts: pts)
                if let out = timeline.outputTime(for: pts) { writer.appendAudio(sb, role: .system, at: out) }
                systemFrame += chunk
            }
            while Double(micFrame) / sampleRate < t + step {
                let pts = base + CMTime(value: CMTimeValue(micFrame), timescale: 48_000)
                let sb = TestMedia.sineBuffer(frequency: 220, amplitude: 0.3, channels: 1, frames: 480,
                                              sampleRate: sampleRate, startFrame: micFrame, pts: pts)
                if let out = timeline.outputTime(for: pts) { writer.appendAudio(sb, role: .microphone, at: out) }
                micFrame += 480
            }
            // Give the real-time encoder a moment, like a live capture would.
            try await Task.sleep(nanoseconds: 2_000_000)
            t += step
        }

        XCTAssertGreaterThan(writer.videoFrameCount, 50)
        XCTAssertEqual(writer.recordedAudioRoles, [.system, .microphone])

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            writer.finish { c.resume(with: $0) }
        }

        let destination = directory.appendingPathComponent("final.mp4")
        let verification = try await RecordingFinalizer.finalize(
            intermediate: intermediate, audioRoles: writer.recordedAudioRoles, destination: destination,
            options: FinalizeOptions(systemVolume: 0.8, microphoneVolume: 1, keepsSeparateTracks: false))

        XCTAssertEqual(verification.videoSize, size)
        XCTAssertEqual(verification.enabledAudioTracks, 1)
        XCTAssertEqual(verification.totalAudioTracks, 1)
        XCTAssertEqual(verification.duration, 2.0, accuracy: 0.15, "Paused second must be removed from the timeline")
        XCTAssertGreaterThan(verification.fileSize, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let intermediateRMS = try await TestMedia.audioRMS(of: intermediate)
        let finalRMS = try await TestMedia.audioRMS(of: destination)
        print("RMS intermediate=\(intermediateRMS) final=\(finalRMS)")
        XCTAssertGreaterThan(intermediateRMS, 0.05, "captured audio must be audible in the intermediate file")
        XCTAssertGreaterThan(finalRMS, 0.05, "mixed audio must be audible in the final MP4")

        // The bubble region must contain camera pixels (green) and the rest the screen (blue-ish in BGRA terms).
        let asset = AVURLAsset(url: destination)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let bubbleRect = layout.rect(in: size)
        let cameraPixel = try XCTUnwrap(Self.pixel(of: image, at: CGPoint(x: bubbleRect.midX, y: bubbleRect.midY)))
        let screenPixel = try XCTUnwrap(Self.pixel(of: image, at: CGPoint(x: 40, y: 40)))
        XCTAssertGreaterThan(cameraPixel.g, 150, "camera bubble should be composited")
        XCTAssertLessThan(cameraPixel.r, 90)
        XCTAssertGreaterThan(screenPixel.b, 150, "screen should fill the background")
    }

    func testSeparateTracksAreKeptDisabled() async throws {
        let intermediate = directory.appendingPathComponent("capture.mov")
        let writer = try MediaWriter(configuration: .init(url: intermediate, videoSize: CGSize(width: 320, height: 240),
                                                          frameRate: 30, codec: .hevc, audioRoles: [.system, .microphone]))
        try writer.start()
        let compositor = VideoCompositor()
        for i in 0..<30 {
            let time = CMTime(value: CMTimeValue(i), timescale: 30)
            if let pb = writer.makeVideoBuffer() {
                compositor.render(screen: nil, camera: nil, layout: CameraOverlayLayout(), into: pb)
                writer.appendVideo(pb, at: time)
            }
            let sys = TestMedia.sineBuffer(frequency: 440, amplitude: 0.2, channels: 2, frames: 1600, sampleRate: 48_000,
                                           startFrame: i * 1600, pts: time)
            writer.appendAudio(sys, role: .system, at: time)
            let mic = TestMedia.sineBuffer(frequency: 330, amplitude: 0.2, channels: 1, frames: 1600, sampleRate: 48_000,
                                           startFrame: i * 1600, pts: time)
            writer.appendAudio(mic, role: .microphone, at: time)
            try await Task.sleep(nanoseconds: 3_000_000)
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in writer.finish { c.resume(with: $0) } }
        let verification = try await RecordingFinalizer.finalize(
            intermediate: intermediate, audioRoles: writer.recordedAudioRoles,
            destination: directory.appendingPathComponent("final.mp4"),
            options: FinalizeOptions(keepsSeparateTracks: true))
        XCTAssertEqual(verification.enabledAudioTracks, 1)
        XCTAssertEqual(verification.totalAudioTracks, 3)
        XCTAssertEqual(verification.duration, 1.0, accuracy: 0.15)
        let rms = try await TestMedia.audioRMS(of: directory.appendingPathComponent("final.mp4"))
        XCTAssertGreaterThan(rms, 0.05, "mixed track must contain the sources' audio")
    }

    func testScreenOnlyRecordingWithoutAudio() async throws {
        let intermediate = directory.appendingPathComponent("capture.mov")
        let writer = try MediaWriter(configuration: .init(url: intermediate, videoSize: CGSize(width: 320, height: 200),
                                                          frameRate: 30, codec: .h264, audioRoles: []))
        try writer.start()
        let compositor = VideoCompositor()
        let screen = TestMedia.solidPixelBuffer(width: 320, height: 200, bgra: (255, 255, 255, 255))
        for i in 0..<15 {
            if let pb = writer.makeVideoBuffer() {
                compositor.render(screen: screen, camera: nil, layout: CameraOverlayLayout(), into: pb)
                writer.appendVideo(pb, at: CMTime(value: CMTimeValue(i), timescale: 30))
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in writer.finish { c.resume(with: $0) } }
        let verification = try await RecordingFinalizer.finalize(
            intermediate: intermediate, audioRoles: [], destination: directory.appendingPathComponent("final.mp4"),
            options: FinalizeOptions())
        XCTAssertEqual(verification.totalAudioTracks, 0)
        XCTAssertEqual(verification.duration, 0.5, accuracy: 0.1)
    }

    func testFinishingWithoutFramesFails() async throws {
        let url = directory.appendingPathComponent("empty.mov")
        let result: Result<Void, Error> = try await Task.detached {
            let writer = try MediaWriter(configuration: .init(url: url, videoSize: CGSize(width: 320, height: 200),
                                                              frameRate: 30, codec: .h264, audioRoles: []))
            try writer.start()
            return await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
        }.value
        guard case .failure(let error as RecorderError) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .noVideoFrames)
    }

    private static func pixel(of image: CGImage, at point: CGPoint) -> (r: Int, g: Int, b: Int)? {
        var data = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Draw so that `point` (top-left image coordinates) lands on the single pixel.
        ctx.draw(image, in: CGRect(x: -point.x, y: point.y - CGFloat(image.height) + 1,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }
}
