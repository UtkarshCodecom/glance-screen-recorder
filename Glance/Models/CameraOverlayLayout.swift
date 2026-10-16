import CoreGraphics
import Foundation

enum CameraShape: String, CaseIterable, Codable, Identifiable {
    case circle
    case roundedSquare
    case roundedRectangle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .circle: return "Circle"
        case .roundedSquare: return "Square"
        case .roundedRectangle: return "Landscape"
        }
    }

    var systemImage: String {
        switch self {
        case .circle: return "circle"
        case .roundedSquare: return "square"
        case .roundedRectangle: return "rectangle"
        }
    }

    /// Width divided by height.
    var aspectRatio: CGFloat {
        switch self {
        case .circle, .roundedSquare: return 1
        case .roundedRectangle: return 4.0 / 3.0
        }
    }

    func cornerRadius(for size: CGSize) -> CGFloat {
        switch self {
        case .circle: return min(size.width, size.height) / 2
        case .roundedSquare, .roundedRectangle: return min(size.width, size.height) * 0.18
        }
    }

    var next: CameraShape {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

struct RGBAColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
}

/// Resolution-independent description of where and how the camera bubble is drawn.
/// Positions are normalized to the captured content with a top-left origin, so the same layout
/// maps onto the on-screen preview, the floating bubble and the encoded frames.
struct CameraOverlayLayout: Codable, Equatable {
    var shape: CameraShape = .circle
    /// Bubble height as a fraction of the shorter edge of the frame.
    var sizeFraction: Double = 0.28
    /// Normalized bubble center, top-left origin.
    var center: CGPoint = CGPoint(x: 0.86, y: 0.78)
    var mirrored = true
    var borderColor: RGBAColor = .white
    /// Border width as a fraction of the bubble height.
    var borderWidthFraction: Double = 0.025
    var showsShadow = true

    static let sizeRange: ClosedRange<Double> = 0.12...0.6
    static let sizeStep = 0.04
    /// Gap kept between the bubble and the frame edges, as a fraction of the shorter edge.
    static let edgeMarginFraction: CGFloat = 0.025

    enum Corner: String, CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight
        var id: String { rawValue }
        var title: String {
            switch self {
            case .topLeft: return "Top Left"
            case .topRight: return "Top Right"
            case .bottomLeft: return "Bottom Left"
            case .bottomRight: return "Bottom Right"
            }
        }
    }

    func bubbleSize(in frame: CGSize) -> CGSize {
        let height = (min(frame.width, frame.height) * CGFloat(clampedSize)).rounded()
        return CGSize(width: (height * shape.aspectRatio).rounded(), height: height)
    }

    var clampedSize: Double { min(max(sizeFraction, Self.sizeRange.lowerBound), Self.sizeRange.upperBound) }

    /// Bubble rectangle in `frame` coordinates (top-left origin), kept fully inside the frame.
    func rect(in frame: CGSize) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let size = bubbleSize(in: frame)
        let margin = min(frame.width, frame.height) * Self.edgeMarginFraction
        let minX = margin + size.width / 2
        let maxX = frame.width - margin - size.width / 2
        let minY = margin + size.height / 2
        let maxY = frame.height - margin - size.height / 2
        let cx = minX <= maxX ? min(max(center.x * frame.width, minX), maxX) : frame.width / 2
        let cy = minY <= maxY ? min(max(center.y * frame.height, minY), maxY) : frame.height / 2
        return CGRect(x: cx - size.width / 2, y: cy - size.height / 2, width: size.width, height: size.height).integral
    }

    func borderWidth(for bubbleSize: CGSize) -> CGFloat {
        max(0, (bubbleSize.height * CGFloat(borderWidthFraction)).rounded())
    }

    /// Updates the center from a bubble rect in `frame` coordinates (top-left origin).
    mutating func setCenter(fromRect rect: CGRect, in frame: CGSize) {
        guard frame.width > 0, frame.height > 0 else { return }
        center = CGPoint(x: rect.midX / frame.width, y: rect.midY / frame.height)
    }

    mutating func move(to corner: Corner, in frame: CGSize) {
        let size = bubbleSize(in: frame)
        let margin = min(frame.width, frame.height) * Self.edgeMarginFraction
        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .topLeft, .bottomLeft: x = margin + size.width / 2
        case .topRight, .bottomRight: x = frame.width - margin - size.width / 2
        }
        switch corner {
        case .topLeft, .topRight: y = margin + size.height / 2
        case .bottomLeft, .bottomRight: y = frame.height - margin - size.height / 2
        }
        center = CGPoint(x: x / frame.width, y: y / frame.height)
    }

    mutating func resize(by delta: Double) {
        sizeFraction = min(max(sizeFraction + delta, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
    }
}
