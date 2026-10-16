import AVFoundation
import CoreMedia

enum AudioRole: String, Codable, CaseIterable {
    case system
    case microphone
}

/// Writes the real-time intermediate movie: one composited video track plus one AAC track per audio
/// source. All methods must be called from the same serial queue.
final class MediaWriter {
    struct Configuration {
        var url: URL
        var videoSize: CGSize
        var frameRate: Int
        var codec: VideoCodecChoice
        var audioRoles: [AudioRole]
    }

    let configuration: Configuration
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var audioInputs: [AudioRole: AVAssetWriterInput] = [:]

    private(set) var videoFrameCount = 0
    private(set) var droppedVideoFrames = 0
    private(set) var audioSampleCounts: [AudioRole: Int] = [:]
    private(set) var lastVideoTime: CMTime = .invalid
    private var lastAudioTime: [AudioRole: CMTime] = [:]

    init(configuration: Configuration) throws {
        self.configuration = configuration
        try? FileManager.default.removeItem(at: configuration.url)
        do {
            writer = try AVAssetWriter(outputURL: configuration.url, fileType: .mov)
        } catch {
            throw RecorderError.writerFailed(error.localizedDescription)
        }
        // Fragments keep everything up to the last few seconds playable if the app crashes.
        writer.movieFragmentInterval = CMTime(seconds: 4, preferredTimescale: 600)

        let width = Int(configuration.videoSize.width)
        let height = Int(configuration.videoSize.height)
        videoInput = AVAssetWriterInput(mediaType: .video,
                                        outputSettings: Self.videoSettings(width: width, height: height,
                                                                           frameRate: configuration.frameRate,
                                                                           codec: configuration.codec))
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw RecorderError.writerFailed("This Mac can't encode \(width)×\(height) video with \(configuration.codec.title).")
        }
        writer.add(videoInput)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])

        for role in configuration.audioRoles {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.writerFailed("Couldn't add the \(role.rawValue) audio track.") }
            writer.add(input)
            audioInputs[role] = input
        }
    }

    static let aacSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 192_000,
    ]

    static func videoSettings(width: Int, height: Int, frameRate: Int, codec: VideoCodecChoice) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: OutputSizing.videoBitrate(for: CGSize(width: width, height: height),
                                                                frameRate: frameRate, codec: codec),
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
        ]
        if codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        return [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    func start() throws {
        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "The writer couldn't start.")
        }
        writer.startSession(atSourceTime: .zero)
    }

    var isWriting: Bool { writer.status == .writing }
    var failure: Error? { writer.status == .failed ? writer.error : nil }

    /// A buffer from the encoder's pool, or `nil` when the encoder is backed up (the frame is dropped
    /// instead of queuing unbounded work).
    func makeVideoBuffer() -> CVPixelBuffer? {
        guard isWriting, videoInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else {
            droppedVideoFrames += 1
            return nil
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    @discardableResult
    func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        guard isWriting, videoInput.isReadyForMoreMediaData else { droppedVideoFrames += 1; return false }
        if lastVideoTime.isValid, time <= lastVideoTime { return false }
        guard adaptor.append(buffer, withPresentationTime: time) else {
            Log.media.error("Video append failed: \(self.writer.error?.localizedDescription ?? "unknown", privacy: .public)")
            return false
        }
        lastVideoTime = time
        videoFrameCount += 1
        return true
    }

    /// Appends an audio buffer, retimed so its first sample lands at `time` on the output timeline.
    @discardableResult
    func appendAudio(_ sampleBuffer: CMSampleBuffer, role: AudioRole, at time: CMTime) -> Bool {
        guard isWriting, let input = audioInputs[role] else { return false }
        if let last = lastAudioTime[role], time <= last { return false }
        guard input.isReadyForMoreMediaData else {
            Log.media.debug("Dropping \(role.rawValue) audio: encoder busy")
            return false
        }
        guard let retimed = Self.retime(sampleBuffer, to: time) else { return false }
        guard input.append(retimed) else {
            Log.media.error("Audio append failed: \(self.writer.error?.localizedDescription ?? "unknown", privacy: .public)")
            return false
        }
        lastAudioTime[role] = time
        audioSampleCounts[role, default: 0] += 1
        return true
    }

    /// Roles that received at least one buffer, in track order.
    var recordedAudioRoles: [AudioRole] {
        configuration.audioRoles.filter { (audioSampleCounts[$0] ?? 0) > 0 }
    }

    func finish(completion: @escaping (Result<Void, Error>) -> Void) {
        guard writer.status == .writing else {
            completion(.failure(RecorderError.writerFailed(writer.error?.localizedDescription ?? "The writer stopped early.")))
            return
        }
        guard videoFrameCount > 0 else {
            writer.cancelWriting()
            completion(.failure(RecorderError.noVideoFrames))
            return
        }
        videoInput.markAsFinished()
        audioInputs.values.forEach { $0.markAsFinished() }
        writer.endSession(atSourceTime: lastVideoTime + CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate)))
        writer.finishWriting { [writer] in
            if writer.status == .completed {
                completion(.success(()))
            } else {
                completion(.failure(RecorderError.writerFailed(writer.error?.localizedDescription ?? "Finishing the file failed.")))
            }
        }
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: configuration.url)
    }

    static func retime(_ sampleBuffer: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        if count > 0 {
            CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        } else {
            timing[0] = CMSampleTimingInfo(duration: sampleBuffer.duration, presentationTimeStamp: sampleBuffer.presentationTimeStamp,
                                           decodeTimeStamp: .invalid)
        }
        let delta = time - sampleBuffer.presentationTimeStamp
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp + delta
            timing[i].decodeTimeStamp = .invalid
        }
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
                                                           sampleTimingEntryCount: timing.count, sampleTimingArray: &timing,
                                                           sampleBufferOut: &output)
        return status == noErr ? output : nil
    }
}
