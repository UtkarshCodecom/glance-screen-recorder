import CoreGraphics
import XCTest
@testable import Glance

final class CameraOverlayLayoutTests: XCTestCase {
    let frame = CGSize(width: 1920, height: 1080)

    func testBubbleSizeFollowsShortEdge() {
        var layout = CameraOverlayLayout()
        layout.sizeFraction = 0.25
        XCTAssertEqual(layout.bubbleSize(in: frame), CGSize(width: 270, height: 270))
        layout.shape = .roundedRectangle
        XCTAssertEqual(layout.bubbleSize(in: frame), CGSize(width: 360, height: 270))
    }

    func testRectStaysInsideFrame() {
        var layout = CameraOverlayLayout()
        for center in [CGPoint(x: -1, y: -1), CGPoint(x: 2, y: 2), CGPoint(x: 1, y: 0), CGPoint(x: 0.5, y: 0.5)] {
            layout.center = center
            let rect = layout.rect(in: frame)
            XCTAssertTrue(CGRect(origin: .zero, size: frame).contains(rect), "\(center) → \(rect)")
        }
    }

    func testDefaultIsBottomRight() {
        let rect = CameraOverlayLayout().rect(in: frame)
        XCTAssertGreaterThan(rect.midX, frame.width / 2)
        XCTAssertGreaterThan(rect.midY, frame.height / 2, "top-left origin: larger y is lower on screen")
    }

    func testCornerPresets() {
        var layout = CameraOverlayLayout()
        let margin = min(frame.width, frame.height) * CameraOverlayLayout.edgeMarginFraction
        layout.move(to: .topLeft, in: frame)
        XCTAssertEqual(layout.rect(in: frame).minX, margin, accuracy: 1)
        XCTAssertEqual(layout.rect(in: frame).minY, margin, accuracy: 1)
        layout.move(to: .bottomRight, in: frame)
        XCTAssertEqual(layout.rect(in: frame).maxX, frame.width - margin, accuracy: 1)
        XCTAssertEqual(layout.rect(in: frame).maxY, frame.height - margin, accuracy: 1)
    }

    func testLayoutIsResolutionIndependent() {
        var layout = CameraOverlayLayout()
        layout.move(to: .bottomLeft, in: frame)
        let big = layout.rect(in: CGSize(width: 3840, height: 2160))
        let small = layout.rect(in: frame)
        XCTAssertEqual(big.minX / 2, small.minX, accuracy: 1)
        XCTAssertEqual(big.width / 2, small.width, accuracy: 1)
    }

    func testSetCenterRoundTrips() {
        var layout = CameraOverlayLayout()
        let rect = CGRect(x: 100, y: 200, width: 300, height: 300)
        layout.setCenter(fromRect: rect, in: frame)
        XCTAssertEqual(layout.center.x, 250 / 1920, accuracy: 1e-9)
        XCTAssertEqual(layout.center.y, 350 / 1080, accuracy: 1e-9)
    }

    func testResizeClampsToRange() {
        var layout = CameraOverlayLayout()
        for _ in 0..<50 { layout.resize(by: CameraOverlayLayout.sizeStep) }
        XCTAssertEqual(layout.sizeFraction, CameraOverlayLayout.sizeRange.upperBound)
        for _ in 0..<50 { layout.resize(by: -CameraOverlayLayout.sizeStep) }
        XCTAssertEqual(layout.sizeFraction, CameraOverlayLayout.sizeRange.lowerBound)
    }

    func testCircleCornerRadiusIsHalfSize() {
        XCTAssertEqual(CameraShape.circle.cornerRadius(for: CGSize(width: 200, height: 200)), 100)
        XCTAssertLessThan(CameraShape.roundedSquare.cornerRadius(for: CGSize(width: 200, height: 200)), 100)
    }

    func testShapeCycle() {
        XCTAssertEqual(CameraShape.circle.next, .roundedSquare)
        XCTAssertEqual(CameraShape.roundedRectangle.next, .circle)
    }
}

final class OutputSizingTests: XCTestCase {
    func testRetinaDisplayScaledTo1080p() {
        let size = OutputSizing.outputSize(contentPixelSize: CGSize(width: 3024, height: 1964), quality: .hd1080)
        XCTAssertLessThanOrEqual(size.width, 1920)
        XCTAssertLessThanOrEqual(size.height, 1080)
        XCTAssertEqual(size.width / size.height, 3024 / 1964, accuracy: 0.01)
        XCTAssertEqual(Int(size.width) % 2, 0)
        XCTAssertEqual(Int(size.height) % 2, 0)
    }

    func testNeverUpscales() {
        let size = OutputSizing.outputSize(contentPixelSize: CGSize(width: 800, height: 600), quality: .qhd1440)
        XCTAssertEqual(size, CGSize(width: 800, height: 600))
    }

    func testPortraitWindowUsesRotatedBox() {
        let size = OutputSizing.outputSize(contentPixelSize: CGSize(width: 1200, height: 2400), quality: .hd720)
        XCTAssertEqual(size.height, 1280)
        XCTAssertEqual(size.width, 640)
    }

    func testNativeIsCappedForEncoder() {
        let size = OutputSizing.outputSize(contentPixelSize: CGSize(width: 5120, height: 2880), quality: .native)
        XCTAssertEqual(size.width, 4096)
        XCTAssertEqual(size.height, 2304)
    }

    func testOddSizesRoundToEven() {
        let size = OutputSizing.outputSize(contentPixelSize: CGSize(width: 1001, height: 777), quality: .native)
        XCTAssertEqual(size, CGSize(width: 1000, height: 776))
    }

    func testBitrateScalesAndIsBounded() {
        let b1080 = OutputSizing.videoBitrate(for: CGSize(width: 1920, height: 1080), frameRate: 30, codec: .h264)
        let b1080hevc = OutputSizing.videoBitrate(for: CGSize(width: 1920, height: 1080), frameRate: 30, codec: .hevc)
        let b1080at60 = OutputSizing.videoBitrate(for: CGSize(width: 1920, height: 1080), frameRate: 60, codec: .h264)
        XCTAssertGreaterThan(b1080, b1080hevc)
        XCTAssertGreaterThan(b1080at60, b1080)
        XCTAssertLessThan(b1080at60, b1080 * 2)
        XCTAssertGreaterThanOrEqual(OutputSizing.videoBitrate(for: CGSize(width: 10, height: 10), frameRate: 24, codec: .hevc), 1_500_000)
    }
}
