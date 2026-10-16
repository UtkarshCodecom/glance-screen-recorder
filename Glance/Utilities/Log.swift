import OSLog

enum Log {
    static let capture = Logger(subsystem: "dev.utkarsh.Glance", category: "capture")
    static let media = Logger(subsystem: "dev.utkarsh.Glance", category: "media")
    static let recording = Logger(subsystem: "dev.utkarsh.Glance", category: "recording")
    static let devices = Logger(subsystem: "dev.utkarsh.Glance", category: "devices")
    static let library = Logger(subsystem: "dev.utkarsh.Glance", category: "library")
}

var isRunningUnitTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
