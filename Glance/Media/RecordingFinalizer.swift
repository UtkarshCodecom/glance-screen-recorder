import AVFoundation

struct FinalizeOptions {
    var systemVolume: Float = 1
    var microphoneVolume: Float = 1
    /// Also store the untouched system and microphone tracks (disabled by default in players).
    var keepsSeparateTracks = false

    func volume(for role: AudioRole?) -> Float {
        switch role {
        case .system: return systemVolume
        case .microphone: return microphoneVolume
        case nil: return 1
        }
    }
}

struct RecordingVerification: Equatable {
    let duration: TimeInterval
    let videoSize: CGSize
    let enabledAudioTracks: Int
    let totalAudioTracks: Int
    let fileSize: Int64
}

/// Turns the intermediate movie into the shareable MP4: the video is passed through untouched,
/// all audio tracks are mixed (with per-source volume) into one AAC track, and the result is
/// written with the movie header up front, then verified.
enum RecordingFinalizer {
    static func finalize(intermediate: URL, audioRoles: [AudioRole]?, destination: URL,
                         options: FinalizeOptions) async throws -> RecordingVerification {
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent).partial.mp4")
        try? FileManager.default.removeItem(at: partial)
        do {
            try await export(intermediate: intermediate, audioRoles: audioRoles, to: partial, options: options)
            let verification = try await verify(partial)
            if FileManager.default.fileExists(atPath: destination.path) {
                throw RecorderError.exportFailed("A file named \(destination.lastPathComponent) already exists.")
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            Log.media.info("Finalized \(destination.lastPathComponent, privacy: .public): \(verification.duration)s")
            return verification
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    private static func export(intermediate: URL, audioRoles: [AudioRole]?, to output: URL, options: FinalizeOptions) async throws {
        let asset = AVURLAsset(url: intermediate)
        let videoTracks: [AVAssetTrack]
        let allAudioTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            allAudioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw RecorderError.exportFailed("The recorded file couldn't be read: \(error.localizedDescription)")
        }
        guard let videoTrack = videoTracks.first else { throw RecorderError.noVideoFrames }

        // Skip empty tracks (a source that never delivered audio); roles follow track order.
        var audioTracks: [AVAssetTrack] = []
        for track in allAudioTracks {
            let range = try await track.load(.timeRange)
            if range.duration.seconds > 0 { audioTracks.append(track) }
        }
        let roles: [AudioRole?] = audioTracks.indices.map { index in
            guard let audioRoles, audioRoles.count == audioTracks.count else { return nil }
            return audioRoles[index]
        }

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        } catch {
            throw RecorderError.exportFailed(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true

        // Video: passthrough.
        let (formatDescriptions, transform) = try await videoTrack.load(.formatDescriptions, .preferredTransform)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw RecorderError.exportFailed("The video track can't be read.") }
        reader.add(videoOutput)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatDescriptions.first)
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else { throw RecorderError.exportFailed("The video track can't be written as MP4.") }
        writer.add(videoInput)
        var pumps: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]

        // Audio: one mixed, enabled track.
        if !audioTracks.isEmpty {
            let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            let mix = AVMutableAudioMix()
            mix.inputParameters = zip(audioTracks, roles).map { track, role in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(options.volume(for: role), at: .zero)
                return parameters
            }
            mixOutput.audioMix = mix
            guard reader.canAdd(mixOutput) else { throw RecorderError.exportFailed("The audio tracks can't be mixed.") }
            reader.add(mixOutput)
            let mixedInput = AVAssetWriterInput(mediaType: .audio, outputSettings: MediaWriter.aacSettings)
            guard writer.canAdd(mixedInput) else { throw RecorderError.exportFailed("The mixed audio track can't be written.") }
            writer.add(mixedInput)
            pumps.append((mixOutput, mixedInput))

            if options.keepsSeparateTracks && audioTracks.count > 1 {
                for track in audioTracks {
                    let format = try await track.load(.formatDescriptions).first
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
                    input.marksOutputTrackAsEnabled = false
                    if reader.canAdd(output), writer.canAdd(input) {
                        reader.add(output)
                        writer.add(input)
                        pumps.append((output, input))
                    }
                }
            }
        }

        guard reader.startReading() else {
            throw RecorderError.exportFailed(reader.error?.localizedDescription ?? "Reading the recording failed.")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw RecorderError.exportFailed(writer.error?.localizedDescription ?? "Writing the MP4 failed.")
        }
        writer.startSession(atSourceTime: .zero)

        // Outputs of one reader must be drained concurrently or the reader can stall.
        await withTaskGroup(of: Void.self) { group in
            for (index, pump) in pumps.enumerated() {
                let box = PumpBox(output: pump.0, input: pump.1)
                group.addTask { await box.run(label: "finalize.pump.\(index)") }
            }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw RecorderError.exportFailed(reader.error?.localizedDescription ?? "Reading the recording failed.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RecorderError.exportFailed(writer.error?.localizedDescription ?? "Writing the MP4 failed.")
        }
    }

    /// Confirms the file opens, is playable, and has a non-empty video track.
    static func verify(_ url: URL) async throws -> RecordingVerification {
        let asset = AVURLAsset(url: url)
        do {
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard playable else { throw RecorderError.verificationFailed("The file isn't playable.") }
            guard duration.seconds > 0, let video = videoTracks.first else {
                throw RecorderError.verificationFailed("The file has no video.")
            }
            let size = try await video.load(.naturalSize)
            var enabled = 0
            for track in audioTracks where try await track.load(.isEnabled) { enabled += 1 }
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return RecordingVerification(duration: duration.seconds, videoSize: size, enabledAudioTracks: enabled,
                                         totalAudioTracks: audioTracks.count, fileSize: fileSize)
        } catch let error as RecorderError {
            throw error
        } catch {
            throw RecorderError.verificationFailed(error.localizedDescription)
        }
    }
}

/// Copies samples from one reader output to one writer input on its own queue.
private final class PumpBox: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput) {
        self.output = output
        self.input = input
    }

    func run(label: String) async {
        let queue = DispatchQueue(label: "dev.utkarsh.Glance.\(label)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
