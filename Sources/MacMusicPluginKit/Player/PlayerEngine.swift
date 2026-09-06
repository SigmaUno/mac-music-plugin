import AVFoundation
import Foundation
import Observation

/// The player the whole UI binds to. Owns the library, the audio subsystem, the
/// autoplay policy and resume state, and turns user intents ("play row 3",
/// "next", "seek") into playback. A single in-process object — there is no
/// `status.json` / `control` IPC as in the Omarchy split.
///
/// Milestone 3 covers local files; milestone 4 the remote loaders; milestone 5
/// tag import on add and cover art (embedded art at play time, an iTunes cover
/// chooser for the rest).
@MainActor
@Observable
public final class PlayerEngine {
    // MARK: Now playing
    /// Menu-bar form: cleaned title with the track number as a ` (NN)` suffix.
    public private(set) var title = ""
    public private(set) var artist = ""
    public private(set) var album = ""
    /// Player-header form: cleaned title with the track number removed entirely.
    public private(set) var nowPlayingTitle = ""
    /// Two-digit track number of the playing row, or "" — folded into the header
    /// album line as `… (Track NN)` by `nowPlayingAlbum`.
    public private(set) var currentTrackLabel = ""
    /// Player-header album line: `album` with a ` (Track NN)` tag.
    public var nowPlayingAlbum: String {
        guard !currentTrackLabel.isEmpty else { return album }
        let base = (album.isEmpty || album == "No Album") ? "" : "\(album) "
        return "\(base)(Track \(currentTrackLabel))"
    }
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

    // MARK: Cover chooser
    /// Candidate artwork from the last `searchCoverArt`, for the panel to show.
    public private(set) var coverResults: [CoverResult] = []
    public private(set) var coverStatus = ""
    public private(set) var isCoverBusy = false

    // MARK: Collaborators
    private let library: LibraryStore
    private let loader: FallbackTrackLoader
    private let resume: ResumeStore
    private let defaults: UserDefaults
    private let audio = AudioPlayer()
    private let randomizer: IndexRandomizer
    private let metadata: MetadataReading
    private let covers: CoverService
    private let coverStore: CoverStore
    private let prober: MetadataProbing

    private var backoff = AutoplayBackoff()
    private var loadTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var coverTask: Task<Void, Never>?
    private var backfillTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var lastResumeWrite = Date.distantPast
    /// Local file URL backing the current track (a real file or a scratch
    /// download), for on-demand embedded-artwork extraction.
    private var playingURL: URL?
    /// True while a load was started by autoplay/track-end rather than the user.
    private var advancing = false

    public init(library: LibraryStore,
                loader: FallbackTrackLoader = .standard(),
                resume: ResumeStore = ResumeStore(),
                defaults: UserDefaults = .standard,
                randomizer: IndexRandomizer = SystemRandomizer(),
                metadata: MetadataReading = AVMetadataReader(),
                covers: CoverService = SystemCoverService(),
                coverStore: CoverStore = CoverStore(),
                prober: MetadataProbing = SystemMetadataProber()) {
        self.library = library
        self.loader = loader
        self.resume = resume
        self.defaults = defaults
        self.randomizer = randomizer
        self.metadata = metadata
        self.covers = covers
        self.coverStore = coverStore
        self.prober = prober
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
        artworkTask?.cancel()
        coverTask?.cancel()
        backfillTask?.cancel()
        probeTask?.cancel()
        scanTask?.cancel()
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
        probeViewedPlaylist()
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

    /// Adds a local file to the viewed playlist, importing its title/artist/album
    /// tags (falling back to the file name, then "Unknown …", exactly as the C
    /// `build_song_query_for`). Refreshes the list on return.
    public func addLocalFile(path: String) async throws {
        let expanded = (path as NSString).expandingTildeInPath
        let fallbackTitle = (expanded as NSString).lastPathComponent
        let stem = (fallbackTitle as NSString).deletingPathExtension
        let tags = await metadata.read(URL(fileURLWithPath: expanded))
        try library.addSource(Source(kind: .local, path: path),
                              metadata: tags.trackMetadata(fallbackTitle: stem.isEmpty ? fallbackTitle : stem),
                              toPlaylist: viewedPlaylist)
        if tags.isEmpty {
            statusText = "Added \(stem) — no tags, imported by file name."
        }
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

    /// Adds an `https` / `ssh` / `network` source to the viewed playlist. For an
    /// `https` URL AVFoundation can read tags off the remote asset; `ssh` /
    /// `network` fall back to the file name (the C backend probes over ssh, which
    /// this deliberately skips — the user can edit the row).
    public func addRemoteSource(kind: SourceKind, username: String = "", host: String = "",
                                remotePath: String = "", url: String = "") async {
        let source: Source
        var probeURL: URL?
        var fallback: String
        switch kind {
        case .https:
            guard url.lowercased().hasPrefix("https://") else {
                statusText = "Only https:// URLs are supported."; return
            }
            source = Source(kind: .https, url: url)
            probeURL = URL(string: url)
            fallback = ((url as NSString).lastPathComponent as NSString).deletingPathExtension
        case .ssh, .network:
            guard !username.isEmpty, !host.isEmpty, !remotePath.isEmpty else {
                statusText = "Enter the user, host and remote path."; return
            }
            guard RemoteCommand.isValidName(username, allowColon: false),
                  RemoteCommand.isValidName(host, allowColon: true) else {
                statusText = "That username or host has characters that are not allowed."; return
            }
            source = Source(kind: kind, path: remotePath, username: username, ip: host)
            fallback = ((remotePath as NSString).lastPathComponent as NSString).deletingPathExtension
        case .local:
            statusText = "Use “Add local file” for local sources."; return
        }
        if fallback.isEmpty { fallback = kind.displayName }

        let tags = probeURL.map { url in Task { await self.metadata.read(url) } }
        let extracted = await tags?.value ?? ExtractedMetadata()
        do {
            try library.addSource(source,
                                  metadata: extracted.trackMetadata(fallbackTitle: fallback),
                                  toPlaylist: viewedPlaylist)
            statusText = extracted.isEmpty
                ? "Added \(fallback) — imported by name; edit the row to fix the tags."
                : "Added \(extracted.title ?? fallback)."
            reloadViewed()
        } catch {
            statusText = "Could not add that source: \(describe(error))"
        }
    }

    /// Rewrites a track's display fields in the viewed playlist.
    public func editTrack(id: String, title: String, artist: String, album: String) {
        do {
            try library.updateTrack(id: id, in: viewedPlaylist,
                                    title: title, artist: artist, album: album)
            reloadViewed()
            if viewedPlaylist == playingPlaylist, selectedIndex >= 0,
               selectedIndex < playingTracks.count, playingTracks[selectedIndex].id == id {
                let edited = Track(title: title, artist: artist, album: album)
                let pos = selectedIndex + 1
                self.title = title.isEmpty ? "No song loaded"
                    : TrackTitle.display(edited, position: pos, number: .suffix)
                self.nowPlayingTitle = title.isEmpty ? "No song loaded"
                    : TrackTitle.display(edited, position: pos, number: .omit)
                self.currentTrackLabel = title.isEmpty ? "" : TrackTitle.numberLabel(edited, position: pos)
                self.artist = artist.isEmpty ? "No Artist" : artist
                self.album = album.isEmpty ? "No Album" : album
            }
            statusText = "Updated \(title)."
        } catch {
            statusText = describe(error)
        }
    }

    /// Removes a track from the viewed playlist. If it was the playing row,
    /// `syncPlayingTracks` steps playback forward or stops.
    public func removeTrack(id: String) {
        do {
            try library.removeTrack(id: id, from: viewedPlaylist)
            reloadViewed()
            statusText = "Removed from \(viewedPlaylist)."
        } catch {
            statusText = describe(error)
        }
    }

    // MARK: Directory-scan staging review

    public var viewedIncomingTarget: String? { PlaylistName.incomingTarget(of: viewedPlaylist) }

    public func acceptIncoming(trackIDs: [String]) {
        applyIncoming(trackIDs) { try self.library.acceptIncoming(trackIDs: $0, from: self.viewedPlaylist) }
    }

    public func declineIncoming(trackIDs: [String]) {
        applyIncoming(trackIDs) { try self.library.declineIncoming(trackIDs: $0, from: self.viewedPlaylist) }
    }

    // MARK: Directory scan

    public private(set) var isScanning = false
    public private(set) var scanCount = 0

    private let scanner = DirectoryScanner()
    private var scanTask: Task<Void, Never>?

    /// The playlist a scan should stage into: the viewed one, or — if that is
    /// itself a staging list — its target; `home` when viewing `*` or a staging
    /// list with an unknown target. Mirrors `scanTargetPlaylist` (BarWidget.qml).
    private var scanTargetPlaylist: String {
        if let target = viewedIncomingTarget { return target }
        if viewedPlaylist != PlaylistName.star,
           PlaylistName.incomingTarget(of: viewedPlaylist) == nil,
           PlaylistName.isValid(viewedPlaylist) {
            return viewedPlaylist
        }
        return PlaylistName.home
    }

    /// Scans `directory` (local, or remote over `ssh` when `kind` is `ssh` /
    /// `network`) into a `INCOMING >> <target> <<` staging playlist, switches the
    /// view to it, and lets the user accept or decline each row. Mirrors
    /// `start_scan` / `handle_scan` (backend/app.c:3382).
    public func startScan(kind: SourceKind, username: String = "", host: String = "",
                          directory: String) async {
        guard !isScanning else { statusText = "A scan is already running."; return }
        let dir = directory.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty else { statusText = "Scan failed: a directory is required."; return }

        let target = scanTargetPlaylist
        guard library.playlistExists(target) else {
            statusText = "Scan failed: no such playlist “\(target)”."; return
        }
        if (kind == .ssh || kind == .network),
           !(RemoteCommand.isValidName(username, allowColon: false)
             && RemoteCommand.isValidName(host, allowColon: true)) {
            statusText = "Scan failed: invalid username or host."; return
        }

        let staging = PlaylistName.incomingName(for: target)
        do {
            if !library.playlistExists(staging) {
                try library.writeStaging(target: target, tracks: [])
            }
        } catch {
            statusText = "Scan failed: could not create the staging playlist."; return
        }
        refreshPlaylists()
        viewPlaylist(staging)

        isScanning = true
        scanCount = 0
        statusText = "Scanning \(dir)…"

        scanTask = Task { [weak self] in
            guard let self else { return }
            let tracks: [Track]
            do {
                if kind == .local {
                    tracks = self.scanner.scanLocal(directory: dir)
                } else {
                    tracks = try await self.scanner.scanRemote(kind: kind, username: username,
                                                               host: host, directory: dir)
                }
            } catch {
                self.isScanning = false
                self.statusText = "Scan failed: \(self.describe(error))"
                return
            }
            if Task.isCancelled { self.isScanning = false; return }

            do {
                try self.library.writeStaging(target: target, tracks: tracks)
            } catch {
                self.isScanning = false
                self.statusText = "Scan failed: could not write results."
                return
            }
            self.scanCount = tracks.count
            self.isScanning = false
            // Always land the user on the staging list with the results loaded,
            // even if they browsed away while the scan ran.
            self.refreshPlaylists()
            self.viewPlaylist(staging)
            self.statusText = tracks.isEmpty
                ? "Scan found no audio files in that directory."
                : "Scan done: \(tracks.count) file\(tracks.count == 1 ? "" : "s") staged in “\(staging)”. Accept or decline them."
        }
    }

    private func applyIncoming(_ ids: [String], _ action: ([String]) throws -> Void) {
        guard !ids.isEmpty, let target = viewedIncomingTarget else { return }
        let staging = viewedPlaylist
        do {
            try action(ids)
            refreshPlaylists()
            // The staging file is deleted when it empties; fall back to its target.
            if !library.playlistExists(staging) {
                viewPlaylist(library.playlistNames().contains(target) ? target : (library.playlistNames().first ?? PlaylistName.home))
            } else {
                reloadViewed()
            }
            statusText = "Reviewed \(ids.count) track\(ids.count == 1 ? "" : "s")."
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
        artworkTask?.cancel()
        backfillTask?.cancel()
        audio.stop()
        isPlaying = false
        isLoading = false
        selectedIndex = -1
        title = ""; artist = ""; album = ""; coverPath = nil
        nowPlayingTitle = ""; currentTrackLabel = ""
        playingURL = nil
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

    // MARK: Cover art

    /// Looks up candidate artwork for the playing track. An empty/absent query
    /// falls back to "<artist> <title>". Mirrors `handle_cover_search`.
    public func searchCoverArt(query: String? = nil) {
        guard selectedIndex >= 0 else { coverStatus = "Nothing is playing."; return }
        let term = (query?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(artist) \(title)".trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { coverStatus = "Nothing to search for."; return }

        coverTask?.cancel()
        isCoverBusy = true
        coverStatus = "Searching for cover art…"
        coverResults = []
        coverTask = Task { [weak self] in
            guard let self else { return }
            do {
                let hits = try await covers.search(term: term)
                if Task.isCancelled { return }
                coverResults = hits
                coverStatus = hits.isEmpty ? "No cover art found for that search." :
                    "\(hits.count) cover\(hits.count == 1 ? "" : "s") found."
            } catch {
                if Task.isCancelled { return }
                coverStatus = "Cover search failed: \(describe(error))"
            }
            isCoverBusy = false
        }
    }

    /// Downloads `result`'s image, stores it beside the library, and hangs it on
    /// the track this was started for — not whatever is playing when the
    /// download lands. Mirrors `handle_cover_apply` / `finish_cover_job`.
    public func applyCoverArt(_ result: CoverResult) {
        applyCover(from: { try await self.covers.downloadImage(from: result.artworkURL) })
    }

    /// Uses a local image file the user picked as the cover for the playing track.
    public func applyCoverArt(fromFile path: String) {
        applyCover(from: {
            let data = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            guard data.count <= 8 * 1024 * 1024 else { throw CoverError.tooLarge }
            guard ImageKind.sniff(data) != nil else { throw CoverError.notAnImage }
            return data
        })
    }

    /// Clears the playing track's cover, falling back to embedded art.
    public func removeCoverArt() {
        guard selectedIndex >= 0, selectedIndex < playingTracks.count else { return }
        let trackID = playingTracks[selectedIndex].id
        let previous = playingTracks[selectedIndex].cover
        do {
            try library.applyCover(toTrackID: trackID, in: playingPlaylist, coverPath: nil)
            coverStore.removeIfOwned(previous)
            reloadViewed()
            coverPath = nil
            refreshNowPlayingArtwork(userCover: nil)
            coverStatus = "Cover removed."
        } catch {
            coverStatus = "Could not remove the cover: \(describe(error))"
        }
    }

    private func applyCover(from fetch: @escaping @Sendable () async throws -> Data) {
        guard selectedIndex >= 0, selectedIndex < playingTracks.count else {
            coverStatus = "Nothing is playing."
            return
        }
        let playlist = playingPlaylist
        let trackID = playingTracks[selectedIndex].id
        let previous = playingTracks[selectedIndex].cover

        coverTask?.cancel()
        isCoverBusy = true
        coverStatus = "Fetching cover…"
        coverTask = Task { [weak self] in
            guard let self else { return }
            defer { isCoverBusy = false }
            do {
                let data = try await fetch()
                if Task.isCancelled { return }
                let stored = try coverStore.store(data)
                do {
                    try library.applyCover(toTrackID: trackID, in: playlist, coverPath: stored.path)
                } catch {
                    coverStore.removeIfOwned(stored.path)
                    throw error
                }
                if previous != stored.path { coverStore.removeIfOwned(previous) }
                reloadViewed()
                if playlist == playingPlaylist, selectedIndex >= 0,
                   selectedIndex < playingTracks.count, playingTracks[selectedIndex].id == trackID {
                    coverPath = stored.path
                }
                coverResults = []
                coverStatus = "Cover updated."
            } catch {
                if Task.isCancelled { return }
                coverStatus = "Could not set the cover: \(describe(error))"
            }
        }
    }

    /// Pulls embedded art out of the playing file into a scratch image and shows
    /// it — unless a user-chosen cover is already in place. Display-only: it is
    /// never written to the library (mirrors `extract_source_cover`).
    private func refreshNowPlayingArtwork(userCover: String?) {
        artworkTask?.cancel()
        guard userCover == nil, let url = playingURL else { return }
        let reader = metadata
        artworkTask = Task { [weak self] in
            let extracted = await reader.read(url)
            guard let self, !Task.isCancelled, self.playingURL == url,
                  let data = extracted.artwork, let kind = ImageKind.sniff(data) else { return }
            let dest = Paths.nowPlayingArtwork.appendingPathComponent("current.\(kind.fileExtension)")
            try? FileManager.default.createDirectory(at: Paths.nowPlayingArtwork, withIntermediateDirectories: true)
            do { try AtomicFile.write(data, to: dest) } catch { return }
            if self.coverPath == nil { self.coverPath = dest.path }
        }
    }

    /// Reads tags and embedded art off the just-started track's local file and,
    /// for a track whose row is still a scan placeholder, writes the real
    /// artist / album / cover back into the library and the now-playing panel.
    /// The C backend probed every file over ssh during a scan; this port stages
    /// fast and fills the gaps the first time a track actually plays.
    private func backfillNowPlaying(track: Track, index: Int) {
        guard let url = playingURL else { return }
        let wantArtist = MetadataPlaceholder.isUnset(track.artist, matching: MetadataPlaceholder.artist)
        let wantAlbum = MetadataPlaceholder.isUnset(track.album, matching: MetadataPlaceholder.album)
        let wantCover = track.cover == nil
        guard wantArtist || wantAlbum || wantCover else { return }

        let keys = Set(track.sources.map(\.dedupKey))
        guard !keys.isEmpty else { return }
        let trackID = track.id
        let reader = metadata

        backfillTask?.cancel()
        backfillTask = Task { [weak self] in
            let tags = await reader.read(url)
            guard let self, !Task.isCancelled, self.playingURL == url else { return }

            let newArtist = wantArtist && hasRealText(tags.artist) ? tags.artist : nil
            let newAlbum = wantAlbum && hasRealText(tags.album) ? tags.album : nil
            var newCover: String?
            if wantCover, let art = tags.artwork, ImageKind.sniff(art) != nil {
                newCover = try? self.coverStore.store(art).path
            }
            guard newArtist != nil || newAlbum != nil || newCover != nil else { return }

            let wrote: (artist: Bool, album: Bool, cover: Bool)
            do {
                wrote = try self.library.backfillMetadata(forSourceKeys: keys,
                                                          artist: newArtist, album: newAlbum,
                                                          cover: newCover)
            } catch {
                if let newCover { self.coverStore.removeIfOwned(newCover) }
                return
            }
            if let newCover, !wrote.cover { self.coverStore.removeIfOwned(newCover) }
            guard wrote.artist || wrote.album || wrote.cover else { return }

            self.reloadViewed()
            guard self.selectedIndex == index, index < self.playingTracks.count,
                  self.playingTracks[index].id == trackID else { return }
            if wrote.artist, let newArtist { self.artist = newArtist }
            if wrote.album, let newAlbum { self.album = newAlbum }
            if wrote.cover, let newCover, self.coverPath == nil { self.coverPath = newCover }
        }
    }

    // MARK: On-view metadata probe

    private struct ProbeJob: Sendable {
        let sources: [Source]   // the ssh / network sources of one track
        let wantCover: Bool
    }

    /// For every viewed row that is still a scan placeholder and has a remote
    /// source, fetch just the front of the file over `ssh` and fill in its real
    /// artist / album (and cover, if it rode along in the prefix). Runs a few at
    /// a time in the background and is replaced whenever the view changes, so
    /// opening a freshly scanned playlist populates it without playing a note.
    private func probeViewedPlaylist() {
        let jobs = viewedTracks.compactMap { track -> ProbeJob? in
            let remote = track.sources.filter { $0.kind == .ssh || $0.kind == .network }
            guard !remote.isEmpty,
                  MetadataPlaceholder.isUnset(track.artist, matching: MetadataPlaceholder.artist)
                    || MetadataPlaceholder.isUnset(track.album, matching: MetadataPlaceholder.album)
            else { return nil }
            return ProbeJob(sources: remote, wantCover: track.cover == nil)
        }
        guard !jobs.isEmpty else { return }
        let prober = self.prober

        probeTask?.cancel()
        probeTask = Task { [weak self] in
            var wroteAny = false
            await withTaskGroup(of: (ProbeJob, ExtractedMetadata)?.self) { group in
                let maxConcurrent = 4
                var next = jobs.makeIterator()
                func pump() { if let job = next.next() { group.addTask { await Self.runProbe(job, prober: prober) } } }
                for _ in 0..<maxConcurrent { pump() }
                while let result = await group.next() {
                    pump()
                    guard let self, !Task.isCancelled else { continue }
                    if let (job, meta) = result, self.applyProbe(job, meta) {
                        wroteAny = true
                        self.reloadViewed()   // let rows fill in as each probe lands
                    }
                }
            }
            guard let self, !Task.isCancelled else { return }
            if wroteAny { try? self.library.rebuildStar() }
            self.reloadViewed()
        }
    }

    private static func runProbe(_ job: ProbeJob, prober: MetadataProbing) async -> (ProbeJob, ExtractedMetadata)? {
        for source in job.sources {
            let meta = await prober.probe(source)
            if hasRealText(meta.artist) || hasRealText(meta.album) || meta.artwork != nil {
                return (job, meta)
            }
            if Task.isCancelled { break }
        }
        return nil
    }

    /// Writes one probed track's new fields into every playlist that holds it.
    /// `backfillMetadata` only touches rows still at a placeholder, so a value
    /// filled by a concurrent play-time backfill is never clobbered.
    private func applyProbe(_ job: ProbeJob, _ meta: ExtractedMetadata) -> Bool {
        let keys = Set(job.sources.map(\.dedupKey))
        let artist = hasRealText(meta.artist) ? meta.artist : nil
        let album = hasRealText(meta.album) ? meta.album : nil
        var cover: String?
        if job.wantCover, let art = meta.artwork, ImageKind.sniff(art) != nil {
            cover = try? coverStore.store(art).path
        }
        guard artist != nil || album != nil || cover != nil else { return false }

        let wrote: (artist: Bool, album: Bool, cover: Bool)
        do {
            wrote = try library.backfillMetadata(forSourceKeys: keys, artist: artist, album: album,
                                                 cover: cover, rebuildStarAfter: false)
        } catch {
            if let cover { coverStore.removeIfOwned(cover) }
            return false
        }
        if let cover, !wrote.cover { coverStore.removeIfOwned(cover) }

        if selectedIndex >= 0, selectedIndex < playingTracks.count,
           playingTracks[selectedIndex].sources.contains(where: { keys.contains($0.dedupKey) }) {
            if wrote.artist, let artist { self.artist = artist }
            if wrote.album, let album { self.album = album }
            if wrote.cover, let cover, coverPath == nil { coverPath = cover }
        }
        return wrote.artist || wrote.album || wrote.cover
    }

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
                self.playingURL = url
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
        let pos = index + 1
        title = TrackTitle.display(track, position: pos, number: .suffix)
        nowPlayingTitle = TrackTitle.display(track, position: pos, number: .omit)
        currentTrackLabel = TrackTitle.numberLabel(track, position: pos)
        artist = track.artist.isEmpty ? "No Artist" : track.artist
        album = track.album.isEmpty ? "No Album" : track.album
        coverPath = resolvedCoverPath(for: track)
        refreshNowPlayingArtwork(userCover: coverPath)
        backfillNowPlaying(track: track, index: index)
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
        case let e as CoverError:
            switch e {
            case .badQuery: return "invalid request"
            case .network(let m): return m
            case .notAnImage: return "that file is not a JPEG or PNG"
            case .tooLarge: return "that image is too large (8 MB max)"
            }
        case let e as DirectoryScanner.ScanError:
            switch e {
            case .invalidIdentity: return "invalid username or host"
            case .transport(let m): return m
            }
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
