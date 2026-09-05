import AVFoundation
import Foundation
import Observation

/// The player the whole UI binds to. Owns the library, the audio subsystem, the
/// autoplay policy and resume state, and turns user intents ("play row 3",
/// "next", "seek") into playback. A single in-process object — there is no
/// `status.json` / `control` IPC as in the Omarchy split.
///
/// Milestone 3 covers local files. Remote loaders and next-track prefetch arrive
/// in milestone 4; metadata/cover import in milestone 5.
@MainActor
@Observable
public final class PlayerEngine {
    // MARK: Now playing
    public private(set) var title = ""
    public private(set) var artist = ""
    public private(set) var album = ""
    public private(set) var coverPath: String?
    public private(set) var positionMs = 0
    public private(set) var durationMs = 0
    public private(set) var isPlaying = false
    public private(set) var isLoading = false
    /// Row index within the *playing* playlist, or -1 when nothing is playing.
    public private(set) var selectedIndex = -1
    public private(set) var statusText = ""

    // MARK: Playlists
    public private(set) var playlistNames: [String] = []
    public private(set) var viewedPlaylist = PlaylistName.home
    public private(set) var playingPlaylist = PlaylistName.home
    public private(set) var viewedTracks: [Track] = []
    private var playingTracks: [Track] = []

    // MARK: Modes (persisted)
    public private(set) var autoplay = true
    public private(set) var shuffle = false
    public private(set) var repeatOne = false
    public private(set) var volume = 100
    public private(set) var muted = false
    public private(set) var outputDeviceName: String?
    public private(set) var outputDevices: [String] = []

    // MARK: Queue
    public private(set) var queue = PlayQueue()
    public var queueIndices: [Int] { queue.indices }

    // MARK: Collaborators
    private let library: LibraryStore
    private let loader: FallbackTrackLoader
    private let resume: ResumeStore
    private let defaults: UserDefaults
    private let audio = AudioPlayer()
    private let randomizer: IndexRandomizer

    private var backoff = AutoplayBackoff()
    private var loadTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var lastResumeWrite = Date.distantPast
    /// True while a load was started by autoplay/track-end rather than the user.
    private var advancing = false

    public init(library: LibraryStore,
                loader: FallbackTrackLoader = .standard(),
                resume: ResumeStore = ResumeStore(),
                defaults: UserDefaults = .standard,
                randomizer: IndexRandomizer = SystemRandomizer()) {
        self.library = library
        self.loader = loader
        self.resume = resume
        self.defaults = defaults
        self.randomizer = randomizer
        loadModes()
        audio.onTrackEnded = { [weak self] in self?.handleTrackEnded() }
    }

    // MARK: Lifecycle

    /// Call once after the library is bootstrapped. Loads the tab list, the
    /// playlist to show, and — with autoplay on — resumes the last track.
    public func start() {
        refreshPlaylists()
        refreshOutputDevices()
        audio.setGain(volume: volume, muted: muted)
        _ = audio.setOutputDevice(name: outputDeviceName)

        let saved = resume.read()
        let initial = saved.map(\.playlist).flatMap { name in
            playlistNames.contains(name) ? name : nil
        } ?? playlistNames.first ?? PlaylistName.home
        viewPlaylist(initial, adoptAsPlaying: true)

        startTicker()

        guard autoplay, let saved, saved.trackIndex >= 0,
              saved.trackIndex < playingTracks.count else { return }
        advancing = true
        start(index: saved.trackIndex, resumeAt: saved.positionMs, startPaused: !saved.isPlaying)
    }

    /// Persist a final resume point and stop background work. Call on quit.
    public func shutdown() {
        writeResume(force: true)
        ticker?.cancel()
        loadTask?.cancel()
        audio.stop()
    }

    // MARK: Playlist browsing

    public func refreshPlaylists() {
        playlistNames = library.playlistNames()
        reloadViewed()
    }

    public func viewPlaylist(_ name: String, adoptAsPlaying: Bool = false) {
        viewedPlaylist = name
        if name == PlaylistName.star { try? library.rebuildStar() }
        reloadViewed()
        if adoptAsPlaying {
            playingPlaylist = name
            playingTracks = viewedTracks
        }
    }

    private func reloadViewed() {
        viewedTracks = (try? library.load(viewedPlaylist).tracks) ?? []
        if viewedPlaylist == playingPlaylist { syncPlayingTracks() }
    }

    /// After a library mutation on the playing playlist, keep the playback
    /// snapshot and `selectedIndex` aligned. Mirrors `note_removed_row` /
    /// `resync_play_lib` (backend/app.c:2921/2957).
    private func syncPlayingTracks() {
        let playingID = selectedIndex >= 0 && selectedIndex < playingTracks.count
            ? playingTracks[selectedIndex].id : nil
        playingTracks = (try? library.load(playingPlaylist).tracks) ?? []
        if let playingID, let now = playingTracks.firstIndex(where: { $0.id == playingID }) {
            let old = selectedIndex
            selectedIndex = now
            if old != now { queue.compact(afterRemoving: min(old, now)) }
        } else if playingID != nil {
            // The playing row was deleted.
            if autoplay, !playingTracks.isEmpty {
                let landing = min(selectedIndex, playingTracks.count - 1)
                advancing = true
                start(index: max(0, landing))
            } else {
                stop()
            }
        }
    }

    /// Adds a local file to the viewed playlist and refreshes the list.
    /// A stand-in until the metadata importer (milestone 5) fills in real tags.
    public func addLocalFile(path: String, metadata: TrackMetadata) throws {
        try library.addSource(Source(kind: .local, path: path), metadata: metadata,
                              toPlaylist: viewedPlaylist)
        reloadViewed()
    }

    public func createPlaylist(_ name: String) {
        do {
            _ = try library.createPlaylist(name)
            refreshPlaylists()
            viewPlaylist(name)
        } catch {
            statusText = describe(error)
        }
    }

    // MARK: Transport

    /// Play row `index` of the *viewed* playlist, adopting it as the playing one.
    public func playFromViewed(_ index: Int) {
        advancing = false
        backoff.recordSuccess()
        playingPlaylist = viewedPlaylist
        playingTracks = viewedTracks
        queue.clear()
        start(index: index)
    }

    public func togglePlayPause() {
        guard durationMs > 0 else { return }
        if audio.isPlaying {
            audio.pause()
            isPlaying = false
            statusText = "Paused."
        } else {
            audio.play()
            isPlaying = true
            statusText = "Playing."
        }
        writeResume(force: true)
    }

    public func next() { playRelative(1) }
    public func previous() { playRelative(-1) }

    private func playRelative(_ delta: Int) {
        let count = playingTracks.count
        guard count > 0 else { statusText = "Playlist is empty."; return }
        advancing = false
        backoff.recordSuccess()

        if delta > 0, !queue.isEmpty || (shuffle && count > 1) {
            let next = AutoplayPolicy.takeNext(count: count, from: selectedIndex, queue: &queue,
                                              shuffle: shuffle, repeatOne: repeatOne,
                                              allowRepeat: false, randomizer: randomizer)
            start(index: next)
            return
        }
        start(index: AutoplayPolicy.step(count: count, from: selectedIndex, delta: delta))
    }

    public func seek(toMs ms: Int) {
        guard durationMs > 0 else { return }
        let clamped = max(0, min(ms, durationMs))
        audio.seek(toMs: clamped)
        positionMs = clamped
        writeResume(force: true)
    }

    public func stop() {
        loadTask?.cancel()
        audio.stop()
        isPlaying = false
        isLoading = false
        selectedIndex = -1
        title = ""; artist = ""; album = ""; coverPath = nil
        positionMs = 0; durationMs = 0
        advancing = false
        resume.write(nil)
    }

    // MARK: Modes

    public func setAutoplay(_ on: Bool) { autoplay = on; persistModes(); statusText = on ? "Autoplay enabled." : "Autoplay disabled." }
    public func setShuffle(_ on: Bool) { shuffle = on; persistModes(); statusText = on ? "Shuffle on." : "Shuffle off." }
    public func setRepeatOne(_ on: Bool) { repeatOne = on; persistModes(); statusText = on ? "Repeat one." : "Repeat off." }

    public func setVolume(_ value: Int) {
        volume = max(0, min(100, value))
        audio.setGain(volume: volume, muted: muted)
        persistModes()
    }

    public func toggleMute() {
        muted.toggle()
        audio.setGain(volume: volume, muted: muted)
        persistModes()
        statusText = muted ? "Muted." : "Unmuted."
    }

    public func refreshOutputDevices() {
        outputDevices = AudioOutput.devices().map(\.name)
    }

    public func selectOutputDevice(_ name: String?) {
        let applied = audio.setOutputDevice(name: name)
        outputDeviceName = applied
        persistModes()
        statusText = applied.map { "Output: \($0)" } ?? "Output: system default."
    }

    // MARK: Remote sources

    /// Opens Terminal to run `ssh-add` so an `ssh` / local-network source whose
    /// key is passphrase-protected can authenticate. Mirrors the "Unlock SSH
    /// agent" button in the Omarchy widget.
    public func unlockSSHAgent() {
        statusText = "Opening Terminal — add your key there, then retry the track."
        Task {
            let result = await Task.detached { SSHAgent.unlock() }.value
            if case .failed(let reason) = result { statusText = reason }
        }
    }

    // MARK: Queue

    public func enqueue(_ index: Int) {
        guard index >= 0, index < playingTracks.count else { return }
        guard queue.count < PlayQueue.capacity else { statusText = "Play queue is full (\(PlayQueue.capacity))."; return }
        queue.push(index)
        statusText = "Queued (\(queue.count) in queue)."
    }

    public func dequeue(_ index: Int) { queue.remove(index: index) }
    public func clearQueue() { queue.clear(); statusText = "Play queue cleared." }

    // MARK: Track loading

    private func start(index: Int, resumeAt: Int = 0, startPaused: Bool = false) {
        guard index >= 0, index < playingTracks.count else { return }
        let track = playingTracks[index]
        loadTask?.cancel()
        isLoading = true
        statusText = "Loading \(track.title)…"

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (url, source) = try await loader.loadTrack(track)
                if Task.isCancelled { return }
                try self.audio.load(url: url, playing: !startPaused)
                ScratchFile.prune(keeping: source.kind == .local ? [] : [source])
                self.onTrackStarted(track: track, index: index, resumeAt: resumeAt, paused: startPaused)
            } catch {
                if Task.isCancelled || (error as? TrackLoadError) == .cancelled { return }
                self.onLoadFailed(index: index, error: error)
            }
        }
    }

    private func onTrackStarted(track: Track, index: Int, resumeAt: Int, paused: Bool) {
        isLoading = false
        selectedIndex = index
        title = track.title
        artist = track.artist.isEmpty ? "No Artist" : track.artist
        album = track.album.isEmpty ? "No Album" : track.album
        coverPath = resolvedCoverPath(for: track)
        durationMs = audio.durationMs
        backoff.recordSuccess()

        if resumeAt > 1000, resumeAt + 1000 < durationMs {
            audio.seek(toMs: resumeAt)
            positionMs = resumeAt
        } else {
            positionMs = 0
        }
        isPlaying = !paused
        statusText = paused ? "Resumed (paused): \(track.title)" : "Playing \(track.title)."
        writeResume(force: true)
    }

    private func onLoadFailed(index: Int, error: Error) {
        isLoading = false
        let reason = describe(error)
        let name = index < playingTracks.count ? playingTracks[index].title : "track \(index + 1)"

        guard autoplay, advancing, playingTracks.count > 1 else {
            statusText = "Could not play \"\(name)\": \(reason)"
            return
        }
        statusText = "Skipped \"\(name)\": \(reason)"
        if backoff.recordFailure(playlistCount: playingTracks.count) {
            haltDeadPlaylist()
            return
        }
        let nextIndex = AutoplayPolicy.takeNext(count: playingTracks.count, from: index, queue: &queue,
                                                shuffle: shuffle, repeatOne: repeatOne,
                                                allowRepeat: false, randomizer: randomizer)
        let delay = backoff.retryDelay
        advancing = true
        if delay == .zero {
            start(index: nextIndex)
        } else {
            statusText += " Retrying in \(delay.components.seconds)s."
            loadTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled, self.autoplay else { return }
                self.start(index: nextIndex)
            }
        }
    }

    private func haltDeadPlaylist() {
        advancing = false
        backoff = AutoplayBackoff()
        isPlaying = false
        audio.pause()
        statusText = "Autoplay stopped: every source in \"\(playingPlaylist)\" failed to load."
        writeResume(force: true)
    }

    private func handleTrackEnded() {
        positionMs = durationMs
        if repeatOne {
            audio.seek(toMs: 0)
            audio.play()
            isPlaying = true
            positionMs = 0
            statusText = "Repeating: \(title)"
            return
        }
        guard autoplay, !playingTracks.isEmpty else {
            isPlaying = false
            writeResume(force: true)
            return
        }
        let next = AutoplayPolicy.takeNext(count: playingTracks.count, from: selectedIndex, queue: &queue,
                                           shuffle: shuffle, repeatOne: repeatOne,
                                           allowRepeat: true, randomizer: randomizer)
        advancing = true
        start(index: next)
    }

    // MARK: Position + resume

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if self.audio.isPlaying {
                    self.positionMs = min(self.audio.positionMs, self.durationMs)
                    self.isPlaying = true
                    if Date().timeIntervalSince(self.lastResumeWrite) >= 5 {
                        self.writeResume()
                    }
                }
            }
        }
    }

    private func writeResume(force: Bool = false) {
        guard selectedIndex >= 0, durationMs > 0 else {
            if force { resume.write(nil) }
            return
        }
        resume.write(ResumeState(playlist: playingPlaylist, trackIndex: selectedIndex,
                                 positionMs: positionMs, isPlaying: isPlaying), force: force)
        lastResumeWrite = Date()
    }

    // MARK: Helpers

    private func resolvedCoverPath(for track: Track) -> String? {
        guard let cover = track.cover else { return nil }
        return FileManager.default.fileExists(atPath: cover) ? cover : nil
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case let e as TrackLoadError:
            switch e {
            case .noUsableSource: return "track has no usable source"
            case .unsupportedKind(let k): return "\(k.displayName) sources are not supported yet"
            case .fileNotFound(let p): return "file not found: \(p)"
            case .cancelled: return "cancelled"
            case .transport(let m): return m
            }
        case let e as LibraryError:
            return "\(e)"
        default:
            return error.localizedDescription
        }
    }

    // MARK: Persisted modes

    private enum Key {
        static let autoplay = "autoplay", shuffle = "shuffle", repeatOne = "repeatOne"
        static let volume = "volume", muted = "muted", output = "outputDevice"
    }

    private func loadModes() {
        autoplay = defaults.object(forKey: Key.autoplay) as? Bool ?? true
        shuffle = defaults.bool(forKey: Key.shuffle)
        repeatOne = defaults.bool(forKey: Key.repeatOne)
        volume = defaults.object(forKey: Key.volume) as? Int ?? 100
        muted = defaults.bool(forKey: Key.muted)
        outputDeviceName = defaults.string(forKey: Key.output)
    }

    private func persistModes() {
        defaults.set(autoplay, forKey: Key.autoplay)
        defaults.set(shuffle, forKey: Key.shuffle)
        defaults.set(repeatOne, forKey: Key.repeatOne)
        defaults.set(volume, forKey: Key.volume)
        defaults.set(muted, forKey: Key.muted)
        defaults.set(outputDeviceName, forKey: Key.output)
    }
}
