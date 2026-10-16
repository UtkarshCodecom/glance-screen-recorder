import CoreGraphics

enum OutputSizing {
    /// Largest edge we encode. Apple's H.264 encoders top out at 4096 pixels.
    static let maximumLongEdge: CGFloat = 4096

    /// Encoded frame size for content of `contentPixelSize`, scaled down (never up) to the quality's
    /// bounding box, preserving aspect ratio and rounded to even dimensions.
    static func outputSize(contentPixelSize: CGSize, quality: VideoQuality) -> CGSize {
        guard contentPixelSize.width >= 2, contentPixelSize.height >= 2 else { return CGSize(width: 2, height: 2) }
        let longEdge = max(contentPixelSize.width, contentPixelSize.height)
        let shortEdge = min(contentPixelSize.width, contentPixelSize.height)
        var scale: CGFloat = 1
        if let box = quality.boundingBox {
            scale = min(scale, box.long / longEdge, box.short / shortEdge)
        }
        scale = min(scale, maximumLongEdge / longEdge)
        return CGSize(width: even(contentPixelSize.width * scale), height: even(contentPixelSize.height * scale))
    }

    static func videoBitrate(for size: CGSize, frameRate: Int, codec: VideoCodecChoice) -> Int {
        let bitsPerPixel: Double = codec == .hevc ? 0.08 : 0.13
        // Higher frame rates compress better per frame; scale sub-linearly.
        let effectiveFPS = 30 * pow(Double(frameRate) / 30, 0.6)
        let bitrate = Double(size.width * size.height) * effectiveFPS * bitsPerPixel
        return Int(min(max(bitrate, 1_500_000), 60_000_000))
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded(.down) * 2)
    }
}
