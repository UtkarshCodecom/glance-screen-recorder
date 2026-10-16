import AppKit
import AVFoundation
import SwiftUI

/// Live camera preview rendered from the same frames the compositor uses, so what you see is what gets recorded.
struct CameraPreview: NSViewRepresentable {
    let camera: CameraService
    var mirrored: Bool

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView(camera: camera)
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.mirrored = mirrored
    }

    static func dismantleNSView(_ nsView: CameraPreviewNSView, coordinator: ()) {
        nsView.detach()
    }
}

final class CameraPreviewNSView: NSView {
    private let displayLayer = CALayer()
    private weak var camera: CameraService?
    private var sinkID: UUID?
    private let pendingLock = NSLock()
    private var framePending = false
    private var currentBuffer: CVPixelBuffer?

    var mirrored = false {
        didSet { if oldValue != mirrored { needsLayout = true } }
    }

    init(camera: CameraService) {
        self.camera = camera
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.contentsGravity = .resizeAspectFill
        displayLayer.masksToBounds = true
        layer?.addSublayer(displayLayer)
        sinkID = camera.addSink { [weak self] buffer in self?.enqueue(buffer) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let sinkID { camera?.removeSink(sinkID) }
    }

    func detach() {
        if let sinkID { camera?.removeSink(sinkID) }
        sinkID = nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        displayLayer.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        CATransaction.commit()
    }

    /// Called on the camera queue; coalesces frames so the main thread never falls behind.
    private func enqueue(_ buffer: CVPixelBuffer) {
        pendingLock.lock()
        if framePending { pendingLock.unlock(); return }
        framePending = true
        pendingLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.currentBuffer = buffer
            self.displayLayer.contents = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
            CATransaction.commit()
            self.pendingLock.lock()
            self.framePending = false
            self.pendingLock.unlock()
        }
    }
}
