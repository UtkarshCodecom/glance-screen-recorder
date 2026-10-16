import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Metal

/// Composites the latest screen frame and the camera bubble into an output pixel buffer on the GPU.
/// Not thread-safe: use from a single serial queue.
final class VideoCompositor {
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private struct DecorationKey: Equatable {
        let rect: CGRect
        let shape: CameraShape
        let border: RGBAColor
        let borderWidth: CGFloat
        let shadow: Bool
    }
    private var decorationCache: (key: DecorationKey, image: CIImage)?

    init() {
        let options: [CIContextOption: Any] = [.workingColorSpace: colorSpace, .cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    /// - Parameters:
    ///   - screen: Latest screen frame; scaled to fit the output if sizes differ. Black when `nil`.
    ///   - camera: Latest camera frame; the bubble is omitted when `nil`.
    func render(screen: CVPixelBuffer?, camera: CVPixelBuffer?, layout: CameraOverlayLayout, into output: CVPixelBuffer) {
        let canvas = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output))
        var image = CIImage(color: .black).cropped(to: canvas)
        if let screen {
            image = Self.aspectFit(CIImage(cvPixelBuffer: screen), in: canvas).composited(over: image)
        }
        if let camera {
            image = bubble(camera: CIImage(cvPixelBuffer: camera), layout: layout, canvas: canvas).composited(over: image)
        }
        context.render(image.cropped(to: canvas), to: output, bounds: canvas, colorSpace: colorSpace)
    }

    // MARK: - Building blocks

    private func bubble(camera: CIImage, layout: CameraOverlayLayout, canvas: CGRect) -> CIImage {
        // Layout rects use a top-left origin; Core Image uses bottom-left.
        let topLeftRect = layout.rect(in: canvas.size)
        let rect = CGRect(x: topLeftRect.minX, y: canvas.height - topLeftRect.maxY,
                          width: topLeftRect.width, height: topLeftRect.height)
        let borderWidth = layout.borderWidth(for: rect.size)
        let inner = rect.insetBy(dx: borderWidth, dy: borderWidth)
        guard inner.width > 2, inner.height > 2 else { return CIImage.empty() }

        var cam = layout.mirrored ? camera.oriented(.upMirrored) : camera
        cam = cam.transformed(by: CGAffineTransform(translationX: -cam.extent.minX, y: -cam.extent.minY))
        let scale = max(inner.width / cam.extent.width, inner.height / cam.extent.height)
        cam = cam.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        cam = cam.transformed(by: CGAffineTransform(translationX: inner.midX - cam.extent.midX, y: inner.midY - cam.extent.midY))
            .cropped(to: inner)

        let mask = Self.roundedRect(inner, radius: layout.shape.cornerRadius(for: inner.size), color: .white)
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = cam
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = mask
        let masked = blend.outputImage ?? cam

        return masked.composited(over: decoration(rect: rect, layout: layout, borderWidth: borderWidth))
    }

    /// Border and drop shadow behind the camera; rendered once per layout and cached as a bitmap.
    private func decoration(rect: CGRect, layout: CameraOverlayLayout, borderWidth: CGFloat) -> CIImage {
        let key = DecorationKey(rect: rect, shape: layout.shape, border: layout.borderColor,
                                borderWidth: borderWidth, shadow: layout.showsShadow)
        if let cached = decorationCache, cached.key == key { return cached.image }

        let radius = layout.shape.cornerRadius(for: rect.size)
        var image = CIImage.empty()
        if layout.showsShadow {
            let blurRadius = rect.height * 0.05
            let shadow = Self.roundedRect(rect.offsetBy(dx: 0, dy: -rect.height * 0.025), radius: radius,
                                          color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.38))
                .applyingGaussianBlur(sigma: blurRadius)
                .cropped(to: rect.insetBy(dx: -blurRadius * 3, dy: -blurRadius * 3))
            image = shadow
        }
        if borderWidth > 0 {
            let c = layout.borderColor
            let border = Self.roundedRect(rect, radius: radius,
                                          color: CIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha))
            image = border.composited(over: image)
        }

        var result = image
        let extent = image.extent.integral
        if !extent.isEmpty, !extent.isInfinite, let cg = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: colorSpace) {
            result = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        }
        decorationCache = (key, result)
        return result
    }

    static func aspectFit(_ image: CIImage, in canvas: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        if extent.size == canvas.size { return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)) }
        let scale = min(canvas.width / extent.width, canvas.height / extent.height)
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(by: CGAffineTransform(translationX: (canvas.width - scaled.extent.width) / 2,
                                                         y: (canvas.height - scaled.extent.height) / 2))
    }

    private static func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let generator = CIFilter.roundedRectangleGenerator()
        generator.extent = rect
        generator.radius = Float(radius)
        generator.color = color
        return generator.outputImage?.cropped(to: rect) ?? CIImage.empty()
    }
}
