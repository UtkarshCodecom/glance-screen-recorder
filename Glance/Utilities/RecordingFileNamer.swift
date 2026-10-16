import Foundation

enum RecordingFileNamer {
    static let fileExtension = "mp4"

    static func baseName(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "Glance Recording %04d-%02d-%02d at %02d.%02d.%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// A URL in `directory` that doesn't collide with an existing file: "Name.mp4", "Name 2.mp4", …
    static func uniqueURL(in directory: URL, baseName: String, fileExtension: String = fileExtension,
                          exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var index = 2
        while exists(candidate) {
            candidate = directory.appendingPathComponent("\(baseName) \(index)").appendingPathExtension(fileExtension)
            index += 1
        }
        return candidate
    }

    enum NameValidation: Equatable {
        case valid(String)
        case empty
        case invalidCharacters
        case tooLong
    }

    /// Validates a user-entered recording name (without extension).
    static func validate(_ proposed: String) -> NameValidation {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if trimmed.contains("/") || trimmed.contains(":") || trimmed.hasPrefix(".") { return .invalidCharacters }
        guard trimmed.utf8.count <= 200 else { return .tooLong }
        return .valid(trimmed)
    }
}
