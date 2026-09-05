import SwiftUI

/// The popover shown when the menu bar item is clicked. Over the milestones this
/// grows into the full now-playing / transport / library panel that mirrors the
/// Omarchy plugin's `PopupCard`.
///
/// Milestone 2: shows the playlists the `LibraryStore` found, with a track count.
public struct PlayerPanel: View {
    private let library: LibraryStore
    @State private var playlists: [(name: String, count: Int)] = []

    public init(library: LibraryStore) {
        self.library = library
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Mac Music Plugin")
                    .font(.headline)
            }

            Text("Nothing playing")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            Text("Playlists")
                .font(.caption)
                .foregroundStyle(.secondary)
            if playlists.isEmpty {
                Text("None yet").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(playlists, id: \.name) { entry in
                    HStack {
                        Text(entry.name == "*" ? "★ all" : entry.name)
                        Spacer()
                        Text("\(entry.count)").foregroundStyle(.tertiary).monospacedDigit()
                    }
                    .font(.callout)
                }
            }

            Divider()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(16)
        .task { reload() }
    }

    private func reload() {
        playlists = library.playlistNames().map { name in
            (name, (try? library.load(name).tracks.count) ?? 0)
        }
    }
}
