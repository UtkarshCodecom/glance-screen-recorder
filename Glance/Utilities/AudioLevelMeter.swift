import AudioToolbox
import CoreMedia

enum AudioLevelMeter {
    /// Root-mean-square amplitude (0…1) across all channels of a PCM sample buffer.
    static func rms(of sampleBuffer: CMSampleBuffer) -> Float? {
        guard let format = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard sizeNeeded > 0 else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: listPointer, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer)
        guard status == noErr else { return nil }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var sumOfSquares: Double = 0
        var count = 0
        for buffer in UnsafeMutableAudioBufferListPointer(listPointer) {
            guard let data = buffer.mData else { continue }
            let bytes = Int(buffer.mDataByteSize)
            if isFloat && asbd.mBitsPerChannel == 32 {
                let samples = data.bindMemory(to: Float.self, capacity: bytes / 4)
                for i in 0..<(bytes / 4) { let s = Double(samples[i]); sumOfSquares += s * s }
                count += bytes / 4
            } else if !isFloat && asbd.mBitsPerChannel == 16 {
                let samples = data.bindMemory(to: Int16.self, capacity: bytes / 2)
                for i in 0..<(bytes / 2) { let s = Double(samples[i]) / 32768; sumOfSquares += s * s }
                count += bytes / 2
            } else if !isFloat && asbd.mBitsPerChannel == 32 {
                let samples = data.bindMemory(to: Int32.self, capacity: bytes / 4)
                for i in 0..<(bytes / 4) { let s = Double(samples[i]) / 2147483648; sumOfSquares += s * s }
                count += bytes / 4
            }
        }
        guard count > 0 else { return nil }
        return Float((sumOfSquares / Double(count)).squareRoot())
    }

    /// Maps an RMS amplitude to a 0…1 meter value on a dB scale.
    static func normalizedLevel(rms: Float, floorDecibels: Float = -55) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(max((db - floorDecibels) / -floorDecibels, 0), 1)
    }
}
