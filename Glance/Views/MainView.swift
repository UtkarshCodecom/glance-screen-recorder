import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        @Bindable var coordinator = app.coordinator
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 260)
        } detail: {
            Group {
                switch app.sidebarSelection ?? .record {
                case .record: RecordView()
                case .library: LibraryView()
                }
            }
            .overlay(alignment: .bottom) { SavedToast() }
        }
        .alert(item: $coordinator.presentedError) { error in
            if let permission = error.permission {
                return Alert(title: Text(error.title), message: Text(error.message),
                             primaryButton: .default(Text("Open System Settings")) { app.permissions.openSystemSettings(for: permission) },
                             secondaryButton: .cancel(Text("OK")))
            }
            return Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
        .background(WindowAccessor { window in app.mainWindow = window })
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.sidebarSelection) {
            Section {
                Label("Record", systemImage: "record.circle").tag(SidebarItem.record)
                Label {
                    HStack {
                        Text("Library")
                        Spacer()
                        if !app.library.items.isEmpty {
                            Text("\(app.library.items.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                } icon: {
                    Image(systemName: "film.stack")
                }
                .tag(SidebarItem.library)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Glance").font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Screen + camera recorder").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom) {
            SidebarStatus().padding(12)
        }
    }
}

private struct SidebarStatus: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let coordinator = app.coordinator!
        VStack(alignment: .leading, spacing: 6) {
            if coordinator.phase.isBusy {
                HStack(spacing: 6) {
                    Circle().fill(coordinator.phase == .recording ? Theme.record : .secondary).frame(width: 7, height: 7)
                    Text(coordinator.phase.statusText).font(.caption.weight(.semibold))
                    Spacer()
                    if coordinator.phase.isCapturing {
                        Text(coordinator.elapsed.clockString).font(.caption.monospacedDigit())
                    }
                }
            }
            Button {
                app.library.openFolder()
            } label: {
                Label(app.settingsStore.outputDirectory.lastPathComponent, systemImage: "folder")
                    .font(.caption).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open \(app.settingsStore.outputDirectory.path)")
        }
    }
}

/// "Recording saved" confirmation with quick actions.
private struct SavedToast: View {
    @Environment(AppModel.self) private var app
    @State private var playing: RecordingItem?

    var body: some View {
        let coordinator = app.coordinator!
        if let saved = coordinator.lastSaved {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Recording saved").font(.headline)
                    Text("\(saved.name) · \(saved.duration.clockString)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                Button("Play") {
                    playing = app.library.items.first { $0.url == saved.url }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved.url]) }
                Button {
                    coordinator.dismissSavedBanner()
                } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
            }
            .padding(14)
            .frame(maxWidth: 620)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
            .padding(20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .sheet(item: $playing) { item in PlayerSheet(item: item) }
            .task(id: saved.url) {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if playing == nil, coordinator.lastSaved == saved { withAnimation { coordinator.dismissSavedBanner() } }
            }
        }
    }
}

/// Captures the hosting NSWindow so the app can hide/show it around recordings.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let window = nsView.window { onWindow(window) } }
    }
}
