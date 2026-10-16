import SwiftUI

struct RecordView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    PermissionsPanel()
                    StageView()
                    RecentRecordingsStrip()
                }
                .padding(28)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
            Divider()
            InspectorView()
                .frame(width: 330)
        }
        .navigationTitle("Record")
        .onAppear {
            app.setCameraDemand(.preview, true)
            app.setMicrophoneDemand(.preview, true)
            // Listing screen content before permission is granted would trigger the system prompt.
            if app.permissions.screen == .granted { Task { await app.sources.refresh() } }
        }
        .onDisappear {
            app.setCameraDemand(.preview, false)
            app.setMicrophoneDemand(.preview, false)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New recording")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Arrange your camera bubble below. What you see here is exactly how it's recorded.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Live preview of the selected source with the draggable camera bubble on top.
struct StageView: View {
    @Environment(AppModel.self) private var app
    @State private var dragStartCenter: CGPoint?

    var body: some View {
        let sources = app.sources
        let aspect = min(max(sources.selectedAspectRatio, 0.5), 3)
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                if let image = sources.previewImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(aspect, contentMode: .fit)
            .clipped()
            .overlay {
                GeometryReader { geometry in
                    if app.settings.cameraEnabled {
                        bubble(in: geometry.size)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)

            HStack(spacing: 8) {
                Image(systemName: sources.kind.systemImage).foregroundStyle(.secondary)
                Text(sources.selectionTitle).font(.callout).lineLimit(1)
                Spacer()
                if app.settings.cameraEnabled {
                    Text("Bubble").font(.caption).foregroundStyle(.secondary)
                    ForEach(CameraOverlayLayout.Corner.allCases) { corner in
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                app.coordinator.updateCameraLayout { $0.move(to: corner, in: stageReferenceSize(aspect)) }
                            }
                        } label: {
                            Image(systemName: icon(for: corner))
                        }
                        .buttonStyle(.borderless)
                        .help("Move bubble to \(corner.title.lowercased())")
                    }
                }
            }
        }
    }

    private func bubble(in size: CGSize) -> some View {
        let layout = app.settings.cameraLayout
        let rect = layout.rect(in: size)
        let radius = layout.shape.cornerRadius(for: rect.size)
        let border = layout.borderWidth(for: rect.size)
        return ZStack {
            if app.isCameraRunning {
                CameraPreview(camera: app.camera, mirrored: layout.mirrored)
            } else {
                Rectangle().fill(Color.black.opacity(0.75))
                    .overlay(Image(systemName: app.permissions.camera == .granted ? "video" : "video.slash")
                        .foregroundStyle(.white.opacity(0.7)).font(.title2))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: max(0, radius - border), style: .continuous))
        .padding(border)
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color(red: layout.borderColor.red, green: layout.borderColor.green, blue: layout.borderColor.blue,
                                opacity: layout.borderColor.alpha), lineWidth: border))
        .shadow(color: .black.opacity(layout.showsShadow ? 0.35 : 0), radius: 8, y: 3)
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .gesture(
            DragGesture()
                .onChanged { value in
                    let start = dragStartCenter ?? layout.center
                    if dragStartCenter == nil { dragStartCenter = start }
                    let proposed = CGPoint(x: start.x + value.translation.width / size.width,
                                           y: start.y + value.translation.height / size.height)
                    app.coordinator.updateCameraLayout { layout in
                        layout.center = proposed
                        layout.setCenter(fromRect: layout.rect(in: size), in: size)
                    }
                }
                .onEnded { _ in dragStartCenter = nil }
        )
        .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
        .help("Drag to position your camera")
    }

    private var placeholder: some View {
        ZStack {
            Theme.brandGradient.opacity(0.85)
            VStack(spacing: 8) {
                Image(systemName: app.permissions.screen == .granted ? "display" : "lock.display")
                    .font(.system(size: 40, weight: .light))
                Text(app.permissions.screen == .granted
                     ? (app.sources.isLoading ? "Loading preview…" : "Preview unavailable")
                     : "Allow screen recording to see a preview")
                    .font(.callout.weight(.medium))
            }
            .foregroundStyle(.white)
        }
    }

    private func stageReferenceSize(_ aspect: CGFloat) -> CGSize {
        CGSize(width: 1000 * aspect, height: 1000)
    }

    private func icon(for corner: CameraOverlayLayout.Corner) -> String {
        switch corner {
        case .topLeft: return "arrow.up.left.square"
        case .topRight: return "arrow.up.right.square"
        case .bottomLeft: return "arrow.down.left.square"
        case .bottomRight: return "arrow.down.right.square"
        }
    }
}

struct PermissionsPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let missing = PermissionKind.allCases.filter { kind in
            switch kind {
            case .screen: return app.permissions.screen != .granted
            case .camera: return app.settings.cameraEnabled && app.permissions.camera != .granted
            case .microphone: return app.settings.capturesMicrophone && app.permissions.microphone != .granted
            }
        }
        if !missing.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "A few permissions first", systemImage: "hand.raised.fill")
                    Text("macOS asks you to approve access once. Glance never records without you pressing Record.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(missing) { kind in row(kind) }
                    if missing.contains(.screen) && app.permissions.screen == .denied {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("After enabling Screen & System Audio Recording, relaunch Glance.")
                                Text("Glance already switched on but still blocked? macOS ties this permission to the exact app build. In that list, select Glance, remove it with −, then relaunch and allow it again.")
                            }
                            Spacer()
                            Button("Relaunch") { Relauncher.relaunch() }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func row(_ kind: PermissionKind) -> some View {
        let state = app.permissions.state(for: kind)
        return HStack(spacing: 12) {
            Image(systemName: kind.systemImage).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(.callout.weight(.semibold))
                Text(kind.explanation).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state == .notDetermined {
                Button("Allow…") { Task { await app.permissions.request(kind); app.updateDevices(); await app.sources.refresh() } }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Open Settings") { app.permissions.openSystemSettings(for: kind) }
            }
        }
    }
}

enum Relauncher {
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
