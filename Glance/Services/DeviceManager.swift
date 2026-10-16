import AVFoundation
import CoreAudio
import Observation

struct CaptureDeviceInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Enumerates cameras and microphones and tracks hot-plug events.
@MainActor
@Observable
final class DeviceManager {
    private(set) var cameras: [CaptureDeviceInfo] = []
    private(set) var microphones: [CaptureDeviceInfo] = []

    /// Called with the unique ID of a device that disappeared.
    @ObservationIgnored var onDeviceDisconnected: ((String) -> Void)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.object as? AVCaptureDevice)?.uniqueID
            MainActor.assumeIsolated {
                self?.refresh()
                if let id { self?.onDeviceDisconnected?(id) }
            }
        })
    }

    func refresh() {
        let video = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video, position: .unspecified)
        cameras = video.devices.map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }

        let audio = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        microphones = audio.devices.map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
        Log.devices.debug("Devices: \(self.cameras.count) cameras, \(self.microphones.count) microphones")
    }

    /// The selected camera if it's connected, otherwise the system's preferred camera.
    func resolvedCameraID(preferred: String?) -> String? {
        if let preferred, cameras.contains(where: { $0.id == preferred }) { return preferred }
        return AVCaptureDevice.systemPreferredCamera?.uniqueID ?? cameras.first?.id
    }

    /// The selected microphone if connected; otherwise macOS's current default input device
    /// (System Settings › Sound › Input), which is what "Default microphone" means.
    func resolvedMicrophoneID(preferred: String?) -> String? {
        if let preferred, microphones.contains(where: { $0.id == preferred }) { return preferred }
        if let systemDefault = Self.systemDefaultInputUID(), microphones.contains(where: { $0.id == systemDefault }) {
            return systemDefault
        }
        return AVCaptureDevice.default(for: .audio)?.uniqueID ?? microphones.first?.id
    }

    /// UID of the Core Audio default input device. For audio devices this equals `AVCaptureDevice.uniqueID`.
    nonisolated static func systemDefaultInputUID() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
