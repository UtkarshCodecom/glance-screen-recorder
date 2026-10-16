import AppKit
import Observation

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case record
    case library
    var id: String { rawValue }
}

enum DeviceDemand: Hashable {
    /// The Record page is on screen (live previews and level meter).
    case preview
    /// A recording session is active.
    case recording
    /// The AVFoundation microphone is feeding a recording.
    case fallback
}

/// Root object: owns the long-lived services and decides when the camera and microphone run.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settingsStore: SettingsStore
    let permissions: PermissionsService
    let devices: DeviceManager
    let sources: ScreenSourceStore
    let library: RecordingsLibrary
    let camera = CameraService()
    let microphone = MicrophoneService()
    @ObservationIgnored private(set) var coordinator: RecordingCoordinator!

    var sidebarSelection: SidebarItem? = .record
    private(set) var previewMicrophoneLevel: Float = 0
    private(set) var cameraError: String?
    private(set) var microphoneError: String?
    private(set) var isCameraRunning = false
    private(set) var isMicrophoneRunning = false

    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored var openMainWindowAction: (() -> Void)?
    @ObservationIgnored private var cameraDemand: Set<DeviceDemand> = []
    @ObservationIgnored private var microphoneDemand: Set<DeviceDemand> = []
    @ObservationIgnored private var cameraDeviceInUse: String?
    @ObservationIgnored private var microphoneDeviceInUse: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var hotKeys: GlobalHotKeys?
    @ObservationIgnored private var isBootstrapped = false

    var settings: RecordingSettings {
        get { settingsStore.settings }
        set { settingsStore.settings = newValue }
    }

    private init() {
        settingsStore = SettingsStore()
        permissions = PermissionsService()
        devices = DeviceManager()
        sources = ScreenSourceStore()
        library = RecordingsLibrary(directory: settingsStore.outputDirectory)
        coordinator = RecordingCoordinator(app: self)

        camera.onProblem = { [weak self] message in self?.handleCameraProblem(message) }
        microphone.onLevel = { [weak self] level in self?.previewMicrophoneLevel = level }
        devices.onDeviceDisconnected = { [weak self] id in self?.handleDeviceDisconnected(id) }
    }

    /// Starts app-wide observers. Skipped when hosting unit tests.
    func bootstrap() {
        guard !isBootstrapped else { return }
        isBootstrapped = true
        library.refresh()
        hotKeys = GlobalHotKeys(
            toggleRecording: { [weak self] in self?.coordinator.toggleRecording() },
            togglePause: { [weak self] in self?.coordinator.togglePause() })

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.permissions.refresh()
                self.devices.refresh()
                self.library.refresh()
                self.updateDevices()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.permissions.screen == .granted { Task { await self.sources.refresh() } }
                self.coordinator.screenParametersChanged()
            }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator.systemWillSleep() }
        })
    }

    // MARK: - Device lifecycle

    func setCameraDemand(_ demand: DeviceDemand, _ active: Bool) {
        if active { cameraDemand.insert(demand) } else { cameraDemand.remove(demand) }
        updateDevices()
    }

    func setMicrophoneDemand(_ demand: DeviceDemand, _ active: Bool) {
        if active { microphoneDemand.insert(demand) } else { microphoneDemand.remove(demand) }
        updateDevices()
    }

    /// Starts or stops the camera and microphone to match current demand, settings and permissions.
    func updateDevices() {
        let settings = settingsStore.settings

        let wantsCamera = settings.cameraEnabled && permissions.camera == .granted && !cameraDemand.isEmpty
        let cameraID = devices.resolvedCameraID(preferred: settings.selectedCameraID)
        if wantsCamera {
            if !isCameraRunning || cameraDeviceInUse != cameraID {
                cameraDeviceInUse = cameraID
                camera.start(deviceID: cameraID) { [weak self] error in
                    guard let self else { return }
                    self.cameraError = error?.localizedDescription
                    self.isCameraRunning = error == nil
                }
            }
        } else if isCameraRunning || cameraDeviceInUse != nil {
            camera.stop()
            isCameraRunning = false
            cameraDeviceInUse = nil
        }

        // While recording through ScreenCaptureKit, the preview meter is fed by the recording itself.
        let previewAllowed = !coordinator.phase.isCapturing
        let micDemanded = microphoneDemand.contains(.fallback) || (microphoneDemand.contains(.preview) && previewAllowed)
        let wantsMicrophone = settings.capturesMicrophone && permissions.microphone == .granted && micDemanded
        let microphoneID = devices.resolvedMicrophoneID(preferred: settings.selectedMicrophoneID)
        if wantsMicrophone {
            if !isMicrophoneRunning || microphoneDeviceInUse != microphoneID {
                microphoneDeviceInUse = microphoneID
                microphone.start(deviceID: microphoneID) { [weak self] error in
                    guard let self else { return }
                    self.microphoneError = error?.localizedDescription
                    self.isMicrophoneRunning = error == nil
                }
            }
        } else if isMicrophoneRunning || microphoneDeviceInUse != nil {
            microphone.stop()
            isMicrophoneRunning = false
            microphoneDeviceInUse = nil
            previewMicrophoneLevel = 0
        }
    }

    private func handleCameraProblem(_ message: String) {
        cameraError = message
        isCameraRunning = false
        cameraDeviceInUse = nil
        coordinator.cameraDidFail(message)
    }

    private func handleDeviceDisconnected(_ id: String) {
        if id == cameraDeviceInUse {
            handleCameraProblem("The camera was disconnected.")
            updateDevices() // Falls back to another camera if one is available.
        }
        if id == microphoneDeviceInUse {
            isMicrophoneRunning = false
            microphoneDeviceInUse = nil
            coordinator.microphoneDidDisconnect()
            updateDevices()
        }
    }

    // MARK: - Windows

    func showMainWindow() {
        NSApp.activate()
        if let window = mainWindow, window.contentView != nil {
            window.makeKeyAndOrderFront(nil)
        } else if let openMainWindowAction {
            openMainWindowAction()
        } else if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(WindowID.main) == true }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func hideMainWindow() {
        mainWindow?.orderOut(nil)
    }

    func setOutputDirectory(_ url: URL) {
        settingsStore.settings.outputDirectoryPath = url.path
        library.setDirectory(url)
    }

    var finalizeOptions: FinalizeOptions {
        FinalizeOptions(systemVolume: settings.systemAudioVolume, microphoneVolume: settings.microphoneVolume,
                        keepsSeparateTracks: settings.keepsSeparateAudioTracks)
    }
}

enum WindowID {
    static let main = "main"
}
