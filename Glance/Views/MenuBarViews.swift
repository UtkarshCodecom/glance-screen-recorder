import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let coordinator = app.coordinator!
        switch coordinator.phase {
        case .idle:
            Button("Start Recording") { coordinator.startRecording() }
        case .countingDown:
            Button("Cancel Countdown") { coordinator.cancelCountdown() }
        case .starting:
            Text("Starting…")
        case .recording, .paused:
            Text("\(coordinator.phase.statusText) — \(coordinator.elapsed.clockString)")
            Button(coordinator.phase == .paused ? "Resume" : "Pause") { coordinator.togglePause() }
            Button("Stop and Save") { coordinator.stopRecording() }
            if coordinator.isCameraActiveInRecording {
                Toggle("Show Camera Preview", isOn: Binding(get: { !coordinator.isCameraPreviewHidden },
                                                           set: { coordinator.isCameraPreviewHidden = !$0 }))
            }
        case .finishing:
            Text("Saving…")
        }
        Divider()
        Button("Open Glance") { app.showMainWindow() }
        Button("Open Recordings Folder") { app.library.openFolder() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Glance") { NSApp.terminate(nil) }
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let coordinator = app.coordinator!
        Group {
            switch coordinator.phase {
            case .recording:
                Text("\(Image(systemName: "record.circle.fill")) \(coordinator.elapsed.clockString)")
            case .paused:
                Text("\(Image(systemName: "pause.circle.fill")) \(coordinator.elapsed.clockString)")
            case .countingDown(let remaining):
                Text("\(Image(systemName: "timer")) \(remaining)")
            default:
                Image(systemName: "record.circle")
            }
        }
        .onAppear {
            app.openMainWindowAction = { openWindow(id: WindowID.main) }
        }
    }
}
