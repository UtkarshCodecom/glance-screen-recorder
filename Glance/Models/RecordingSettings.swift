import CoreGraphics
import Foundation

enum VideoQuality: String, CaseIterable, Codable, Identifiable {
    case hd720
    case hd1080
    case qhd1440
    case native

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        case .qhd1440: return "1440p"
        case .native: return "Native"
        }
    }

    var detail: String {
        switch self {
        case .hd720: return "Smallest files"
        case .hd1080: return "Recommended"
        case .qhd1440: return "Sharper text"
        case .native: return "Full resolution, up to 4K"
        }
    }

    /// Bounding box (long edge × short edge) the output is scaled to fit. `nil` keeps the source size.
    var boundingBox: (long: CGFloat, short: CGFloat)? {
        switch self {
        case .hd720: return (1280, 720)
        case .hd1080: return (1920, 1080)
        case .qhd1440: return (2560, 1440)
        case .native: return nil
        }
    }
}

enum FrameRate: Int, CaseIterable, Codable, Identifiable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }
    var title: String { "\(rawValue) fps" }
}

enum VideoCodecChoice: String, CaseIterable, Codable, Identifiable {
    case h264
    case hevc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264: return "H.264 (most compatible)"
        case .hevc: return "HEVC (smaller files)"
        }
    }
}

struct RecordingSettings: Codable, Equatable {
    var quality: VideoQuality = .hd1080
    var frameRate: FrameRate = .fps30
    var codec: VideoCodecChoice = .h264
    var countdownSeconds: Int = 3
    var capturesSystemAudio = true
    var capturesMicrophone = true
    var cameraEnabled = true
    var systemAudioVolume: Float = 0.8
    var microphoneVolume: Float = 1.0
    var keepsSeparateAudioTracks = false
    var showsCursor = true
    var hidesMainWindowWhileRecording = true
    var selectedCameraID: String?
    var selectedMicrophoneID: String?
    var outputDirectoryPath: String?
    var cameraLayout = CameraOverlayLayout()

    static let countdownChoices = [0, 3, 5, 10]

    init() {}

    // Decoding field-by-field keeps older saved settings loadable when new fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecordingSettings()
        quality = (try? c.decode(VideoQuality.self, forKey: .quality)) ?? d.quality
        frameRate = (try? c.decode(FrameRate.self, forKey: .frameRate)) ?? d.frameRate
        codec = (try? c.decode(VideoCodecChoice.self, forKey: .codec)) ?? d.codec
        countdownSeconds = (try? c.decode(Int.self, forKey: .countdownSeconds)) ?? d.countdownSeconds
        capturesSystemAudio = (try? c.decode(Bool.self, forKey: .capturesSystemAudio)) ?? d.capturesSystemAudio
        capturesMicrophone = (try? c.decode(Bool.self, forKey: .capturesMicrophone)) ?? d.capturesMicrophone
        cameraEnabled = (try? c.decode(Bool.self, forKey: .cameraEnabled)) ?? d.cameraEnabled
        systemAudioVolume = (try? c.decode(Float.self, forKey: .systemAudioVolume)) ?? d.systemAudioVolume
        microphoneVolume = (try? c.decode(Float.self, forKey: .microphoneVolume)) ?? d.microphoneVolume
        keepsSeparateAudioTracks = (try? c.decode(Bool.self, forKey: .keepsSeparateAudioTracks)) ?? d.keepsSeparateAudioTracks
        showsCursor = (try? c.decode(Bool.self, forKey: .showsCursor)) ?? d.showsCursor
        hidesMainWindowWhileRecording = (try? c.decode(Bool.self, forKey: .hidesMainWindowWhileRecording)) ?? d.hidesMainWindowWhileRecording
        selectedCameraID = try? c.decodeIfPresent(String.self, forKey: .selectedCameraID)
        selectedMicrophoneID = try? c.decodeIfPresent(String.self, forKey: .selectedMicrophoneID)
        outputDirectoryPath = try? c.decodeIfPresent(String.self, forKey: .outputDirectoryPath)
        cameraLayout = (try? c.decode(CameraOverlayLayout.self, forKey: .cameraLayout)) ?? d.cameraLayout
    }
}
