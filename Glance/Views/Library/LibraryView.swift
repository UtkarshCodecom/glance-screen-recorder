import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""
    @State private var playing: RecordingItem?
    @State private var renaming: RecordingItem?
    @State private var trashing: RecordingItem?
    @State private var actionError: String?

    var body: some View {
        let items = filteredItems
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                RecoveryBanner()
                if app.library.items.isEmpty {
                    ContentUnavailableView {
                        Label("No recordings yet", systemImage: "film.stack")
                    } description: {
                        Text("Recordings you make are saved to \(app.settingsStore.outputDirectory.path).")
                    } actions: {
                        Button("New Recording") { app.sidebarSelection = .record }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 420)
                } else if items.isEmpty {
                    ContentUnavailableView.search(text: search)
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 20)], spacing: 22) {
                        ForEach(items) { item in
                            RecordingCard(item: item) { playing = item }
                                .contextMenu { menu(for: item) }
                        }
                    }
                }
            }
            .padding(28)
        }
        .navigationTitle("Library")
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: "Search recordings")
        .toolbar {
            ToolbarItemGroup {
                Button { app.library.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button { app.library.openFolder() } label: { Label("Open Folder", systemImage: "folder") }
            }
        }
        .sheet(item: $playing) { PlayerSheet(item: $0) }
        .sheet(item: $renaming) { item in
            RenameSheet(item: item) { newName in
                try app.library.rename(item, to: newName)
            }
        }
        .confirmationDialog("Move “\(trashing?.name ?? "")” to the Trash?", isPresented: trashBinding, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let trashing { perform { try app.library.moveToTrash(trashing) } }
            }
        } message: {
            Text("You can restore it from the Trash in Finder.")
        }
        .alert("Couldn't complete that", isPresented: errorBinding) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .onAppear { app.library.refresh() }
    }

    private var filteredItems: [RecordingItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return app.library.items }
        return app.library.items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var subtitle: String {
        let total = app.library.items.reduce(Int64(0)) { $0 + $1.fileSize }
        let count = app.library.items.count
        return "\(count) recording\(count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }

    @ViewBuilder
    private func menu(for item: RecordingItem) -> some View {
        Button("Play") { playing = item }
        Button("Rename…") { renaming = item }
        Button("Show in Finder") { app.library.reveal(item) }
        Button("Copy") { RecordingActions.copy(item.url) }
        ShareLink(item: item.url) { Text("Share…") }
        Divider()
        Button("Move to Trash…", role: .destructive) { trashing = item }
    }

    private var trashBinding: Binding<Bool> {
        Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { actionError = error.localizedDescription }
    }
}

enum RecordingActions {
    static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }
}

private struct RecoveryBanner: View {
    @Environment(AppModel.self) private var app
    @State private var errors: [String] = []

    var body: some View {
        if !app.library.unfinished.isEmpty {
            Card {
                HStack(spacing: 12) {
                    Image(systemName: "bandage.fill").font(.title2).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(app.library.unfinished.count) unfinished recording\(app.library.unfinished.count == 1 ? "" : "s") found")
                            .font(.callout.weight(.semibold))
                        Text(errors.first ?? "Glance quit before saving. Recover what was captured, or discard it.")
                            .font(.caption).foregroundStyle(errors.isEmpty ? Color.secondary : Color.orange)
                    }
                    Spacer()
                    if app.library.isRecovering {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Discard", role: .destructive) { app.library.discardUnfinished() }
                        Button("Recover") {
                            Task {
                                errors = await app.library.recoverUnfinished(options: app.finalizeOptions).map(\.localizedDescription)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }
}

struct RecordingCard: View {
    @Environment(AppModel.self) private var app
    let item: RecordingItem
    var compact = false
    let onPlay: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Rectangle().fill(Color.black.opacity(0.85))
                if let image = app.library.thumbnails[item.url] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film").font(.title).foregroundStyle(.white.opacity(0.4))
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: compact ? 34 : 44))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.35))
                    .opacity(isHovering ? 1 : 0)
                    .scaleEffect(isHovering ? 1 : 0.85)
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                if let duration = app.library.durations[item.url] {
                    Text(duration.clockString)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(app.library.highlightedURL == item.url ? Color.accentColor : Color.primary.opacity(0.08),
                              lineWidth: app.library.highlightedURL == item.url ? 2.5 : 1))
            .shadow(color: .black.opacity(isHovering ? 0.18 : 0.08), radius: isHovering ? 12 : 6, y: 4)
            .scaleEffect(isHovering ? 1.015 : 1)
            .contentShape(Rectangle())
            .onTapGesture(perform: onPlay)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold)).lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
        .onAppear { app.library.requestThumbnail(for: item) }
        .help(item.url.path)
    }
}

private struct RenameSheet: View {
    let item: RecordingItem
    let onRename: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Recording").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: commit).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { name = item.name }
    }

    private func commit() {
        do {
            try onRename(name)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
