import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
    var settings: RecordingSettings {
        didSet { if settings != oldValue { persist() } }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "GlanceRecordingSettings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(RecordingSettings.self, from: data) {
            settings = decoded
        } else {
            settings = RecordingSettings()
        }
    }

    var outputDirectory: URL {
        settings.outputDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultOutputDirectory
    }

    static var defaultOutputDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("Glance", isDirectory: true)
    }

    /// Where in-progress intermediate files live; leftovers here are recoverable after a crash.
    static var inProgressDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Glance/InProgress", isDirectory: true)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
