import AppKit
import Observation
import ScreenCaptureKit

struct DisplaySource: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let pointSize: CGSize
    let display: SCDisplay

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.pointSize == rhs.pointSize }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct WindowSource: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let appName: String
    let bundleID: String?
    let frame: CGRect
    let window: SCWindow

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.title == rhs.title }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum SourceKind: String, CaseIterable, Identifiable {
    case display
    case window
    var id: String { rawValue }
    var title: String { self == .display ? "Full Screen" : "Window" }
    var systemImage: String { self == .display ? "display" : "macwindow" }
}

/// Everything the recorder needs about the chosen source, resolved right before recording.
struct ResolvedCaptureSource {
    let filter: SCContentFilter
    /// Native pixel size of the captured content.
    let contentPixelSize: CGSize
    /// Area of the screen (AppKit global coordinates) that the captured content occupies.
    /// The floating camera bubble is positioned relative to this region.
    let overlayRegion: CGRect
    let screen: NSScreen?
    let title: String
}

/// Lists displays and windows that can be recorded and resolves the current selection.
@MainActor
@Observable
final class ScreenSourceStore {
    private(set) var displays: [DisplaySource] = []
    private(set) var windows: [WindowSource] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var previewImage: CGImage?
    /// A content filter chosen in the system picker that couldn't be mapped back onto our lists.
    private(set) var pickedFilter: SCContentFilter?
    private(set) var pickedTitle: String?

    var kind: SourceKind = .display { didSet { if oldValue != kind { pickedFilter = nil; refreshPreview() } } }
    var selectedDisplayID: CGDirectDisplayID? { didSet { if oldValue != selectedDisplayID { pickedFilter = nil; refreshPreview() } } }
    var selectedWindowID: CGWindowID? { didSet { if oldValue != selectedWindowID { pickedFilter = nil; refreshPreview() } } }

    @ObservationIgnored private var content: SCShareableContent?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private lazy var pickerObserver = SharingPickerObserver { [weak self] filter in
        self?.applyPickedFilter(filter)
    }

    /// Aspect ratio (width / height) of the selected content, used to shape the preview stage.
    var selectedAspectRatio: CGFloat {
        if let pickedFilter {
            let rect = pickedFilter.contentRect
            return rect.height > 0 ? rect.width / rect.height : 16 / 9
        }
        switch kind {
        case .display:
            if let d = selectedDisplay, d.pointSize.height > 0 { return d.pointSize.width / d.pointSize.height }
        case .window:
            if let w = selectedWindow, w.frame.height > 0 { return w.frame.width / w.frame.height }
        }
        return 16 / 9
    }

    var selectedDisplay: DisplaySource? { displays.first { $0.id == selectedDisplayID } ?? displays.first }
    var selectedWindow: WindowSource? { windows.first { $0.id == selectedWindowID } }

    var selectionTitle: String {
        if let pickedTitle, pickedFilter != nil { return pickedTitle }
        switch kind {
        case .display: return selectedDisplay?.name ?? "No display"
        case .window: return selectedWindow.map { "\($0.appName) — \($0.title)" } ?? "Choose a window"
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            apply(content)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            Log.capture.error("Shareable content failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshPreview()
    }

    private func apply(_ content: SCShareableContent) {
        self.content = content
        let screensByID = Dictionary(NSScreen.screens.compactMap { screen in screen.displayID.map { ($0, screen) } },
                                     uniquingKeysWith: { first, _ in first })
        displays = content.displays.enumerated().map { index, display in
            let name = screensByID[display.displayID]?.localizedName ?? "Display \(index + 1)"
            return DisplaySource(id: display.displayID, name: name,
                                 pointSize: CGSize(width: display.width, height: display.height), display: display)
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        windows = content.windows
            .filter { window in
                guard window.isOnScreen, let app = window.owningApplication, app.processID != ownPID else { return false }
                return window.windowLayer == 0 && window.frame.width >= 120 && window.frame.height >= 80
                    && !(window.title ?? "").isEmpty
            }
            .map { window in
                WindowSource(id: window.windowID, title: window.title ?? "Untitled",
                             appName: window.owningApplication?.applicationName ?? "App",
                             bundleID: window.owningApplication?.bundleIdentifier,
                             frame: window.frame, window: window)
            }
            .sorted { ($0.appName, $0.title) < ($1.appName, $1.title) }

        if selectedDisplayID == nil || !displays.contains(where: { $0.id == selectedDisplayID }) {
            let mainID = NSScreen.main?.displayID
            selectedDisplayID = displays.first { $0.id == mainID }?.id ?? displays.first?.id
        }
    }

    // MARK: - Resolution

    /// Builds the content filter for the current selection from fresh shareable content.
    func resolveSelection() async throws -> ResolvedCaptureSource {
        if let pickedFilter {
            return Self.resolve(filter: pickedFilter, title: pickedTitle ?? "Shared content", screen: NSScreen.main)
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            Log.capture.error("Screen content unavailable when starting: \(error.localizedDescription, privacy: .public)")
            throw RecorderError.screenPermissionDenied
        }
        apply(content)
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }

        switch kind {
        case .display:
            guard let source = selectedDisplay else { throw RecorderError.noDisplayAvailable }
            // Glance's own windows (camera bubble, controls, countdown) are excluded so the bubble is only
            // ever drawn once: by the compositor.
            let filter = SCContentFilter(display: source.display, excludingApplications: ownApps, exceptingWindows: [])
            let screen = NSScreen.screens.first { $0.displayID == source.id }
            return Self.resolve(filter: filter, title: source.name, screen: screen)
        case .window:
            guard let id = selectedWindowID, let source = windows.first(where: { $0.id == id }) else {
                throw RecorderError.sourceUnavailable("The selected window was closed or is no longer on screen.")
            }
            let filter = SCContentFilter(desktopIndependentWindow: source.window)
            let region = Self.appKitRect(fromCGGlobal: source.frame)
            let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: region.midX, y: region.midY)) } ?? NSScreen.main
            return ResolvedCaptureSource(filter: filter,
                                         contentPixelSize: Self.pixelSize(of: filter),
                                         overlayRegion: region, screen: screen,
                                         title: "\(source.appName) — \(source.title)")
        }
    }

    private static func resolve(filter: SCContentFilter, title: String, screen: NSScreen?) -> ResolvedCaptureSource {
        let region: CGRect
        if filter.style == .window {
            region = appKitRect(fromCGGlobal: filter.contentRect)
        } else {
            region = screen?.frame ?? NSScreen.main?.frame ?? CGRect(origin: .zero, size: filter.contentRect.size)
        }
        return ResolvedCaptureSource(filter: filter, contentPixelSize: pixelSize(of: filter),
                                     overlayRegion: region, screen: screen, title: title)
    }

    static func pixelSize(of filter: SCContentFilter) -> CGSize {
        let scale = CGFloat(filter.pointPixelScale)
        return CGSize(width: (filter.contentRect.width * scale).rounded(), height: (filter.contentRect.height * scale).rounded())
    }

    /// Converts a rect in CoreGraphics global coordinates (top-left origin of the primary display)
    /// to AppKit global coordinates (bottom-left origin).
    static func appKitRect(fromCGGlobal rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - Preview thumbnail

    func refreshPreview() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            guard let self else { return }
            let image = await self.capturePreview()
            guard !Task.isCancelled else { return }
            self.previewImage = image
        }
    }

    private func capturePreview() async -> CGImage? {
        guard let content else { return nil }
        let filter: SCContentFilter
        if let pickedFilter {
            filter = pickedFilter
        } else {
            switch kind {
            case .display:
                guard let display = selectedDisplay else { return nil }
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                filter = SCContentFilter(display: display.display, excludingApplications: ownApps, exceptingWindows: [])
            case .window:
                guard let window = selectedWindow else { return nil }
                filter = SCContentFilter(desktopIndependentWindow: window.window)
            }
        }
        let config = SCStreamConfiguration()
        let pixel = Self.pixelSize(of: filter)
        let scale = min(1, 1280 / max(pixel.width, 1))
        config.width = max(2, Int(pixel.width * scale))
        config.height = max(2, Int(pixel.height * scale))
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: - System content-sharing picker

    func presentSystemPicker() {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow]
        if let bundleID = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [bundleID] }
        picker.defaultConfiguration = configuration
        picker.add(pickerObserver)
        picker.isActive = true
        picker.present()
    }

    private func applyPickedFilter(_ filter: SCContentFilter) {
        SCContentSharingPicker.shared.isActive = false
        // On macOS 15.2+ the picked content can be mapped back to our own display/window selection, which
        // lets us apply the usual exclusion of Glance's windows.
        if #available(macOS 15.2, *) {
            if filter.style == .display, let display = filter.includedDisplays.first {
                kind = .display
                selectedDisplayID = display.displayID
                Task { await refresh() }
                return
            }
            if filter.style == .window, let window = filter.includedWindows.first {
                Task {
                    await refresh()
                    kind = .window
                    selectedWindowID = window.windowID
                }
                return
            }
        }
        pickedFilter = filter
        pickedTitle = filter.style == .window ? "Window picked in System Picker" : "Display picked in System Picker"
        refreshPreview()
    }
}

/// Bridges `SCContentSharingPickerObserver` callbacks (arbitrary threads) to the main actor.
private final class SharingPickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    private let onPick: @MainActor (SCContentFilter) -> Void

    init(onPick: @escaping @MainActor (SCContentFilter) -> Void) {
        self.onPick = onPick
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async { SCContentSharingPicker.shared.isActive = false }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        DispatchQueue.main.async { [onPick] in onPick(filter) }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Log.capture.error("System picker failed: \(error.localizedDescription, privacy: .public)")
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
