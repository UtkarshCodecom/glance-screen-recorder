import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class CountdownModel {
    var remaining = 3
}

/// Manages Glance's floating windows during a recording: control bar, camera bubble and countdown.
/// All of them belong to Glance, which is excluded from display capture, so none of them appear in
/// the video; the bubble is drawn into the video by the compositor instead.
@MainActor
final class OverlayController {
    static let bubblePadding: CGFloat = 22

    private unowned let app: AppModel
    private var controlPanel: NSPanel?
    private var bubblePanel: NSPanel?
    private var countdownPanel: NSPanel?
    private let countdownModel = CountdownModel()
    private var bubbleRegion: CGRect = .zero
    private var bubbleMoveObserver: NSObjectProtocol?
    private var isApplyingBubbleFrame = false
    private var escapeMonitor: Any?

    init(app: AppModel) {
        self.app = app
    }

    // MARK: - Control bar

    func showControlBar(on screen: NSScreen?) {
        let panel = controlPanel ?? makePanel(content: ControlBarView().environment(app), level: .statusBar)
        controlPanel = panel
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 420, height: 72))
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 28))
        panel.orderFrontRegardless()
    }

    // MARK: - Camera bubble

    func showBubble(region: CGRect, layout: CameraOverlayLayout) {
        bubbleRegion = region
        let panel = bubblePanel ?? makePanel(content: CameraBubbleView().environment(app), level: .floating)
        if bubblePanel == nil {
            bubblePanel = panel
            bubbleMoveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.bubbleDidMove() }
            }
        }
        applyBubbleFrame(for: layout)
        panel.orderFrontRegardless()
    }

    func layoutBubble(_ layout: CameraOverlayLayout) {
        guard bubblePanel != nil else { return }
        applyBubbleFrame(for: layout)
    }

    func setBubbleHidden(_ hidden: Bool) {
        guard let bubblePanel else { return }
        if hidden { bubblePanel.orderOut(nil) } else { bubblePanel.orderFrontRegardless() }
    }

    /// Called after a drag of the bubble finishes: snaps it fully inside the recorded area.
    func bubbleDragEnded() {
        applyBubbleFrame(for: app.settings.cameraLayout)
    }

    func screenParametersChanged() {
        guard bubblePanel != nil else { return }
        applyBubbleFrame(for: app.settings.cameraLayout)
    }

    private func applyBubbleFrame(for layout: CameraOverlayLayout) {
        guard let panel = bubblePanel, bubbleRegion.width > 0 else { return }
        let rect = layout.rect(in: bubbleRegion.size) // top-left origin within the region
        let frame = CGRect(x: bubbleRegion.minX + rect.minX, y: bubbleRegion.maxY - rect.maxY,
                           width: rect.width, height: rect.height)
            .insetBy(dx: -Self.bubblePadding, dy: -Self.bubblePadding)
        isApplyingBubbleFrame = true
        panel.setFrame(frame, display: true, animate: false)
        isApplyingBubbleFrame = false
    }

    private func bubbleDidMove() {
        guard !isApplyingBubbleFrame, let panel = bubblePanel, bubbleRegion.width > 0 else { return }
        let bubble = panel.frame.insetBy(dx: Self.bubblePadding, dy: Self.bubblePadding)
        let topLeft = CGRect(x: bubble.minX - bubbleRegion.minX, y: bubbleRegion.maxY - bubble.maxY,
                             width: bubble.width, height: bubble.height)
        app.coordinator.updateCameraLayout(fromBubble: true) { layout in
            layout.setCenter(fromRect: topLeft, in: bubbleRegion.size)
            // Store the clamped position so the composited bubble never leaves the frame.
            let clamped = layout.rect(in: bubbleRegion.size)
            layout.setCenter(fromRect: clamped, in: bubbleRegion.size)
        }
    }

    // MARK: - Countdown

    func showCountdown(remaining: Int, on screen: NSScreen?) {
        countdownModel.remaining = remaining
        if countdownPanel == nil {
            let panel = makePanel(content: CountdownView(model: countdownModel).environment(app), level: .statusBar)
            panel.setContentSize(NSSize(width: 300, height: 300))
            let frame = (screen ?? NSScreen.main)?.frame ?? .zero
            panel.setFrameOrigin(NSPoint(x: frame.midX - 150, y: frame.midY - 150))
            countdownPanel = panel
            panel.orderFrontRegardless()
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event } // Esc
                MainActor.assumeIsolated { self?.app.coordinator.cancelCountdown() }
                return nil
            }
        }
    }

    func hideCountdown() {
        countdownPanel?.orderOut(nil)
        countdownPanel = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    func hideAll() {
        hideCountdown()
        controlPanel?.orderOut(nil)
        controlPanel = nil
        if let bubbleMoveObserver { NotificationCenter.default.removeObserver(bubbleMoveObserver) }
        bubbleMoveObserver = nil
        bubblePanel?.orderOut(nil)
        bubblePanel = nil
    }

    // MARK: - Panel factory

    private func makePanel<Content: View>(content: Content, level: NSWindow.Level) -> NSPanel {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        let hosting = FirstMouseHostingView(rootView: content)
        hosting.sizingOptions = [.minSize, .intrinsicContentSize]
        panel.contentView = hosting
        return panel
    }
}

/// Borderless panel that can still become key (for buttons and Esc) without activating Glance.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on an inactive overlay hit the button underneath.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Drag area that moves its window using the system's native window drag.
struct WindowDragArea: NSViewRepresentable {
    var onDragEnded: (() -> Void)?

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: DragView, context: Context) {
        nsView.onDragEnded = onDragEnded
    }

    final class DragView: NSView {
        var onDragEnded: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
            onDragEnded?()
        }
    }
}
