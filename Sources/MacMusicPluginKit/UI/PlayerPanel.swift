import AppKit
import SwiftUI

/// The popover shown from the menu bar item. Milestone 3: a working now-playing
/// header, seek + transport, mode toggles, volume/output, a playlist picker and
/// a tappable track list, plus an "Add local file" affordance. Milestone 6
/// rebuilds this into the full styled panel that mirrors the Omarchy `PopupCard`.
public struct PlayerPanel: View {
    private let engine: PlayerEngine

    public init(engine: PlayerEngine) {
        self.engine = engine
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            nowPlaying
            seekRow
            transportRow
            modeRow
            volumeRow
            Divider()
            libraryRow
            trackList
            if !engine.statusText.isEmpty {
                Text(engine.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Add local file…", action: addLocalFile)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 380)
        .task {
            engine.refreshPlaylists()
            engine.refreshOutputDevices()
        }
    }

    // MARK: Sections

    private var nowPlaying: some View {
        HStack(spacing: 10) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.selectedIndex >= 0 ? engine.title : "Nothing playing")
                    .font(.headline)
                    .lineLimit(2)
                if engine.selectedIndex >= 0 {
                    Text(engine.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Text(engine.album).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var cover: some View {
        Group {
            if let path = engine.coverPath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var seekRow: some View {
        HStack(spacing: 8) {
            Text(Self.time(engine.positionMs)).font(.caption).monospacedDigit()
            Slider(
                value: Binding(
                    get: { Double(engine.positionMs) },
                    set: { engine.seek(toMs: Int($0)) }),
                in: 0...Double(max(engine.durationMs, 1))
            )
            .disabled(engine.durationMs == 0)
            Text(Self.time(engine.durationMs)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var transportRow: some View {
        HStack(spacing: 24) {
            Spacer()
            Button(action: engine.previous) { Image(systemName: "backward.fill") }
            Button(action: engine.togglePlayPause) {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill").font(.title2)
            }
            Button(action: engine.next) { Image(systemName: "forward.fill") }
            Spacer()
        }
        .buttonStyle(.borderless)
        .disabled(engine.selectedIndex < 0)
    }

    private var modeRow: some View {
        HStack(spacing: 12) {
            Toggle("Autoplay", isOn: Binding(get: { engine.autoplay }, set: engine.setAutoplay))
            Toggle("Shuffle", isOn: Binding(get: { engine.shuffle }, set: engine.setShuffle))
            Toggle("Repeat one", isOn: Binding(get: { engine.repeatOne }, set: engine.setRepeatOne))
        }
        .toggleStyle(.checkbox)
        .font(.caption)
    }

    private var volumeRow: some View {
        HStack(spacing: 8) {
            Button(action: engine.toggleMute) {
                Image(systemName: engine.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.borderless)
            Slider(value: Binding(get: { Double(engine.volume) }, set: { engine.setVolume(Int($0)) }),
                   in: 0...100)
            Picker("", selection: Binding(
                get: { engine.outputDeviceName ?? "" },
                set: { engine.selectOutputDevice($0.isEmpty ? nil : $0) })
            ) {
                Text("System default").tag("")
                ForEach(engine.outputDevices, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 120)
        }
    }

    private var libraryRow: some View {
        HStack {
            Picker("Playlist", selection: Binding(
                get: { engine.viewedPlaylist },
                set: { engine.viewPlaylist($0) })
            ) {
                ForEach(engine.playlistNames, id: \.self) { name in
                    Text(name == "*" ? "★ all" : name).tag(name)
                }
            }
            .labelsHidden()
            Spacer()
            Text("\(engine.viewedTracks.count) tracks").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var trackList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(Array(engine.viewedTracks.enumerated()), id: \.element.id) { index, track in
                    let isCurrent = engine.viewedPlaylist == engine.playingPlaylist
                        && index == engine.selectedIndex
                    Button {
                        engine.playFromViewed(index)
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(index + 1)").font(.caption).monospacedDigit()
                                .foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title).lineLimit(1)
                                Text("\(track.artist) · \(track.album)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if isCurrent {
                                Image(systemName: engine.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                                    .font(.caption).foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(.plain)
                    .background(isCurrent ? Color.accentColor.opacity(0.12) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contextMenu {
                        Button("Play next / queue") { engine.enqueue(index) }
                    }
                }
            }
        }
        .frame(maxHeight: 220)
    }

    // MARK: Actions

    private func addLocalFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.title = "Add music files"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let name = url.deletingPathExtension().lastPathComponent
            let meta = TrackMetadata(title: name, artist: "Unknown artist", album: "Unknown album")
            try? engine.addLocalFile(path: url.path, metadata: meta)
        }
        engine.refreshPlaylists()
    }

    private static func time(_ ms: Int) -> String {
        guard ms > 0 else { return "0:00" }
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
