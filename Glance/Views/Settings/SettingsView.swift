import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            VideoSettings().tabItem { Label("Video", systemImage: "film") }
            AudioSettings().tabItem { Label("Audio", systemImage: "waveform") }
            CameraSettings().tabItem { Label("Camera", systemImage: "video") }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private extension View {
    func settingsForm() -> some View {
        formStyle(.grouped).frame(minHeight: 300)
    }
}

/// Binding helper into the persisted settings.
@MainActor
private struct SettingsBinding {
    let app: AppModel
    func callAsFunction<T>(_ keyPath: WritableKeyPath<RecordingSettings, T>) -> Binding<T> {
        Binding(get: { app.settings[keyPath: keyPath] }, set: { app.settings[keyPath: keyPath] = $0 })
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let bind = SettingsBinding(app: app)
        Form {
            Section("Recordings folder") {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.secondary)
                    Text(app.settingsStore.outputDirectory.path)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                }
                HStack {
                    if let available = DiskSpace.availableBytes(at: app.settingsStore.outputDirectory) {
                        Text("\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) available")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if app.settings.outputDirectoryPath != nil {
                        Button("Use Default") { app.setOutputDirectory(SettingsStore.defaultOutputDirectory) }
                            .buttonStyle(.link)
                    }
                }
            }
            Section("Recording") {
                Picker("Countdown", selection: bind(\.countdownSeconds)) {
                    ForEach(RecordingSettings.countdownChoices, id: \.self) { Text($0 == 0 ? "Off" : "\($0) seconds").tag($0) }
                }
                Toggle("Hide Glance's window while recording", isOn: bind(\.hidesMainWindowWhileRecording))
                Toggle("Show mouse pointer", isOn: bind(\.showsCursor))
            }
            Section("Permissions") {
                ForEach(PermissionKind.allCases) { kind in
                    HStack {
                        Label(kind.title, systemImage: kind.systemImage)
                        Spacer()
                        let state = app.permissions.state(for: kind)
                        Text(state == .granted ? "Allowed" : state == .denied ? "Not allowed" : "Not requested")
                            .foregroundStyle(state == .granted ? .green : .secondary)
                        Button("Open…") { app.permissions.openSystemSettings(for: kind) }
                    }
                }
            }
        }
        .settingsForm()
        .onAppear { app.permissions.refresh() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.directoryURL = app.settingsStore.outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            app.setOutputDirectory(url)
        }
    }
}

private struct VideoSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let bind = SettingsBinding(app: app)
        Form {
            Section {
                Picker("Resolution", selection: bind(\.quality)) {
                    ForEach(VideoQuality.allCases) { quality in
                        Text("\(quality.title) — \(quality.detail)").tag(quality)
                    }
                }
                Picker("Frame rate", selection: bind(\.frameRate)) {
                    ForEach(FrameRate.allCases) { Text($0.title).tag($0) }
                }
                Picker("Codec", selection: bind(\.codec)) {
                    ForEach(VideoCodecChoice.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Recordings are saved as MP4. The resolution is a maximum: smaller windows are recorded at their own size. Native resolution is capped at 4096 pixels on the long edge.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsForm()
    }
}

private struct AudioSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let bind = SettingsBinding(app: app)
        Form {
            Section("Sources") {
                Toggle("Record microphone", isOn: bind(\.capturesMicrophone))
                Toggle("Record system audio", isOn: bind(\.capturesSystemAudio))
            }
            Section {
                LabeledContent("Microphone volume") {
                    Slider(value: bind(\.microphoneVolume), in: 0...1.5) { EmptyView() }
                        .frame(width: 220)
                }
                LabeledContent("System audio volume") {
                    Slider(value: bind(\.systemAudioVolume), in: 0...1.5) { EmptyView() }
                        .frame(width: 220)
                }
                Toggle("Also keep separate microphone and system tracks", isOn: bind(\.keepsSeparateAudioTracks))
            } header: {
                Text("Mix")
            } footer: {
                Text("Microphone and system audio are always mixed into one track every player understands. Separate tracks are added as extra, disabled tracks for editing apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsForm()
    }
}

private struct CameraSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Bubble") {
                Picker("Shape", selection: layout(\.shape)) {
                    ForEach(CameraShape.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                LabeledContent("Size") {
                    Slider(value: layout(\.sizeFraction), in: CameraOverlayLayout.sizeRange) { EmptyView() }.frame(width: 220)
                }
                Picker("Position", selection: cornerBinding) {
                    Text("Custom").tag(CameraOverlayLayout.Corner?.none)
                    ForEach(CameraOverlayLayout.Corner.allCases) { Text($0.title).tag(Optional($0)) }
                }
                Toggle("Mirror camera", isOn: layout(\.mirrored))
            }
            Section("Style") {
                ColorPicker("Border color", selection: borderColor, supportsOpacity: true)
                LabeledContent("Border width") {
                    Slider(value: layout(\.borderWidthFraction), in: 0...0.08) { EmptyView() }.frame(width: 220)
                }
                Toggle("Drop shadow", isOn: layout(\.showsShadow))
            }
        }
        .settingsForm()
    }

    private func layout<T>(_ keyPath: WritableKeyPath<CameraOverlayLayout, T>) -> Binding<T> {
        Binding(get: { app.settings.cameraLayout[keyPath: keyPath] },
                set: { value in app.coordinator.updateCameraLayout { $0[keyPath: keyPath] = value } })
    }

    private var cornerBinding: Binding<CameraOverlayLayout.Corner?> {
        let reference = CGSize(width: 1920, height: 1080)
        return Binding(get: {
            CameraOverlayLayout.Corner.allCases.first { corner in
                var probe = app.settings.cameraLayout
                probe.move(to: corner, in: reference)
                return probe.rect(in: reference) == app.settings.cameraLayout.rect(in: reference)
            }
        }, set: { corner in
            guard let corner else { return }
            app.coordinator.updateCameraLayout { $0.move(to: corner, in: reference) }
        })
    }

    private var borderColor: Binding<Color> {
        Binding(get: {
            let c = app.settings.cameraLayout.borderColor
            return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
        }, set: { color in
            guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
            let rgba = RGBAColor(red: Double(ns.redComponent), green: Double(ns.greenComponent),
                                 blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent))
            app.coordinator.updateCameraLayout { $0.borderColor = rgba }
        })
    }
}

private struct ShortcutSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Start / stop recording", value: GlobalHotKeys.toggleDescription)
                LabeledContent("Pause / resume", value: GlobalHotKeys.pauseDescription)
                LabeledContent("Cancel countdown", value: "Esc")
                LabeledContent("Start recording (in Glance)", value: "⌘↩")
            } footer: {
                Text("Start/stop and pause work from any app, including while Glance's window is hidden. The menu bar icon also controls recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsForm()
    }
}
