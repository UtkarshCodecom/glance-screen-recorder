import CoreMedia
import ScreenCaptureKit

/// Thin wrapper around one `SCStream`: screen frames, system audio and (macOS 15+) microphone audio.
/// Each output type is delivered on its own serial queue, so callbacks across types are not ordered
/// relative to each other; consumers must rely on presentation timestamps.
final class ScreenCapture: NSObject, @unchecked Sendable {
    struct Handlers {
        var screenFrame: (CVPixelBuffer) -> Void
        var systemAudio: (CMSampleBuffer) -> Void
        var microphone: (CMSampleBuffer) -> Void
        var stopped: (Error) -> Void
    }

    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let handlers: Handlers
    private var stream: SCStream?

    private let videoQueue = DispatchQueue(label: "dev.utkarsh.Glance.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "dev.utkarsh.Glance.capture.audio", qos: .userInteractive)
    private let micQueue = DispatchQueue(label: "dev.utkarsh.Glance.capture.mic", qos: .userInteractive)

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, handlers: Handlers) {
        self.filter = filter
        self.configuration = configuration
        self.handlers = handlers
    }

    func start() async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if configuration.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        if configuration.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        }
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            self.stream = nil
            throw error
        }
        Log.capture.info("Screen capture started (\(self.configuration.width)x\(self.configuration.height))")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            Log.capture.error("stopCapture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func makeConfiguration(outputSize: CGSize, frameRate: Int, showsCursor: Bool,
                                  capturesSystemAudio: Bool, capturesMicrophone: Bool,
                                  microphoneDeviceID: String?) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(outputSize.width)
        config.height = Int(outputSize.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = showsCursor
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.queueDepth = 6
        config.capturesAudio = capturesSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = capturesMicrophone
        if capturesMicrophone {
            config.microphoneCaptureDeviceID = microphoneDeviceID
        }
        return config
    }
}

extension ScreenCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            // Only complete frames carry new pixels; idle/blank frames are skipped and the last frame is reused.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete,
                  let pixelBuffer = sampleBuffer.imageBuffer else { return }
            handlers.screenFrame(pixelBuffer)
        case .audio:
            handlers.systemAudio(sampleBuffer)
        case .microphone:
            handlers.microphone(sampleBuffer)
        @unknown default:
            break
        }
    }
}

extension ScreenCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.capture.error("Stream stopped: \(error.localizedDescription, privacy: .public)")
        handlers.stopped(error)
    }
}
