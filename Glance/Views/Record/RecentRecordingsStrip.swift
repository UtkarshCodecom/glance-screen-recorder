import SwiftUI

struct RecentRecordingsStrip: View {
    @Environment(AppModel.self) private var app
    @State private var playing: RecordingItem?

    var body: some View {
        let recent = Array(app.library.items.prefix(4))
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent recordings").font(.title3.weight(.semibold))
                Spacer()
                if !app.library.items.isEmpty {
                    Button("View all") { app.sidebarSelection = .library }
                        .buttonStyle(.link)
                }
            }
            if recent.isEmpty {
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "film").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No recordings yet").font(.callout.weight(.semibold))
                            Text("Your videos are saved as MP4 to \(app.settingsStore.outputDirectory.path).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                    ForEach(recent) { item in
                        RecordingCard(item: item, compact: true) { playing = item }
                    }
                }
            }
        }
        .sheet(item: $playing) { PlayerSheet(item: $0) }
    }
}
