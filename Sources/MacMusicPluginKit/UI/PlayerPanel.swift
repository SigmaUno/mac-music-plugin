import AppKit
import SwiftUI

/// The popover shown from the menu bar item — a full now-playing / transport /
/// library panel that mirrors the Omarchy plugin's `PopupCard`.
@MainActor
public struct PlayerPanel: View {
    private let engine: PlayerEngine
    @State private var showCoverPicker = false
    @State private var openAtLogin = LoginItem.isEnabled

    public init(engine: PlayerEngine) {
        self.engine = engine
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NowPlayingHeader(engine: engine, showCoverPicker: $showCoverPicker)
            if showCoverPicker, engine.selectedIndex >= 0 { coverPicker }
            SeekBar(engine: engine)
            TransportControls(engine: engine)
            ModeToggles(engine: engine)
            VolumeControls(engine: engine)

            Divider()

            PlaylistTabStrip(engine: engine)
            TrackListView(engine: engine)
            if !engine.queueIndices.isEmpty { queueStrip }
            AddSourceForm(engine: engine)

            if !engine.statusText.isEmpty {
                Text(engine.statusText)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Toggle("Open at Login", isOn: Binding(get: { openAtLogin }, set: { setOpenAtLogin($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Unlock SSH agent…", action: engine.unlockSSHAgent)
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 400)
        .task {
            engine.refreshPlaylists()
            engine.refreshOutputDevices()
        }
    }

    private var queueStrip: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Up next (\(engine.queueIndices.count))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tint)
                Spacer()
                Button("Clear", action: engine.clearQueue).buttonStyle(.borderless).controlSize(.small)
            }
            Text(queueSummary)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var queueSummary: String {
        engine.queueIndices.map { i in
            i < engine.viewedTracks.count && engine.viewedPlaylist == engine.playingPlaylist
                ? engine.viewedTracks[i].title : "#\(i + 1)"
        }.joined(separator: "  ·  ")
    }

    private var coverPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button("Search iTunes") { engine.searchCoverArt() }.disabled(engine.isCoverBusy)
                Button("Choose file…", action: chooseCoverFile).disabled(engine.isCoverBusy)
                if engine.coverPath != nil {
                    Button("Remove", action: engine.removeCoverArt).disabled(engine.isCoverBusy)
                }
                Spacer(minLength: 0)
                if engine.isCoverBusy { ProgressView().controlSize(.small) }
            }
            .font(.caption).buttonStyle(.borderless)

            if !engine.coverResults.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(engine.coverResults) { result in
                            Button { engine.applyCoverArt(result); showCoverPicker = false } label: {
                                AsyncImage(url: URL(string: result.artworkURL)) { $0.resizable().scaledToFill() }
                                    placeholder: { Rectangle().fill(.quaternary) }
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .help("\(result.title) — \(result.artist)")
                        }
                    }
                }
                .frame(height: 60)
            }
            if !engine.coverStatus.isEmpty {
                Text(engine.coverStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            try LoginItem.setEnabled(on)
            openAtLogin = LoginItem.isEnabled
        } catch {
            openAtLogin = LoginItem.isEnabled
        }
    }

    private func chooseCoverFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.jpeg, .png]
        panel.title = "Choose a cover image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.applyCoverArt(fromFile: url.path)
    }
}

// MARK: - Now playing

@MainActor
struct NowPlayingHeader: View {
    let engine: PlayerEngine
    @Binding var showCoverPicker: Bool
    @State private var hoverCover = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if let path = engine.coverPath, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                    }
                }
                if engine.selectedIndex >= 0, hoverCover || showCoverPicker {
                    Rectangle().fill(.black.opacity(0.55))
                    Text(engine.coverPath == nil ? "Add\nCover" : "Change\nCover")
                        .font(.caption2.weight(.bold)).multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hoverCover = $0 }
            .onTapGesture { if engine.selectedIndex >= 0 { showCoverPicker.toggle() } }

            VStack(alignment: .leading, spacing: 2) {
                Text(engine.selectedIndex >= 0 ? engine.title : "Nothing playing")
                    .font(.headline).lineLimit(2)
                if engine.selectedIndex >= 0 {
                    Text(engine.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Text(engine.album).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                } else if engine.isLoading {
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

@MainActor
struct SeekBar: View {
    let engine: PlayerEngine

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.time(engine.positionMs)).font(.caption).monospacedDigit()
            Slider(value: Binding(get: { Double(engine.positionMs) },
                                  set: { engine.seek(toMs: Int($0)) }),
                   in: 0...Double(max(engine.durationMs, 1)))
                .disabled(engine.durationMs == 0)
            Text(Self.time(engine.durationMs)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    static func time(_ ms: Int) -> String {
        guard ms > 0 else { return "0:00" }
        let total = ms / 1000, h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

@MainActor
struct TransportControls: View {
    let engine: PlayerEngine

    var body: some View {
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
}

@MainActor
struct ModeToggles: View {
    let engine: PlayerEngine

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Autoplay", isOn: Binding(get: { engine.autoplay }, set: { engine.setAutoplay($0) }))
            Toggle("Shuffle", isOn: Binding(get: { engine.shuffle }, set: { engine.setShuffle($0) }))
            Toggle("Repeat one", isOn: Binding(get: { engine.repeatOne }, set: { engine.setRepeatOne($0) }))
        }
        .toggleStyle(.checkbox).font(.caption)
    }
}

@MainActor
struct VolumeControls: View {
    let engine: PlayerEngine

    var body: some View {
        HStack(spacing: 8) {
            Button(action: engine.toggleMute) {
                Image(systemName: engine.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.borderless)
            Slider(value: Binding(get: { Double(engine.volume) }, set: { engine.setVolume(Int($0)) }), in: 0...100)
            Picker("", selection: Binding(get: { engine.outputDeviceName ?? "" },
                                          set: { engine.selectOutputDevice($0.isEmpty ? nil : $0) })) {
                Text("System default").tag("")
                ForEach(engine.outputDevices, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(maxWidth: 130)
        }
    }
}
