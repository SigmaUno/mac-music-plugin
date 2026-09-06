import SwiftUI

/// The filterable track list for the viewed playlist: per-row play, queue,
/// edit and remove — or accept/decline when reviewing a `INCOMING >>` staging
/// list, with bulk actions beside the filter field. Mirrors the library section
/// of `BarWidget.qml`.
@MainActor
struct TrackListView: View {
    let engine: PlayerEngine
    @State private var filter = ""
    @State private var editingID: String?

    private var isIncoming: Bool { engine.viewedIncomingTarget != nil }

    private var rows: [(index: Int, track: Track)] {
        let all = Array(engine.viewedTracks.enumerated()).map { (index: $0.offset, track: $0.element) }
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { "\($0.track.title) \($0.track.artist) \($0.track.album)".lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.tertiary)
                TextField("Filter by title, artist or album", text: $filter)
                    .textFieldStyle(.plain)
                if isIncoming, !rows.isEmpty {
                    Button {
                        engine.acceptIncoming(trackIDs: rows.map(\.track.id))
                    } label: { Image(systemName: "plus.circle.fill") }
                        .help("Add every track shown")
                    Button {
                        engine.declineIncoming(trackIDs: rows.map(\.track.id))
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .help("Decline every track shown")
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)

            if rows.isEmpty {
                Text(engine.viewedTracks.isEmpty ? "No tracks in this playlist." : "Nothing matches “\(filter)”.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(rows, id: \.track.id) { row in
                            if editingID == row.track.id {
                                TrackEditor(track: row.track) { title, artist, album in
                                    engine.editTrack(id: row.track.id, title: title, artist: artist, album: album)
                                    editingID = nil
                                } onCancel: { editingID = nil }
                            } else {
                                TrackRow(engine: engine, index: row.index, track: row.track,
                                         isIncoming: isIncoming) { editingID = row.track.id }
                            }
                        }
                    }
                }
                // A ScrollView has no content-based ideal height, so inside the
                // size-to-fit MenuBarExtra window it collapses to nothing unless
                // pinned. Give it a definite height (short lists hug their rows).
                .frame(height: min(CGFloat(rows.count) * 32 + 6, 300))
            }
        }
    }
}

@MainActor
private struct TrackRow: View {
    let engine: PlayerEngine
    let index: Int
    let track: Track
    let isIncoming: Bool
    let onEdit: () -> Void
    @State private var hovering = false

    private var isCurrent: Bool {
        engine.viewedPlaylist == engine.playingPlaylist && index == engine.selectedIndex
    }
    private var queuePos: Int { (engine.queueIndices.firstIndex(of: index)).map { $0 + 1 } ?? 0 }

    var body: some View {
        HStack(spacing: 8) {
            Text(queuePos > 0 ? "▸\(queuePos)" : "\(index + 1)")
                .font(.caption).monospacedDigit()
                .foregroundStyle(queuePos > 0 ? Color.accentColor : Color.secondary)
                .frame(width: 26, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(TrackTitle.display(track, position: index + 1, number: .prefix)).lineLimit(1)
                Text("\(track.artist) · \(track.album)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer(minLength: 0)

            if isCurrent {
                Image(systemName: engine.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                    .font(.caption).foregroundStyle(.tint)
            }

            if hovering {
                if isIncoming {
                    rowButton("plus.circle", "Add to playlist") { engine.acceptIncoming(trackIDs: [track.id]) }
                    rowButton("xmark.circle", "Decline") { engine.declineIncoming(trackIDs: [track.id]) }
                } else {
                    if queuePos > 0 {
                        rowButton("text.badge.minus", "Remove from queue") { engine.dequeue(index) }
                    } else {
                        rowButton("text.badge.plus", "Play next / queue") { engine.enqueue(index) }
                    }
                    rowButton("pencil", "Edit tags", action: onEdit)
                    rowButton("trash", "Remove") { engine.removeTrack(id: track.id) }
                }
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .contentShape(Rectangle())
        .background(isCurrent ? Color.accentColor.opacity(0.12) : (hovering ? Color.primary.opacity(0.06) : .clear))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onHover { hovering = $0 }
        .onTapGesture { engine.playFromViewed(index) }
    }

    private func rowButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .font(.caption)
            .help(help)
    }
}

@MainActor
private struct TrackEditor: View {
    let track: Track
    let onSave: (String, String, String) -> Void
    let onCancel: () -> Void
    @State private var title: String
    @State private var artist: String
    @State private var album: String

    init(track: Track, onSave: @escaping (String, String, String) -> Void, onCancel: @escaping () -> Void) {
        self.track = track
        self.onSave = onSave
        self.onCancel = onCancel
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
        _album = State(initialValue: track.album)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Edit track info").font(.caption.weight(.semibold))
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextField("Artist", text: $artist).textFieldStyle(.roundedBorder)
            TextField("Album", text: $album).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(title, artist, album) }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
    }
}
