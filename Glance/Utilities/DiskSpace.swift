import Foundation

enum DiskSpace {
    /// Refuse to start below this much free space.
    static let minimumToStart: Int64 = 1_000_000_000
    /// Stop an in-progress recording below this much free space so it can still be finalized.
    static let minimumWhileRecording: Int64 = 400_000_000

    static func availableBytes(at url: URL) -> Int64? {
        var probe = url
        // Walk up until we hit something that exists (the output folder may not be created yet).
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    static func hasRoomToStart(availableBytes: Int64?) -> Bool {
        guard let availableBytes else { return true } // Unknown: don't block, keep monitoring.
        return availableBytes >= minimumToStart
    }

    static func shouldStopRecording(availableBytes: Int64?) -> Bool {
        guard let availableBytes else { return false }
        return availableBytes < minimumWhileRecording
    }
}
