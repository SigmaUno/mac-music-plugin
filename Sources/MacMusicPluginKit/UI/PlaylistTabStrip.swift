import SwiftUI

/// Horizontally scrolling playlist tabs plus an inline "new playlist" field.
/// The viewed tab is filled; a playlist that is *playing* while a different one
/// is viewed keeps a faint tint; `INCOMING >>` staging lists show in orange.
/// Mirrors the tab strip in `BarWidget.qml`.
struct PlaylistTabStrip: View {
    let engine: PlayerEngine
    @State private var adding = false
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(engine.playlistNames, id: \.self) { name in
                        tab(name)
                    }
                }
            }
            if adding {
                TextField("name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                    .focused($nameFocused)
                    .onSubmit(commit)
                    .onExitCommand { adding = false; newName = "" }
            } else {
                Button {
                    adding = true
                    nameFocused = true
                } label: {
                    Image(systemName: "plus").font(.caption.weight(.bold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("New playlist")
            }
        }
    }

    private func tab(_ name: String) -> some View {
        let isViewed = name == engine.viewedPlaylist
        let isPlaying = name == engine.playingPlaylist
        let isIncoming = PlaylistName.incomingTarget(of: name) != nil
        let label = isIncoming ? "+ \(PlaylistName.incomingTarget(of: name) ?? name)"
            : (name == PlaylistName.star ? "★ all" : name)
        let tint: Color = isIncoming ? .orange : .accentColor

        return Button {
            engine.viewPlaylist(name)
        } label: {
            Text(label)
                .font(.caption.weight(isViewed || isPlaying || isIncoming ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isViewed ? tint.opacity(0.9)
                              : isIncoming ? tint.opacity(0.28)
                              : isPlaying ? tint.opacity(0.16) : .clear)
                }
                .foregroundStyle(isViewed ? Color.white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func commit() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        adding = false
        newName = ""
        guard !trimmed.isEmpty else { return }
        engine.createPlaylist(trimmed)
    }
}
