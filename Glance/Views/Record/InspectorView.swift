import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    SourceSection()
                    CameraSection()
                    AudioSection()
                    OutputSection()
                }
                .padding(14)
            }
            Divider()
            RecordButtonBar()
                .padding(14)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
    }
}

// MARK: - Source

private struct SourceSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var sources = app.sources
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Screen", systemImage: "rectangle.dashed") {
                    Button { Task { await sources.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh displays and windows")
                    .disabled(sources.isLoading)
                }
                Picker("Source", selection: $sources.kind) {
                    ForEach(SourceKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.systemImage).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch sources.kind {
                case .display:
                    if sources.displays.count > 1 {
                        Picker("Display", selection: $sources.selectedDisplayID) {
                            ForEach(sources.displays) { display in
                                Text("\(display.name) — \(Int(display.pointSize.width))×\(Int(display.pointSize.height))")
                                    .tag(Optional(display.id))
                            }
                        }
                        .labelsHidden()
                    } else if let display = sources.selectedDisplay {
                        Label("\(display.name) · \(Int(display.pointSize.width))×\(Int(display.pointSize.height))", systemImage: "display")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                case .window:
                    Picker("Window", selection: $sources.selectedWindowID) {
                        Text("Choose a window…").tag(CGWindowID?.none)
                        ForEach(sources.windows) { window in
                            Text("\(window.appName) — \(window.title)").lineLimit(1).tag(Optional(window.id))
                        }
                    }
                    .labelsHidden()
                }

                Button {
                    sources.presentSystemPicker()
                } label: {
                    Label("Choose with System Picker…", systemImage: "macwindow.on.rectangle")
                }
                .buttonStyle(.link)
                .font(.callout)

                if let error = sources.loadError, app.permissions.screen == .granted {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - Camera

private struct CameraSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let layout = app.settings.cameraLayout
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Camera", systemImage: "video.fill") {
                    Toggle("Camera", isOn: settingBinding(\.cameraEnabled))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                if app.settings.cameraEnabled {
                    Picker("Camera", selection: settingBinding(\.selectedCameraID)) {
                        Text("Default camera").tag(String?.none)
                        ForEach(app.devices.cameras) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()

                    Picker("Shape", selection: layoutBinding(\.shape)) {
                        ForEach(CameraShape.allCases) { shape in
                            Image(systemName: shape.systemImage).help(shape.title).tag(shape)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.secondary)
                        Slider(value: layoutBinding(\.sizeFraction), in: CameraOverlayLayout.sizeRange)
                        Image(systemName: "circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .help("Bubble size")

                    Toggle("Mirror camera", isOn: layoutBinding(\.mirrored))
                        .font(.callout)
                    if let error = app.cameraError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if layout.sizeFraction > 0.5 {
                        Text("Large bubbles cover a lot of your screen.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: app.settings.cameraEnabled) { app.updateDevices() }
        .onChange(of: app.settings.selectedCameraID) { app.updateDevices() }
    }

    private func settingBinding<T>(_ keyPath: WritableKeyPath<RecordingSettings, T>) -> Binding<T> {
        Binding(get: { app.settings[keyPath: keyPath] }, set: { app.settings[keyPath: keyPath] = $0 })
    }

    private func layoutBinding<T>(_ keyPath: WritableKeyPath<CameraOverlayLayout, T>) -> Binding<T> {
        Binding(get: { app.settings.cameraLayout[keyPath: keyPath] },
                set: { value in app.coordinator.updateCameraLayout { $0[keyPath: keyPath] = value } })
    }
}

// MARK: - Audio

private struct AudioSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Audio", systemImage: "waveform")

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: binding(\.capturesMicrophone)) {
                        Label("Microphone", systemImage: "mic.fill").font(.callout.weight(.medium))
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    if app.settings.capturesMicrophone {
                        Picker("Microphone", selection: binding(\.selectedMicrophoneID)) {
                            Text("Default microphone").tag(String?.none)
                            ForEach(app.devices.microphones) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .labelsHidden()
                        LevelMeter(level: app.previewMicrophoneLevel)
                        volumeSlider(binding(\.microphoneVolume))
                        if let error = app.microphoneError {
                            Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: binding(\.capturesSystemAudio)) {
                        Label("System audio", systemImage: "speaker.wave.2.fill").font(.callout.weight(.medium))
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    if app.settings.capturesSystemAudio {
                        volumeSlider(binding(\.systemAudioVolume))
                        Text("Sound from apps is mixed with your voice into a single track.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: app.settings.capturesMicrophone) { app.updateDevices() }
        .onChange(of: app.settings.selectedMicrophoneID) { app.updateDevices() }
    }

    private func volumeSlider(_ value: Binding<Float>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: 0...1.5)
            Text("\(Int(value.wrappedValue * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .help("Volume in the final mix")
    }

    private func binding<T>(_ keyPath: WritableKeyPath<RecordingSettings, T>) -> Binding<T> {
        Binding(get: { app.settings[keyPath: keyPath] }, set: { app.settings[keyPath: keyPath] = $0 })
    }
}

// MARK: - Output

private struct OutputSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Output", systemImage: "slider.horizontal.3")
                FieldRow(label: "Quality") {
                    Picker("Quality", selection: binding(\.quality)) {
                        ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                FieldRow(label: "Frame rate") {
                    Picker("Frame rate", selection: binding(\.frameRate)) {
                        ForEach(FrameRate.allCases) { Text("\($0.rawValue)").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                FieldRow(label: "Countdown") {
                    Picker("Countdown", selection: binding(\.countdownSeconds)) {
                        ForEach(RecordingSettings.countdownChoices, id: \.self) { seconds in
                            Text(seconds == 0 ? "Off" : "\(seconds)s").tag(seconds)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Text(app.settings.quality.detail + " · MP4 · " + (app.settings.codec == .h264 ? "H.264" : "HEVC"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<RecordingSettings, T>) -> Binding<T> {
        Binding(get: { app.settings[keyPath: keyPath] }, set: { app.settings[keyPath: keyPath] = $0 })
    }
}

// MARK: - Record button

private struct RecordButtonBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let coordinator = app.coordinator!
        VStack(spacing: 8) {
            switch coordinator.phase {
            case .idle:
                Button { coordinator.startRecording() } label: {
                    Label("Start Recording", systemImage: "record.circle")
                }
                .buttonStyle(PrimaryRecordButtonStyle())
                .keyboardShortcut(.return, modifiers: [.command])
            case .countingDown, .starting:
                Button { coordinator.toggleRecording() } label: {
                    Label(coordinator.phase.statusText, systemImage: "xmark.circle")
                }
                .buttonStyle(PrimaryRecordButtonStyle(tint: .gray))
            case .recording, .paused:
                HStack(spacing: 8) {
                    Button { coordinator.togglePause() } label: {
                        Label(coordinator.phase == .paused ? "Resume" : "Pause",
                              systemImage: coordinator.phase == .paused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(PrimaryRecordButtonStyle(tint: .indigo))
                    Button { coordinator.stopRecording() } label: {
                        Label("Stop · \(coordinator.elapsed.clockString)", systemImage: "stop.fill")
                    }
                    .buttonStyle(PrimaryRecordButtonStyle())
                }
            case .finishing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Saving your recording…").font(.callout)
                }
                .frame(maxWidth: .infinity, minHeight: 40)
            }
            Text("\(GlobalHotKeys.toggleDescription) start/stop · \(GlobalHotKeys.pauseDescription) pause — work from any app")
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
