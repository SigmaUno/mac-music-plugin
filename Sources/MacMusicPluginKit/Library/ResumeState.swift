import Foundation

/// Persisted playback position, so a relaunched app picks the song back up.
/// Same file and field names as the Omarchy backend's `.resume.json`
/// (`write_resume` / `read_resume`, backend/app.c:680), so the two can share a
/// library directory.
public struct ResumeState: Codable, Equatable, Sendable {
    public var playlist: String
    public var trackIndex: Int
    public var positionMs: Int
    public var isPlaying: Bool

    public init(playlist: String, trackIndex: Int, positionMs: Int, isPlaying: Bool) {
        self.playlist = playlist
        self.trackIndex = trackIndex
        self.positionMs = positionMs
        self.isPlaying = isPlaying
    }

    private enum CodingKeys: String, CodingKey {
        case playlist
        case trackIndex = "track_index"
        case positionMs = "position_ms"
        case isPlaying = "is_playing"
    }
}

/// Reads and writes `ResumeState` at a fixed path, throttling writes so a
/// once-per-second position tick does not hammer the disk.
public final class ResumeStore {
    private let url: URL
    private let minWriteInterval: TimeInterval
    private var lastWrite: Date = .distantPast

    public init(url: URL = Paths.resumeFile, minWriteInterval: TimeInterval = 3) {
        self.url = url
        self.minWriteInterval = minWriteInterval
    }

    public func read() -> ResumeState? {
        try? AtomicFile.readJSON(ResumeState.self, from: url)
    }

    /// Writes now if enough time has passed since the last write, or when `force`
    /// is set (track change, pause, quit). A nil `state` clears the file — the
    /// track it named is gone and resuming there would pick up the wrong song.
    public func write(_ state: ResumeState?, force: Bool = false) {
        guard let state else {
            try? FileManager.default.removeItem(at: url)
            lastWrite = .distantPast
            return
        }
        guard force || Date().timeIntervalSince(lastWrite) >= minWriteInterval else { return }
        // A not-yet-loaded track has an unknown position; don't overwrite a good
        // resume point with position 0 (mirrors the `duration_ms == 0` guard).
        try? AtomicFile.writeJSON(state, to: url)
        lastWrite = Date()
    }
}
