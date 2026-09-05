import Foundation

public enum LibraryError: Error, Equatable {
    case invalidPlaylistName(String)
    case playlistNotFound(String)
    case playlistExists(String)
    case reservedPlaylist(String)
    case incompleteSource
    case missingMetadata
    case trackNotFound(String)
    case notAnIncomingPlaylist(String)
}

/// Display metadata for a new library entry. `title`, `artist` and `album` must
/// be non-empty — the caller (metadata import) fills placeholders like
/// "Unknown artist" when tags are absent, mirroring `build_song_query_for`
/// (backend/app.c:1308).
public struct TrackMetadata: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var cover: String?

    public init(title: String, artist: String, album: String, cover: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.cover = cover
    }
}

public enum AddOutcome: Equatable {
    case merged(trackID: String)
    case created(trackID: String)
}

/// Owns the playlist directory: one `<stem>.json` file per playlist, in the same
/// schema the Omarchy backend uses. A full rewrite of that backend's library
/// layer (`library_handler.c` + the playlist helpers in `app.c`), not an FFI
/// binding.
///
/// Note: unlike the C string-splicing writer, this decodes to `PlaylistFile` and
/// re-encodes on save, so JSON keys the model does not know about are not
/// preserved. The schema is small and fully modelled, so this only matters for
/// hand-added experimental fields.
public final class LibraryStore {
    public let directory: URL
    private let fm = FileManager.default

    public init(directory: URL = Paths.library) {
        self.directory = directory
    }

    // MARK: Bootstrap

    private static let emptyPlaylist = PlaylistFile(version: 1, tracks: [])

    /// Creates the directory, migrates a legacy single `library.json`, seeds
    /// `home.json` when the directory holds no playlist, and ensures `*` exists.
    /// Mirrors `resolve_library_dir` (backend/app.c:630).
    public func bootstrap() throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let legacy = directory.deletingLastPathComponent().appendingPathComponent("library.json")
        let hasAnyPlaylist = !scanStems().isEmpty

        if !hasAnyPlaylist {
            let home = fileURL(for: PlaylistName.home)
            if !fm.fileExists(atPath: home.path) {
                if fm.fileExists(atPath: legacy.path),
                   let data = try? Data(contentsOf: legacy) {
                    try AtomicFile.write(data, to: home)
                } else {
                    try AtomicFile.writeJSON(Self.emptyPlaylist, to: home)
                }
            }
        }

        let star = fileURL(for: PlaylistName.star)
        if !fm.fileExists(atPath: star.path) {
            try AtomicFile.writeJSON(Self.emptyPlaylist, to: star)
        }
    }

    // MARK: Enumeration

    /// Playlist stems present on disk, ordered for the tab strip. Dotfiles (so
    /// `.resume.json`) are skipped. Mirrors `scan_playlists` (backend/app.c:590).
    public func playlistNames() -> [String] {
        PlaylistName.sorted(scanStems())
    }

    private func scanStems() -> [String] {
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return entries.compactMap { name in
            guard !name.hasPrefix("."), name.hasSuffix(".json") else { return nil }
            return String(name.dropLast(".json".count))
        }
    }

    public func playlistExists(_ name: String) -> Bool {
        fm.fileExists(atPath: fileURL(for: name).path)
    }

    private func fileURL(for stem: String) -> URL {
        directory.appendingPathComponent("\(stem).json")
    }

    // MARK: Load / save

    public func load(_ name: String) throws -> Playlist {
        let url = fileURL(for: name)
        guard fm.fileExists(atPath: url.path) else { throw LibraryError.playlistNotFound(name) }
        let file = try AtomicFile.readJSON(PlaylistFile.self, from: url)
        return Playlist(name: name, tracks: file.tracks)
    }

    public func save(_ playlist: Playlist) throws {
        try AtomicFile.writeJSON(PlaylistFile(version: 1, tracks: playlist.tracks),
                                 to: fileURL(for: playlist.name))
    }

    // MARK: Mutations

    /// Creates an empty user playlist. `*` is reserved; staging names are
    /// created only by the scanner. Mirrors `create_playlist` (backend/app.c:3217).
    @discardableResult
    public func createPlaylist(_ name: String) throws -> Playlist {
        guard name != PlaylistName.star else { throw LibraryError.reservedPlaylist(name) }
        guard PlaylistName.isValid(name) else { throw LibraryError.invalidPlaylistName(name) }
        guard !playlistExists(name) else { throw LibraryError.playlistExists(name) }
        try AtomicFile.writeJSON(Self.emptyPlaylist, to: fileURL(for: name))
        return Playlist(name: name, tracks: [])
    }

    /// Appends `source` to a track in `name` whose title+artist+album match
    /// exactly (case-insensitively), or creates a new track. Mirrors
    /// `library_handler_add_source` (backend/library_handler.c:468).
    @discardableResult
    public func addSource(_ source: Source, metadata: TrackMetadata,
                          toPlaylist name: String) throws -> AddOutcome {
        guard source.isComplete else { throw LibraryError.incompleteSource }
        guard !metadata.title.isEmpty, !metadata.artist.isEmpty, !metadata.album.isEmpty else {
            throw LibraryError.missingMetadata
        }
        var playlist = (try? load(name)) ?? Playlist(name: name)

        if let idx = playlist.tracks.firstIndex(where: {
            MatchScore.sameTrack(($0.title, $0.artist, $0.album),
                                 (metadata.title, metadata.artist, metadata.album))
        }) {
            playlist.tracks[idx].sources.append(source)
            let id = playlist.tracks[idx].id
            try save(playlist)
            return .merged(trackID: id)
        }

        let track = Track(title: metadata.title, artist: metadata.artist,
                          album: metadata.album, cover: metadata.cover, sources: [source])
        playlist.tracks.append(track)
        try save(playlist)
        return .created(trackID: track.id)
    }

    /// Updates display fields of a track. A nil argument leaves that field alone.
    /// Mirrors `library_handler_update_track` (backend/library_handler.c:543).
    public func updateTrack(id: String, in name: String,
                            title: String? = nil, artist: String? = nil,
                            album: String? = nil, cover: String?? = nil) throws {
        var playlist = try load(name)
        guard let idx = playlist.tracks.firstIndex(where: { $0.id == id }) else {
            throw LibraryError.trackNotFound(id)
        }
        if let title { playlist.tracks[idx].title = title }
        if let artist { playlist.tracks[idx].artist = artist }
        if let album { playlist.tracks[idx].album = album }
        if let cover { playlist.tracks[idx].cover = cover }  // double optional: .some(nil) clears
        try save(playlist)
    }

    public func removeTrack(id: String, from name: String) throws {
        var playlist = try load(name)
        guard playlist.tracks.contains(where: { $0.id == id }) else {
            throw LibraryError.trackNotFound(id)
        }
        playlist.tracks.removeAll { $0.id == id }
        try save(playlist)
    }

    /// Sets (or, with `coverPath == nil`, clears) a track's cover image.
    ///
    /// On a normal playlist this is one `updateTrack` write. `*` is different:
    /// `rebuildStar` regenerates it from the other playlists, so a cover written
    /// only there is lost on the next rebuild. When `name` is `*`, the cover is
    /// pushed instead to every non-staging playlist that holds one of this
    /// track's sources, and `*` is rebuilt so the change surfaces there too.
    /// Mirrors `apply_cover_to_origins` (backend/app.c:3528).
    public func applyCover(toTrackID id: String, in name: String, coverPath: String?) throws {
        guard name == PlaylistName.star else {
            try updateTrack(id: id, in: name, cover: .some(coverPath))
            return
        }

        let star = try load(PlaylistName.star)
        guard let track = star.tracks.first(where: { $0.id == id }) else {
            throw LibraryError.trackNotFound(id)
        }
        let keys = Set(track.sources.map(\.dedupKey))

        for stem in scanStems() where stem != PlaylistName.star {
            if PlaylistName.incomingTarget(of: stem) != nil { continue }
            guard var playlist = try? load(stem) else { continue }
            var touched = false
            for idx in playlist.tracks.indices
            where playlist.tracks[idx].sources.contains(where: { keys.contains($0.dedupKey) }) {
                playlist.tracks[idx].cover = coverPath
                touched = true
            }
            if touched { try save(playlist) }
        }
        try rebuildStar()
    }

    /// Fills a track's `artist` / `album` / `cover` in every non-staging
    /// playlist that holds one of the given sources, but only where the field
    /// is still unset — blank, or the "Unknown …" placeholder a scan writes.
    /// A real value (tags imported at add time, or a user's edit) is never
    /// overwritten. `*` is rebuilt so the change surfaces there too.
    ///
    /// Remote sources are staged by file name only — a scan does not probe
    /// every file — so this is how the engine backfills real tags the first
    /// time such a track plays and its bytes are on disk. Matching is by
    /// `Source.dedupKey`, like `applyCover`, so one play updates the track
    /// wherever it appears.
    ///
    /// - Returns: which of the three fields were written somewhere.
    @discardableResult
    public func backfillMetadata(forSourceKeys keys: Set<String>,
                                 artist: String?, album: String?, cover: String?,
                                 rebuildStarAfter: Bool = true)
        throws -> (artist: Bool, album: Bool, cover: Bool) {
        guard !keys.isEmpty, artist != nil || album != nil || cover != nil else {
            return (false, false, false)
        }
        var wroteArtist = false, wroteAlbum = false, wroteCover = false

        for stem in scanStems() where stem != PlaylistName.star {
            if PlaylistName.incomingTarget(of: stem) != nil { continue }
            guard var playlist = try? load(stem) else { continue }
            var touched = false
            for idx in playlist.tracks.indices
            where playlist.tracks[idx].sources.contains(where: { keys.contains($0.dedupKey) }) {
                if let artist,
                   MetadataPlaceholder.isUnset(playlist.tracks[idx].artist, matching: MetadataPlaceholder.artist) {
                    playlist.tracks[idx].artist = artist; wroteArtist = true; touched = true
                }
                if let album,
                   MetadataPlaceholder.isUnset(playlist.tracks[idx].album, matching: MetadataPlaceholder.album) {
                    playlist.tracks[idx].album = album; wroteAlbum = true; touched = true
                }
                if let cover, playlist.tracks[idx].cover == nil {
                    playlist.tracks[idx].cover = cover; wroteCover = true; touched = true
                }
            }
            if touched { try save(playlist) }
        }

        if rebuildStarAfter, wroteArtist || wroteAlbum || wroteCover { try rebuildStar() }
        return (wroteArtist, wroteAlbum, wroteCover)
    }

    // MARK: Resolve

    /// Best fuzzy metadata match in `name`, or nil. Mirrors
    /// `library_handler_resolve` (backend/library_handler.c:357).
    public func resolve(title: String?, artist: String?, album: String?,
                        in name: String) -> Track? {
        guard let playlist = try? load(name) else { return nil }
        var best: Track?
        var bestScore = 0
        for track in playlist.tracks {
            let score = MatchScore.score(track.title, title)
                + MatchScore.score(track.artist, artist)
                + MatchScore.score(track.album, album)
            if score > bestScore {
                bestScore = score
                best = track
            }
        }
        return best
    }

    // MARK: `*` auto-collect

    /// Rebuilds `*` from the union of every non-staging playlist's sources,
    /// de-duplicated by `Source.dedupKey`, carrying each source's owning track
    /// metadata and cover. Lazy: call on startup and when `*` is viewed. Mirrors
    /// `rebuild_star_playlist` (backend/app.c:1353).
    public func rebuildStar() throws {
        var seen = Set<String>()
        var tracks: [Track] = []

        for stem in scanStems() where stem != PlaylistName.star {
            if PlaylistName.incomingTarget(of: stem) != nil { continue }
            guard let playlist = try? load(stem) else { continue }
            for track in playlist.tracks {
                for source in track.sources where seen.insert(source.dedupKey).inserted {
                    if let idx = tracks.firstIndex(where: {
                        MatchScore.sameTrack(($0.title, $0.artist, $0.album),
                                             (track.title, track.artist, track.album))
                    }) {
                        tracks[idx].sources.append(source)
                    } else {
                        tracks.append(Track(title: track.title, artist: track.artist,
                                            album: track.album, cover: track.cover,
                                            sources: [source]))
                    }
                }
            }
        }

        try AtomicFile.writeJSON(PlaylistFile(version: 1, tracks: tracks),
                                 to: fileURL(for: PlaylistName.star))
    }

    // MARK: Directory-scan staging

    /// Writes (replacing) the `INCOMING >> <target> <<` staging playlist a
    /// directory scan produces. Mirrors the staging-file write in `scan_worker`
    /// (backend/app.c:3301).
    public func writeStaging(target: String, tracks: [Track]) throws {
        guard PlaylistName.isValid(target) else { throw LibraryError.invalidPlaylistName(target) }
        try AtomicFile.writeJSON(PlaylistFile(version: 1, tracks: tracks),
                                 to: fileURL(for: PlaylistName.incomingName(for: target)))
    }

    /// Moves the named tracks from a `INCOMING >> target <<` playlist into
    /// `target`, then drops them from staging (deleting the file when it empties).
    /// Mirrors the accept branch of `handle_accept_decline` (backend/app.c:3645).
    public func acceptIncoming(trackIDs: [String], from incomingName: String) throws {
        guard let target = PlaylistName.incomingTarget(of: incomingName) else {
            throw LibraryError.notAnIncomingPlaylist(incomingName)
        }
        var staging = try load(incomingName)
        let moving = staging.tracks.filter { trackIDs.contains($0.id) }
        guard !moving.isEmpty else { return }

        var destination = (try? load(target)) ?? Playlist(name: target)
        for track in moving {
            if let idx = destination.tracks.firstIndex(where: {
                MatchScore.sameTrack(($0.title, $0.artist, $0.album),
                                     (track.title, track.artist, track.album))
            }) {
                for source in track.sources where !destination.tracks[idx].sources.contains(source) {
                    destination.tracks[idx].sources.append(source)
                }
            } else {
                destination.tracks.append(track)
            }
        }
        try save(destination)

        staging.tracks.removeAll { trackIDs.contains($0.id) }
        try finishStaging(staging)
    }

    /// Drops the named tracks from a staging playlist without moving them.
    public func declineIncoming(trackIDs: [String], from incomingName: String) throws {
        guard PlaylistName.incomingTarget(of: incomingName) != nil else {
            throw LibraryError.notAnIncomingPlaylist(incomingName)
        }
        var staging = try load(incomingName)
        staging.tracks.removeAll { trackIDs.contains($0.id) }
        try finishStaging(staging)
    }

    private func finishStaging(_ staging: Playlist) throws {
        if staging.tracks.isEmpty {
            try? fm.removeItem(at: fileURL(for: staging.name))
        } else {
            try save(staging)
        }
    }
}
