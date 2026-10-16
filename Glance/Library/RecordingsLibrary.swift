import AppKit
import AVFoundation
import Observation

struct RecordingItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let createdAt: Date
    let fileSize: Int64

    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Lists recordings in the output folder, loads durations and thumbnails, and performs file actions.
@MainActor
@Observable
final class RecordingsLibrary {
    private(set) var items: [RecordingItem] = []
    private(set) var durations: [URL: TimeInterval] = [:]
    private(set) var thumbnails: [URL: NSImage] = [:]
    /// Intermediate files left behind by a crash or forced quit.
    private(set) var unfinished: [URL] = []
    private(set) var isRecovering = false
    var highlightedURL: URL?

    @ObservationIgnored private(set) var directory: URL
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var thumbnailRequests: Set<URL> = []
    /// Intermediate currently being written; never offered for recovery.
    @ObservationIgnored var activeIntermediate: URL?

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    init(directory: URL) {
        self.directory = directory
    }

    func setDirectory(_ url: URL) {
        guard url.standardizedFileURL != directory.standardizedFileURL else { return }
        directory = url
        thumbnails = [:]
        durations = [:]
        startWatching()
        refresh()
    }

    func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func refresh() {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        items = urls.compactMap { url in
            guard Self.videoExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return RecordingItem(url: url, createdAt: values.creationDate ?? .distantPast, fileSize: Int64(values.fileSize ?? 0))
        }
        .sorted { $0.createdAt > $1.createdAt }

        let present = Set(items.map(\.url))
        thumbnails = thumbnails.filter { present.contains($0.key) }
        durations = durations.filter { present.contains($0.key) }
        for item in items where durations[item.url] == nil { loadDuration(for: item.url) }
        refreshUnfinished()
        if watcher == nil { startWatching() }
    }

    private func loadDuration(for url: URL) {
        Task {
            let duration = try? await AVURLAsset(url: url).load(.duration)
            if let seconds = duration?.seconds, seconds.isFinite { durations[url] = seconds }
        }
    }

    func requestThumbnail(for item: RecordingItem) {
        guard thumbnails[item.url] == nil, !thumbnailRequests.contains(item.url) else { return }
        thumbnailRequests.insert(item.url)
        let url = item.url
        Task {
            let image = await Self.makeThumbnail(url: url)
            thumbnailRequests.remove(url)
            if let image { thumbnails[url] = image }
        }
    }

    nonisolated private static func makeThumbnail(url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: CMTime(seconds: 0.6, preferredTimescale: 600)).image else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: - File actions

    @discardableResult
    func rename(_ item: RecordingItem, to proposedName: String) throws -> URL {
        let name: String
        switch RecordingFileNamer.validate(proposedName) {
        case .valid(let valid): name = valid
        case .empty: throw LibraryError.invalidName("The name can't be empty.")
        case .invalidCharacters: throw LibraryError.invalidName("Names can't contain “/” or “:” or start with a period.")
        case .tooLong: throw LibraryError.invalidName("That name is too long.")
        }
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(item.url.pathExtension)
        guard destination != item.url else { return item.url }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LibraryError.invalidName("A recording named “\(name)” already exists.")
        }
        try FileManager.default.moveItem(at: item.url, to: destination)
        if let thumbnail = thumbnails.removeValue(forKey: item.url) { thumbnails[destination] = thumbnail }
        if let duration = durations.removeValue(forKey: item.url) { durations[destination] = duration }
        refresh()
        return destination
    }

    /// Moves the recording to the Trash (recoverable from Finder).
    func moveToTrash(_ item: RecordingItem) throws {
        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        refresh()
    }

    func reveal(_ item: RecordingItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func openFolder() {
        try? ensureDirectoryExists()
        NSWorkspace.shared.open(directory)
    }

    // MARK: - Crash recovery

    func refreshUnfinished() {
        let dir = SettingsStore.inProgressDirectory
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        unfinished = urls.filter { $0.pathExtension == "mov" && $0.standardizedFileURL != activeIntermediate?.standardizedFileURL }
    }

    func recoverUnfinished(options: FinalizeOptions) async -> [Error] {
        isRecovering = true
        defer { isRecovering = false; refreshUnfinished(); refresh() }
        var errors: [Error] = []
        try? ensureDirectoryExists()
        for url in unfinished {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let destination = RecordingFileNamer.uniqueURL(in: directory, baseName: RecordingFileNamer.baseName(for: created) + " (Recovered)")
            do {
                _ = try await RecordingFinalizer.finalize(intermediate: url, audioRoles: nil, destination: destination, options: options)
                try? FileManager.default.removeItem(at: url)
            } catch {
                errors.append(error)
            }
        }
        return errors
    }

    func discardUnfinished() {
        for url in unfinished { try? FileManager.default.removeItem(at: url) }
        refreshUnfinished()
    }

    // MARK: - Folder watching

    private func startWatching() {
        watcher?.cancel()
        watcher = nil
        try? ensureDirectoryExists()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }
}

enum LibraryError: LocalizedError {
    case invalidName(String)

    var errorDescription: String? {
        switch self {
        case .invalidName(let message): return message
        }
    }
}
