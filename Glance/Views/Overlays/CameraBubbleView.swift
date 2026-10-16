import SwiftUI

/// The floating, draggable camera bubble shown on screen while recording.
struct CameraBubbleView: View {
    @Environment(AppModel.self) private var app
    @State private var isHovering = false

    var body: some View {
        let layout = app.settings.cameraLayout
        let coordinator = app.coordinator!
        GeometryReader { geometry in
            let size = geometry.size
            let radius = layout.shape.cornerRadius(for: size)
            let border = layout.borderWidth(for: size)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                WindowDragArea { app.coordinator.overlays.bubbleDragEnded() }
                CameraPreview(camera: app.camera, mirrored: layout.mirrored)
                    .clipShape(RoundedRectangle(cornerRadius: max(0, radius - border), style: .continuous))
                    .padding(border)
                    .allowsHitTesting(false)
                shape
                    .strokeBorder(Color(red: layout.borderColor.red, green: layout.borderColor.green,
                                        blue: layout.borderColor.blue, opacity: layout.borderColor.alpha), lineWidth: border)
                    .allowsHitTesting(false)
                if !coordinator.isCameraInRecording {
                    shape.fill(.black.opacity(0.45)).allowsHitTesting(false)
                    Label("Not recorded", systemImage: "video.slash.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .allowsHitTesting(false)
                }
                if isHovering {
                    VStack {
                        Spacer()
                        controls(coordinator)
                            .padding(.bottom, max(8, size.height * 0.08))
                    }
                    .transition(.opacity)
                }
            }
            .compositingGroup()
            .shadow(color: .black.opacity(layout.showsShadow ? 0.35 : 0), radius: 12, y: 5)
        }
        .padding(OverlayController.bubblePadding)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering } }
    }

    private func controls(_ coordinator: RecordingCoordinator) -> some View {
        HStack(spacing: 4) {
            Button { coordinator.updateCameraLayout { $0.resize(by: -CameraOverlayLayout.sizeStep) } } label: { Image(systemName: "minus") }
                .help("Smaller")
            Button { coordinator.updateCameraLayout { $0.resize(by: CameraOverlayLayout.sizeStep) } } label: { Image(systemName: "plus") }
                .help("Larger")
            Button { coordinator.updateCameraLayout { $0.shape = $0.shape.next } } label: { Image(systemName: "square.on.circle") }
                .help("Change shape")
            Button { coordinator.isCameraPreviewHidden = true } label: { Image(systemName: "eye.slash") }
                .help("Hide preview (camera keeps recording)")
        }
        .buttonStyle(OverlayIconButtonStyle(size: 24))
        .padding(4)
        .background(Capsule().fill(.ultraThinMaterial))
    }
}
