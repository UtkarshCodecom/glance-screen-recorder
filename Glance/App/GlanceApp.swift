import SwiftUI

@main
struct GlanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let app = AppModel.shared

    var body: some Scene {
        Window("Glance", id: WindowID.main) {
            MainView()
                .environment(app)
                .frame(minWidth: 1000, minHeight: 660)
        }
        .defaultSize(width: 1240, height: 800)
        .commands { RecordingCommands(app: app) }

        Settings {
            SettingsView().environment(app)
        }

        MenuBarExtra {
            MenuBarContent().environment(app)
        } label: {
            MenuBarLabel().environment(app)
        }
    }
}

struct RecordingCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandMenu("Recording") {
            Button(app.coordinator.phase.isCapturing ? "Stop and Save" : "Start Recording") {
                app.coordinator.toggleRecording()
            }
            .keyboardShortcut("r", modifiers: [.command, .option, .shift])
            Button(app.coordinator.phase == .paused ? "Resume" : "Pause") {
                app.coordinator.togglePause()
            }
            .keyboardShortcut("p", modifiers: [.command, .option, .shift])
            .disabled(!app.coordinator.phase.isCapturing)
            Divider()
            Button("Open Recordings Folder") { app.library.openFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("Record") { app.sidebarSelection = .record }.keyboardShortcut("1")
            Button("Library") { app.sidebarSelection = .library }.keyboardShortcut("2")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningUnitTests else { return }
        AppModel.shared.bootstrap()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Keep running in the menu bar.
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.shared.showMainWindow() }
        return true
    }

    /// Never lose a recording on quit: finish and save first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let coordinator = AppModel.shared.coordinator!
        switch coordinator.phase {
        case .idle:
            return .terminateNow
        case .countingDown:
            coordinator.cancelCountdown()
            return .terminateNow
        case .starting, .recording, .paused, .finishing:
            coordinator.toggleRecording()
            coordinator.whenIdle { sender.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
    }
}
