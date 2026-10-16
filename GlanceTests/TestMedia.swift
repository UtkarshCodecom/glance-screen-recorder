import AVFoundation
import CoreMedia
import CoreVideo
@testable import Glance

/// Synthetic media helpers for pipeline tests.
enum TestMedia {
    static func solidPixelBuffer(width: Int, height: Int, bgra: (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary, &buffer)
        let pb = buffer!
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * bytesPerRow + x * 4
                p[0] = bgra.0; p[1] = bgra.1; p[2] = bgra.2; p[3] = bgra.3
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// Float32 PCM sine wave, non-interleaved when `channels > 1` (the layout ScreenCaptureKit delivers).
    static func sineBuffer(frequency: Double, amplitude: Float, channels: Int, frames: Int, sampleRate: Double,
                           startFrame: Int, pts: CMTime) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (channels > 1 ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let avFormat = AVAudioFormat(cmAudioFormatDescription: format!)
        let pcm = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels {
            let data = pcm.floatChannelData![c]
            for i in 0..<frames {
                data[i] = amplitude * Float(sin(2 * Double.pi * frequency * Double(startFrame + i) / sampleRate))
            }
        }
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1,
                             sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                             sampleBufferOut: &sampleBuffer)
        CMSampleBufferSetDataBufferFromAudioBufferList(sampleBuffer!, blockBufferAllocator: nil,
                                                       blockBufferMemoryAllocator: nil, flags: 0,
                                                       bufferList: pcm.audioBufferList)
        return sampleBuffer!
    }
}

extension TestMedia {
    /// RMS (0…1) of the first enabled audio track of a file, decoded to float PCM.
    static func audioRMS(of url: URL) async throws -> Float {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        reader.startReading()
        var sum: Double = 0
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if let rms = AudioLevelMeter.rms(of: sample) {
                let n = sample.numSamples
                sum += Double(rms * rms) * Double(n)
                count += n
            }
        }
        return count > 0 ? Float((sum / Double(count)).squareRoot()) : 0
    }
}
