import CoreMedia
import QuartzCore
import ScreenCaptureKit

struct RecordingEngineConfiguration {
    var source: ResolvedCaptureSource
    var outputSize: CGSize
    var frameRate: Int
    var codec: VideoCodecChoice
    var showsCursor: Bool
    var capturesSystemAudio: Bool
    var capturesMicrophone: Bool
    var microphoneDeviceID: String?
    var cameraEnabled: Bool
    var cameraLayout: CameraOverlayLayout
    var intermediateURL: URL
    var outputDirectory: URL
}

enum RecordingEngineEvent {
    case microphoneLevel(Float)
    case warning(String)
    /// Capture can't continue (stream stopped, writer failed, disk full); the coordinator should stop.
    case mustStop(RecorderError)
    /// The ScreenCaptureKit microphone produced nothing usable; the AVFoundation microphone must run.
    case microphoneFallbackActivated
}

/// Where an audio buffer came from. The two microphone paths feed the same output track.
enum AudioSource: String, CaseIterable {
    case system
    case screenCaptureKitMicrophone
    case fallbackMicrophone

    var role: AudioRole { self == .system ? .system : .microphone }
}

struct CapturedRecording {
    let intermediateURL: URL
    let audioRoles: [AudioRole]
    let videoFrames: Int
    let droppedFrames: Int
}

/// Owns one recording session: the ScreenCaptureKit stream, the compositor clock and the writer.
///
/// Concurrency model: every writer/timeline mutation happens on `queue` (serial). Capture callbacks
/// arrive on their own queues and hop onto `queue`; the latest screen frame and the overlay state are
/// shared through `lock`. Video frames are produced by a fixed-rate timer on `queue` that composites the
/// newest screen and camera frames, so the camera keeps moving even when the screen is static. When the
/// encoder falls behind, frames are dropped rather than buffered.
final class RecordingEngine: @unchecked Sendable {
    private let configuration: RecordingEngineConfiguration
    private let camera: CameraService
    private let microphone: MicrophoneService
    private let sendEvent: @Sendable (RecordingEngineEvent) -> Void

    private let queue = DispatchQueue(label: "dev.utkarsh.Glance.recording", qos: .userInitiated)
    private let compositor = VideoCompositor()

    // queue-confined
    private var capture: ScreenCapture?
    private var writer: MediaWriter?
    private var timeline = RecordingTimeline()
    private var timer: DispatchSourceTimer?
    private var isStopping = false
    private var hasReportedFatal = false
    private var lastDiskCheck: CFTimeInterval = 0
    private var lastLevelTime: CFTimeInterval = 0
    private var aligners: [AudioSource: AudioClockAligner] = [:]
    private var audioStats: [AudioSource: AudioSourceStats] = [:]
    private var didCheckScreenCaptureKitMicrophone = false
    private var didCheckFallbackMicrophone = false
    private var fallbackActivatedAt: CMTime?

    // lock-protected
    private let lock = NSLock()
    private var latestScreenFrame: CVPixelBuffer?
    private var layout: CameraOverlayLayout
    private var cameraVisible = true
    private var firstFrameWaiter: CheckedContinuation<Void, Error>?
    private var microphoneFallbackActive = false

    var usesMicrophoneFallback: Bool { lock.withLock { microphoneFallbackActive } }

    init(configuration: RecordingEngineConfiguration, camera: CameraService, microphone: MicrophoneService,
         events: @escaping @Sendable (RecordingEngineEvent) -> Void) {
        self.configuration = configuration
        self.camera = camera
        self.microphone = microphone
        self.sendEvent = events
        self.layout = configuration.cameraLayout
    }

    // MARK: - Control

    func start() async throws {
        var roles: [AudioRole] = []
        if configuration.capturesSystemAudio { roles.append(.system) }
        if configuration.capturesMicrophone { roles.append(.microphone) }
        let writer = try MediaWriter(configuration: .init(url: configuration.intermediateURL,
                                                          videoSize: configuration.outputSize,
                                                          frameRate: configuration.frameRate,
                                                          codec: configuration.codec, audioRoles: roles))
        try await onQueue { self.writer = writer }

        do {
            let capture = makeCapture(microphoneViaScreenCaptureKit: configuration.capturesMicrophone)
            do {
                try await capture.start()
                try await onQueue { self.capture = capture }
            } catch where configuration.capturesMicrophone {
                // Some input devices can't be opened by ScreenCaptureKit; fall back to AVFoundation for the mic.
                Log.capture.error("Capture with microphone failed (\(error.localizedDescription, privacy: .public)); retrying with AVFoundation microphone")
                let fallback = makeCapture(microphoneViaScreenCaptureKit: false)
                try await fallback.start()
                try await onQueue {
                    self.capture = fallback
                    self.activateMicrophoneFallback()
                }
            }
        } catch let error as RecorderError {
            await cleanUpAfterFailedStart()
            throw error
        } catch {
            await cleanUpAfterFailedStart()
            let nsError = error as NSError
            if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.userDeclined.rawValue {
                throw RecorderError.screenPermissionDenied
            }
            throw RecorderError.captureFailed(error.localizedDescription)
        }

        do {
            try await waitForFirstScreenFrame(timeout: 5)
            try await onQueue {
                try writer.start()
                self.timeline.start(at: HostClock.now)
                self.startFrameClock()
            }
        } catch {
            await cleanUpAfterFailedStart()
            throw error
        }
        Log.recording.info("Recording started: \(Int(self.configuration.outputSize.width))x\(Int(self.configuration.outputSize.height)) @\(self.configuration.frameRate)fps, systemAudio=\(self.configuration.capturesSystemAudio), microphone=\(self.configuration.capturesMicrophone ? (self.configuration.microphoneDeviceID ?? "default") : "off", privacy: .public), micFallback=\(self.usesMicrophoneFallback)")
    }

    func pause(at hostTime: CMTime) {
        queue.async { self.timeline.pause(at: hostTime) }
    }

    func resume(at hostTime: CMTime) {
        queue.async { self.timeline.resume(at: hostTime) }
    }

    func updateLayout(_ layout: CameraOverlayLayout) {
        lock.lock(); self.layout = layout; lock.unlock()
    }

    func setCameraVisible(_ visible: Bool) {
        lock.lock(); cameraVisible = visible; lock.unlock()
    }

    /// Stops capture, flushes the encoder and closes the intermediate file.
    func stop() async throws -> CapturedRecording {
        let capture: ScreenCapture? = try? await onQueue { () -> ScreenCapture? in
            // Emit one last frame at the stop instant so the video runs as long as the audio.
            self.renderFrame(at: HostClock.now)
            self.isStopping = true
            self.timer?.cancel()
            self.timer = nil
            return self.capture
        }
        await capture?.stop()
        microphone.setSampleSink(nil)

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let writer = self.writer else {
                    continuation.resume(throwing: RecorderError.noVideoFrames)
                    return
                }
                let roles = writer.recordedAudioRoles
                let frames = writer.videoFrameCount
                let dropped = writer.droppedVideoFrames
                self.logAudioDiagnostics()
                writer.finish { result in
                    switch result {
                    case .success:
                        Log.recording.info("Captured \(frames) frames (\(dropped) dropped)")
                        continuation.resume(returning: CapturedRecording(intermediateURL: self.configuration.intermediateURL,
                                                                         audioRoles: roles, videoFrames: frames,
                                                                         droppedFrames: dropped))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - Capture wiring

    private func makeCapture(microphoneViaScreenCaptureKit: Bool) -> ScreenCapture {
        let streamConfiguration = ScreenCapture.makeConfiguration(
            outputSize: configuration.outputSize, frameRate: configuration.frameRate,
            showsCursor: configuration.showsCursor, capturesSystemAudio: configuration.capturesSystemAudio,
            capturesMicrophone: microphoneViaScreenCaptureKit, microphoneDeviceID: configuration.microphoneDeviceID)
        let handlers = ScreenCapture.Handlers(
            screenFrame: { [weak self] buffer in self?.receiveScreenFrame(buffer) },
            systemAudio: { [weak self] sample in
                self?.receiveAudio(sample, source: .system, presentationTime: sample.presentationTimeStamp)
            },
            microphone: { [weak self] sample in
                guard let self, !self.usesMicrophoneFallback else { return }
                self.receiveAudio(sample, source: .screenCaptureKitMicrophone, presentationTime: sample.presentationTimeStamp)
                self.meter(sample)
            },
            stopped: { [weak self] error in
                self?.reportFatal(.captureFailed(Self.describeStreamError(error)))
            })
        return ScreenCapture(filter: configuration.source.filter, configuration: streamConfiguration, handlers: handlers)
    }

    /// Switches the microphone track to the AVFoundation capture path (queue).
    private func activateMicrophoneFallback() {
        lock.withLock { microphoneFallbackActive = true }
        fallbackActivatedAt = HostClock.now
        microphone.setSampleSink { [weak self] sample, hostTime in
            self?.receiveAudio(sample, source: .fallbackMicrophone, presentationTime: hostTime)
            self?.meter(sample)
        }
    }

    private func receiveScreenFrame(_ buffer: CVPixelBuffer) {
        lock.lock()
        latestScreenFrame = buffer
        let waiter = firstFrameWaiter
        firstFrameWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    private func receiveAudio(_ sample: CMSampleBuffer, source: AudioSource, presentationTime: CMTime) {
        let arrival = HostClock.now
        queue.async {
            guard !self.isStopping, let writer = self.writer, writer.isWriting else { return }
            var stats = self.audioStats[source, default: AudioSourceStats()]
            stats.received += 1
            if let rms = AudioLevelMeter.rms(of: sample) { stats.peakRMS = max(stats.peakRMS, rms) }

            var aligner = self.aligners[source, default: AudioClockAligner()]
            let hostTime = aligner.hostTime(for: presentationTime, duration: sample.duration, arrivedAt: arrival)
            if !self.aligners[source, default: AudioClockAligner()].isRealigned, aligner.isRealigned {
                Log.recording.error("\(source.rawValue, privacy: .public) audio is on another clock; re-anchoring by \(aligner.offset?.seconds ?? 0)s")
            }
            self.aligners[source] = aligner
            stats.clockOffsetSeconds = aligner.offset?.seconds ?? 0

            if let outputTime = self.timeline.outputTime(for: hostTime) {
                if writer.appendAudio(sample, role: source.role, at: outputTime) {
                    stats.appended += 1
                } else {
                    stats.rejectedByWriter += 1
                }
            } else {
                stats.droppedOutsideTimeline += 1
            }
            self.audioStats[source] = stats
        }
    }

    /// A few seconds in, make sure the microphone is actually delivering sound (queue).
    private func checkMicrophoneHealth(now: CMTime) {
        guard configuration.capturesMicrophone, let start = timeline.startTime, (now - start).seconds >= 3 else { return }
        if !usesMicrophoneFallback {
            guard !didCheckScreenCaptureKitMicrophone else { return }
            didCheckScreenCaptureKitMicrophone = true
            let stats = audioStats[.screenCaptureKitMicrophone] ?? AudioSourceStats()
            guard !stats.hasAudibleSignal else { return }
            Log.recording.error("ScreenCaptureKit microphone delivered no sound after 3 s (\(stats.summary, privacy: .public)); switching to AVFoundation")
            activateMicrophoneFallback()
            sendEvent(.microphoneFallbackActivated)
        } else if !didCheckFallbackMicrophone, let since = fallbackActivatedAt, (now - since).seconds >= 3 {
            didCheckFallbackMicrophone = true
            let stats = audioStats[.fallbackMicrophone] ?? AudioSourceStats()
            guard !stats.hasAudibleSignal else { return }
            Log.recording.error("Fallback microphone is silent too (\(stats.summary, privacy: .public))")
            sendEvent(.warning("Your microphone is silent — check the input device and System Settings › Privacy › Microphone."))
        }
    }

    /// Per-source audio counters, logged when the recording stops (queue).
    private func logAudioDiagnostics() {
        var expected: [AudioSource] = []
        if configuration.capturesSystemAudio { expected.append(.system) }
        if configuration.capturesMicrophone { expected.append(.screenCaptureKitMicrophone) }
        if usesMicrophoneFallback { expected.append(.fallbackMicrophone) }
        for source in expected {
            let stats = audioStats[source] ?? AudioSourceStats()
            Log.recording.info("Audio \(source.rawValue, privacy: .public): \(stats.summary, privacy: .public)")
        }
    }

    private func meter(_ sample: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        lock.lock()
        let due = now - lastLevelTime > 0.05
        if due { lastLevelTime = now }
        lock.unlock()
        guard due, let rms = AudioLevelMeter.rms(of: sample) else { return }
        sendEvent(.microphoneLevel(AudioLevelMeter.normalizedLevel(rms: rms)))
    }

    private func waitForFirstScreenFrame(timeout: TimeInterval) async throws {
        if lock.withLock({ latestScreenFrame != nil }) { return }

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self else { return }
            let waiter = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
                let waiter = self.firstFrameWaiter
                self.firstFrameWaiter = nil
                return waiter
            }
            waiter?.resume(throwing: RecorderError.captureStartTimedOut)
        }
        defer { timeoutTask.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let hasFrame = lock.withLock { () -> Bool in
                if latestScreenFrame != nil { return true }
                firstFrameWaiter = continuation
                return false
            }
            if hasFrame { continuation.resume() }
        }
    }

    // MARK: - Frame clock (queue)

    private func startFrameClock() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let interval = 1.0 / Double(configuration.frameRate)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        guard !isStopping else { return }
        if let failure = writer?.failure {
            reportFatal(.writerFailed(failure.localizedDescription))
            return
        }
        checkDiskSpaceIfDue()
        let now = HostClock.now
        checkMicrophoneHealth(now: now)
        renderFrame(at: now)
    }

    private func renderFrame(at hostTime: CMTime) {
        guard !isStopping, let writer, writer.isWriting,
              let outputTime = timeline.outputTime(for: hostTime) else { return }
        lock.lock()
        let screen = latestScreenFrame
        let layout = self.layout
        let showCamera = configuration.cameraEnabled && cameraVisible
        lock.unlock()
        let cameraFrame = showCamera ? camera.latestFrame() : nil
        guard let buffer = writer.makeVideoBuffer() else { return }
        compositor.render(screen: screen, camera: cameraFrame, layout: layout, into: buffer)
        writer.appendVideo(buffer, at: outputTime)
    }

    private func checkDiskSpaceIfDue() {
        let now = CACurrentMediaTime()
        guard now - lastDiskCheck > 5 else { return }
        lastDiskCheck = now
        let available = DiskSpace.availableBytes(at: configuration.intermediateURL.deletingLastPathComponent())
        let outputAvailable = DiskSpace.availableBytes(at: configuration.outputDirectory)
        if DiskSpace.shouldStopRecording(availableBytes: available) || DiskSpace.shouldStopRecording(availableBytes: outputAvailable) {
            reportFatal(.insufficientDiskSpace(availableBytes: min(available ?? .max, outputAvailable ?? .max)))
        }
    }

    // MARK: - Failure handling

    private func reportFatal(_ error: RecorderError) {
        queue.async {
            guard !self.isStopping, !self.hasReportedFatal else { return }
            self.hasReportedFatal = true
            self.sendEvent(.mustStop(error))
        }
    }

    private func cleanUpAfterFailedStart() async {
        let capture: ScreenCapture? = try? await onQueue { () -> ScreenCapture? in
            self.isStopping = true
            self.timer?.cancel()
            self.timer = nil
            return self.capture
        }
        await capture?.stop()
        microphone.setSampleSink(nil)
        try? await onQueue { self.writer?.cancel() }
    }

    private static func describeStreamError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain {
            switch SCStreamError.Code(rawValue: nsError.code) {
            case .userStopped: return "Recording was stopped from the macOS menu bar."
            case .noDisplayList, .noCaptureSource: return "The display or window being recorded disappeared."
            case .userDeclined: return "Screen Recording permission was revoked."
            default: break
            }
        }
        return error.localizedDescription
    }

    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}
