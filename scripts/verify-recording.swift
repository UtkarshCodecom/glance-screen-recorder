// Usage: swift scripts/verify-recording.swift "/path/to/recording.mp4"
// Prints container/track details and fails (exit 1) if the file isn't a playable MP4 with video.
import AVFoundation

let args = CommandLine.arguments
guard args.count == 2 else { print("usage: verify-recording.swift <file.mp4>"); exit(2) }
let url = URL(fileURLWithPath: args[1])

func fourCC(_ code: FourCharCode) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii) ?? "\(code)"
}

let semaphore = DispatchSemaphore(value: 0)
var failed = false
Task {
    defer { semaphore.signal() }
    do {
        let asset = AVURLAsset(url: url)
        let (playable, duration) = try await asset.load(.isPlayable, .duration)
        print("File:      \(url.lastPathComponent)")
        print("Playable:  \(playable)")
        print(String(format: "Duration:  %.2f s", duration.seconds))
        let tracks = try await asset.load(.tracks)
        var hasVideo = false
        for track in tracks {
            let type = track.mediaType
            let (enabled, range, formats) = try await track.load(.isEnabled, .timeRange, .formatDescriptions)
            let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
            var line = "Track \(track.trackID): \(type.rawValue) \(codec) enabled=\(enabled) start=\(String(format: "%.3f", range.start.seconds)) dur=\(String(format: "%.2f", range.duration.seconds))"
            if type == .video {
                hasVideo = true
                let (size, fps, rate) = try await track.load(.naturalSize, .nominalFrameRate, .estimatedDataRate)
                line += " \(Int(size.width))x\(Int(size.height)) \(String(format: "%.1f", fps))fps \(Int(rate / 1000))kbps"
            } else if type == .audio, let asbd = formats.first.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }) {
                line += " \(Int(asbd.mSampleRate))Hz \(asbd.mChannelsPerFrame)ch"
            }
            print(line)
        }
        if !playable || !hasVideo || duration.seconds <= 0 { failed = true; print("FAIL: not a playable video") } else { print("OK") }
    } catch {
        failed = true
        print("FAIL: \(error.localizedDescription)")
    }
}
semaphore.wait()
exit(failed ? 1 : 0)
