import AppKit
import Observation

struct PresentedError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var permission: PermissionKind?

    init(_ error: Error, context: String? = nil) {
        let recorderError = error as? RecorderError
        title = (error as? LocalizedError)?.errorDescription ?? "Something went wrong"
        let detail = recorderError?.recoverySuggestion ?? (recorderError == nil ? error.localizedDescription : nil)
        message = [context, detail].compactMap { $0 }.joined(separator: "\n\n")
        if recorderError == .screenPermissionDenied { permission = .screen }
    }
}

struct SavedRecording: Equatable {
    let url: URL
    let duration: TimeInterval
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// UI-facing recording controller. Owns the state machine and translates user intent
/// (buttons, menu bar, hotkeys, system events) into engine calls on the main actor.
@MainActor
@Observable
final class RecordingCoordinator {
    private(set) var machine = RecordingStateMachine()
    private(set) var elapsed: TimeInterval = 0
    private(set) var microphoneLevel: Float = 0
    private(set) var warning: String?
    private(set) var lastSaved: SavedRecording?
    private(set) var activeSourceTitle: String?
    private(set) var isCameraActiveInRecording = false
    var presentedError: PresentedError?

    /// Hides only the floating preview; the camera keeps being recorded.
    var isCameraPreviewHidden = false {
        didSet { overlays.setBubbleHidden(isCameraPreviewHidden) }
    }
    /// Removes the camera bubble from the recorded video (preview stays so you can see yourself).
    var isCameraInRecording = true {
        didSet { engine?.setCameraVisible(isCameraInRecording) }
    }

    var phase: RecordingPhase { machine.phase }

    unowned let app: AppModel
    @ObservationIgnored private(set) lazy var overlays = OverlayController(app: app)
    @ObservationIgnored private var engine: RecordingEngine?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var uiTimeline = RecordingTimeline()
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var recordingStartedAt = Date()
    @ObservationIgnored private var stopReason: RecorderError?
    @ObservationIgnored private var stopRequestedWhileStarting = false
    @ObservationIgnored private var idleWaiters: [() -> Void] = []

    init(app: AppModel) {
        self.app = app
    }

    // MARK: - User intents

    func toggleRecording() {
        switch phase {
        case .idle: startRecording()
        case .countingDown: cancelCountdown()
        case .starting: stopRequestedWhileStarting = true
        case .recording, .paused: stopRecording()
        case .finishing: break
        }
    }

    func startRecording() {
        guard machine.handle(.requestStart(countdown: app.settings.countdownSeconds)) else { return }
        warning = nil
        lastSaved = nil
        stopReason = nil
        stopRequestedWhileStarting = false
        runTask = Task { await run() }
    }

    func cancelCountdown() {
        guard case .countingDown = phase, machine.handle(.cancelCountdown) else { return }
        runTask?.cancel()
        runTask = nil
        tearDownRecordingUI()
        notifyIdle()
    }

    func togglePause() {
        let now = HostClock.now
        switch phase {
        case .recording:
            guard machine.handle(.pause) else { return }
            uiTimeline.pause(at: now)
            engine?.pause(at: now)
            updateElapsed()
        case .paused:
            guard machine.handle(.resume) else { return }
            uiTimeline.resume(at: now)
            engine?.resume(at: now)
            warning = nil
        default:
            break
        }
    }

    func stopRecording() {
        guard machine.handle(.stop) else { return }
        stopClock()
        updateElapsed()
        Task { await finish() }
    }

    /// Runs `body` once the coordinator is idle (used to finish recording before quitting).
    func whenIdle(_ body: @escaping () -> Void) {
        if phase == .idle { body() } else { idleWaiters.append(body) }
    }

    func updateCameraLayout(fromBubble: Bool = false, _ change: (inout CameraOverlayLayout) -> Void) {
        var layout = app.settings.cameraLayout
        change(&layout)
        guard layout != app.settings.cameraLayout else { return }
        app.settings.cameraLayout = layout
        engine?.updateLayout(layout)
        if !fromBubble { overlays.layoutBubble(layout) }
    }

    func dismissSavedBanner() {
        lastSaved = nil
    }

    // MARK: - System events

    func systemWillSleep() {
        if phase == .recording {
            togglePause()
            warning = "Paused because your Mac went to sleep."
        }
    }

    func screenParametersChanged() {
        overlays.screenParametersChanged()
    }

    func cameraDidFail(_ message: String) {
        guard phase.isCapturing else { return }
        warning = "Camera unavailable — continuing with screen only."
        Log.recording.error("Camera problem during recording: \(message, privacy: .public)")
    }

    func microphoneDidDisconnect() {
        guard phase.isCapturing else { return }
        warning = "Microphone disconnected — your voice may not be recorded."
    }

    // MARK: - Session flow

    private struct Prepared {
        let source: ResolvedCaptureSource
        let configuration: RecordingEngineConfiguration
    }

    private func run() async {
        let prepared: Prepared
        do {
            prepared = try await prepare()
        } catch {
            guard !Task.isCancelled else { return }
            Log.recording.error("Couldn't start recording: \(error.localizedDescription, privacy: .public)")
            machine.handle(.failure)
            tearDownRecordingUI()
            presentedError = PresentedError(error)
            notifyIdle()
            return
        }
        guard machine.phase != .idle, !Task.isCancelled else { return }

        activeSourceTitle = prepared.source.title
        presentRecordingUI(prepared)

        while case .countingDown(let remaining) = phase {
            overlays.showCountdown(remaining: remaining, on: prepared.source.screen)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard case .countingDown = phase, !Task.isCancelled else { return }
            machine.handle(.countdownTick)
        }
        overlays.hideCountdown()
        guard phase == .starting else { return }
        await beginCapture(prepared)
    }

    private func prepare() async throws -> Prepared {
        let settings = app.settings
        app.permissions.refresh()

        if settings.capturesMicrophone && app.permissions.microphone == .notDetermined {
            await app.permissions.request(.microphone)
        }
        if settings.cameraEnabled && app.permissions.camera == .notDetermined {
            await app.permissions.request(.camera)
        }

        let outputDirectory = app.settingsStore.outputDirectory
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: SettingsStore.inProgressDirectory, withIntermediateDirectories: true)
        } catch {
            throw RecorderError.outputDirectoryUnavailable(error.localizedDescription)
        }
        guard FileManager.default.isWritableFile(atPath: outputDirectory.path) else {
            throw RecorderError.outputDirectoryUnavailable("Glance can't write to “\(outputDirectory.path)”.")
        }
        let available = DiskSpace.availableBytes(at: outputDirectory)
        guard DiskSpace.hasRoomToStart(availableBytes: available) else {
            throw RecorderError.insufficientDiskSpace(availableBytes: available ?? 0)
        }

        let source = try await app.sources.resolveSelection()
        app.permissions.markScreenCaptureConfirmed()

        let microphoneAllowed = settings.capturesMicrophone && app.permissions.microphone == .granted
        let cameraAllowed = settings.cameraEnabled && app.permissions.camera == .granted
        if settings.capturesMicrophone && !microphoneAllowed {
            warning = "Microphone access is off — recording without your voice."
        } else if settings.cameraEnabled && !cameraAllowed {
            warning = "Camera access is off — recording without the camera bubble."
        }

        let outputSize = OutputSizing.outputSize(contentPixelSize: source.contentPixelSize, quality: settings.quality)
        let intermediate = SettingsStore.inProgressDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        let configuration = RecordingEngineConfiguration(
            source: source, outputSize: outputSize, frameRate: settings.frameRate.rawValue, codec: settings.codec,
            showsCursor: settings.showsCursor, capturesSystemAudio: settings.capturesSystemAudio,
            capturesMicrophone: microphoneAllowed,
            microphoneDeviceID: app.devices.resolvedMicrophoneID(preferred: settings.selectedMicrophoneID),
            cameraEnabled: cameraAllowed, cameraLayout: settings.cameraLayout,
            intermediateURL: intermediate, outputDirectory: outputDirectory)
        return Prepared(source: source, configuration: configuration)
    }

    private func presentRecordingUI(_ prepared: Prepared) {
        if app.settings.hidesMainWindowWhileRecording { app.hideMainWindow() }
        isCameraPreviewHidden = false
        isCameraActiveInRecording = prepared.configuration.cameraEnabled
        overlays.showControlBar(on: prepared.source.screen)
        if prepared.configuration.cameraEnabled {
            app.setCameraDemand(.recording, true)
            overlays.showBubble(region: prepared.source.overlayRegion, layout: app.settings.cameraLayout)
        }
    }

    private func beginCapture(_ prepared: Prepared) async {
        let engine = RecordingEngine(configuration: prepared.configuration, camera: app.camera,
                                     microphone: app.microphone) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        engine.setCameraVisible(isCameraInRecording)
        self.engine = engine
        app.library.activeIntermediate = prepared.configuration.intermediateURL

        do {
            try await engine.start()
        } catch {
            self.engine = nil
            app.library.activeIntermediate = nil
            machine.handle(.failure)
            tearDownRecordingUI()
            presentedError = PresentedError(error)
            notifyIdle()
            return
        }

        machine.handle(.captureDidStart)
        recordingStartedAt = Date()
        uiTimeline.start(at: HostClock.now)
        elapsed = 0
        startClock()
        if engine.usesMicrophoneFallback { app.setMicrophoneDemand(.fallback, true) }
        app.updateDevices()

        if stopRequestedWhileStarting {
            stopRequestedWhileStarting = false
            stopRecording()
        }
    }

    private func handle(_ event: RecordingEngineEvent) {
        switch event {
        case .microphoneLevel(let level):
            microphoneLevel = level
        case .warning(let message):
            warning = message
        case .microphoneFallbackActivated:
            app.setMicrophoneDemand(.fallback, true)
            warning = "Switched to backup microphone capture."
        case .mustStop(let error):
            guard phase.isCapturing else { return }
            stopReason = error
            stopRecording()
        }
    }

    private func finish() async {
        defer { notifyIdle() }
        guard let engine else {
            machine.handle(.finishDidComplete)
            tearDownRecordingUI()
            return
        }
        overlays.setBubbleHidden(true)

        var saved: SavedRecording?
        var failure: Error?
        var intermediate: URL?
        do {
            let captured = try await engine.stop()
            intermediate = captured.intermediateURL
            try app.library.ensureDirectoryExists()
            let destination = RecordingFileNamer.uniqueURL(in: app.settingsStore.outputDirectory,
                                                           baseName: RecordingFileNamer.baseName(for: recordingStartedAt))
            let verification = try await RecordingFinalizer.finalize(intermediate: captured.intermediateURL,
                                                                     audioRoles: captured.audioRoles,
                                                                     destination: destination,
                                                                     options: app.finalizeOptions)
            try? FileManager.default.removeItem(at: captured.intermediateURL)
            saved = SavedRecording(url: destination, duration: verification.duration)
        } catch {
            failure = error
            Log.recording.error("Finishing failed: \(error.localizedDescription, privacy: .public)")
        }

        self.engine = nil
        app.library.activeIntermediate = nil
        tearDownRecordingUI()
        machine.handle(.finishDidComplete)
        app.library.refresh()

        if let saved {
            lastSaved = saved
            app.library.highlightedURL = saved.url
        }
        let keptFootage = intermediate.map { FileManager.default.fileExists(atPath: $0.path) } ?? !app.library.unfinished.isEmpty
        if let stopReason {
            let context = saved != nil ? "Recording stopped early. Everything captured up to that point was saved." : nil
            presentedError = PresentedError(stopReason, context: context)
        } else if let failure {
            let context = keptFootage ? "The captured footage was kept — use “Recover” in the Library to save it." : nil
            presentedError = PresentedError(failure, context: context)
        }
        stopReason = nil
    }

    private func tearDownRecordingUI() {
        overlays.hideAll()
        stopClock()
        microphoneLevel = 0
        activeSourceTitle = nil
        isCameraActiveInRecording = false
        app.setCameraDemand(.recording, false)
        app.setMicrophoneDemand(.fallback, false)
        app.updateDevices()
        app.showMainWindow()
    }

    private func notifyIdle() {
        guard phase == .idle else { return }
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0() }
    }

    // MARK: - Elapsed time

    private func startClock() {
        stopClock()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateElapsed() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
    }

    private func updateElapsed() {
        elapsed = uiTimeline.recordedDuration(at: HostClock.now).seconds
    }
}

extension TimeInterval {
    /// "1:05" or "1:02:05".
    var clockString: String {
        let total = Int(self.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }
}
