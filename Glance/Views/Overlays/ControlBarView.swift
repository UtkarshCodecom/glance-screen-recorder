import SwiftUI

/// Compact floating recording controls.
struct ControlBarView: View {
    @Environment(AppModel.self) private var app
    @State private var pulse = false

    var body: some View {
        let coordinator = app.coordinator!
        HStack(spacing: 10) {
            WindowDragArea()
                .frame(width: 14, height: 28)
                .overlay(Image(systemName: "line.3.horizontal").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary).rotationEffect(.degrees(90)).allowsHitTesting(false))
                .help("Drag to move")

            status(coordinator)

            switch coordinator.phase {
            case .countingDown:
                Button { coordinator.cancelCountdown() } label: { Image(systemName: "xmark") }
                    .buttonStyle(OverlayIconButtonStyle())
                    .help("Cancel (Esc)")
            case .recording, .paused:
                divider
                Button { coordinator.togglePause() } label: {
                    Image(systemName: coordinator.phase == .paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(OverlayIconButtonStyle())
                .help(coordinator.phase == .paused ? "Resume (\(GlobalHotKeys.pauseDescription))" : "Pause (\(GlobalHotKeys.pauseDescription))")

                Button { coordinator.stopRecording() } label: {
                    RoundedRectangle(cornerRadius: 3).frame(width: 11, height: 11)
                }
                .buttonStyle(OverlayIconButtonStyle(tint: Theme.record, filled: true))
                .help("Stop and save (\(GlobalHotKeys.toggleDescription))")

                if coordinator.isCameraActiveInRecording {
                    divider
                    cameraControls(coordinator)
                }
                if app.settings.capturesMicrophone {
                    LevelMeter(level: coordinator.microphoneLevel, segments: 8, height: 14)
                        .frame(width: 44)
                        .help("Microphone level")
                }
            case .starting, .finishing:
                ProgressView().controlSize(.small)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Capsule(style: .continuous).fill(.regularMaterial))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .padding(16)
        .fixedSize()
    }

    @ViewBuilder
    private func status(_ coordinator: RecordingCoordinator) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(coordinator.phase == .recording ? Theme.record : Color.secondary)
                .frame(width: 9, height: 9)
                .opacity(coordinator.phase == .recording && pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            VStack(alignment: .leading, spacing: 0) {
                Text(timerText(coordinator))
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                if let warning = coordinator.warning {
                    Text(warning).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
                } else {
                    Text(coordinator.phase.statusText).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 64, alignment: .leading)
        }
    }

    @ViewBuilder
    private func cameraControls(_ coordinator: RecordingCoordinator) -> some View {
        Button { coordinator.isCameraInRecording.toggle() } label: {
            Image(systemName: coordinator.isCameraInRecording ? "video.fill" : "video.slash.fill")
        }
        .buttonStyle(OverlayIconButtonStyle(tint: coordinator.isCameraInRecording ? .primary : .orange))
        .help(coordinator.isCameraInRecording ? "Remove camera from the recording" : "Show camera in the recording")

        Button { coordinator.isCameraPreviewHidden.toggle() } label: {
            Image(systemName: coordinator.isCameraPreviewHidden ? "eye.slash" : "eye")
        }
        .buttonStyle(OverlayIconButtonStyle())
        .help(coordinator.isCameraPreviewHidden ? "Show camera preview" : "Hide camera preview (keeps recording it)")
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 22)
    }

    private func timerText(_ coordinator: RecordingCoordinator) -> String {
        switch coordinator.phase {
        case .countingDown(let remaining): return "Starting in \(remaining)"
        case .starting: return "Starting…"
        case .finishing: return "Saving…"
        default: return coordinator.elapsed.clockString
        }
    }
}
