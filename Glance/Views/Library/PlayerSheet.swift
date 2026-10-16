import AVKit
import SwiftUI

struct PlayerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let item: RecordingItem

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.headline).lineLimit(1)
                    Text(item.createdAt.formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { RecordingActions.copy(item.url) } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { app.library.reveal(item) } label: { Label("Show in Finder", systemImage: "folder") }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            PlayerView(url: item.url)
        }
        .frame(minWidth: 820, idealWidth: 1000, minHeight: 540, idealHeight: 660)
    }
}

private struct PlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.player = AVPlayer(url: url)
        view.player?.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
