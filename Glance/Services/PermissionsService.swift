import AppKit
import AVFoundation
import CoreGraphics
import Observation

enum PermissionKind: String, CaseIterable, Identifiable {
    case screen
    case camera
    case microphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: return "Screen & System Audio"
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        }
    }

    var systemImage: String {
        switch self {
        case .screen: return "rectangle.inset.filled.on.rectangle"
        case .camera: return "video.fill"
        case .microphone: return "mic.fill"
        }
    }

    var explanation: String {
        switch self {
        case .screen: return "Required to record your screen and the sound your Mac plays."
        case .camera: return "Shows you in the camera bubble."
        case .microphone: return "Records your voice."
        }
    }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .screen: anchor = "Privacy_ScreenCapture"
        case .camera: anchor = "Privacy_Camera"
        case .microphone: anchor = "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

enum PermissionState: Equatable {
    case granted
    case denied
    case notDetermined
}

@MainActor
@Observable
final class PermissionsService {
    private(set) var screen: PermissionState = .notDetermined
    private(set) var camera: PermissionState = .notDetermined
    private(set) var microphone: PermissionState = .notDetermined

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let screenRequestedKey = "GlanceDidRequestScreenCapture"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refresh()
    }

    func state(for kind: PermissionKind) -> PermissionState {
        switch kind {
        case .screen: return screen
        case .camera: return camera
        case .microphone: return microphone
        }
    }

    func refresh() {
        if CGPreflightScreenCaptureAccess() {
            screen = .granted
        } else {
            screen = defaults.bool(forKey: screenRequestedKey) ? .denied : .notDetermined
        }
        camera = Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        microphone = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// Screen recording grants are only picked up reliably after relaunching the app.
    func markScreenCaptureConfirmed() {
        screen = .granted
    }

    func request(_ kind: PermissionKind) async {
        switch kind {
        case .screen:
            if defaults.bool(forKey: screenRequestedKey) && !CGPreflightScreenCaptureAccess() {
                openSystemSettings(for: .screen)
            } else {
                defaults.set(true, forKey: screenRequestedKey)
                // Shows the system prompt once; afterwards macOS only allows changes in System Settings.
                _ = CGRequestScreenCaptureAccess()
            }
        case .camera, .microphone:
            let type: AVMediaType = kind == .camera ? .video : .audio
            if AVCaptureDevice.authorizationStatus(for: type) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: type)
            } else {
                openSystemSettings(for: kind)
            }
        }
        refresh()
    }

    func openSystemSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
}
