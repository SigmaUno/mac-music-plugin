import Foundation

/// Central resolver for every on-disk location the app uses.
///
/// The Omarchy plugin scatters state across `$XDG_DATA_HOME/leecher-media`,
/// `$XDG_RUNTIME_DIR/leecher` and `$XDG_CONFIG_HOME`. On macOS everything lives
/// under one Application Support tree, with volatile bits in a caches/temp dir.
public enum Paths {
    /// `~/Library/Application Support/MacMusicPlugin`
    public static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacMusicPlugin", isDirectory: true)
    }()

    /// Directory holding one `<playlist>.json` per playlist. Mirrors the C
    /// backend's `library/` directory (see `resolve_library_dir`, backend/app.c).
    public static let library: URL = support.appendingPathComponent("library", isDirectory: true)

    /// Persisted playback position, so a relaunch resumes where it left off.
    /// Leading dot keeps it out of the playlist scan.
    public static let resumeFile: URL = library.appendingPathComponent(".resume.json")

    /// User-chosen cover images, kept for the life of the track that references them.
    public static let covers: URL = support.appendingPathComponent("covers", isDirectory: true)

    /// OpenSSH `ControlMaster` sockets for multiplexed remote streaming. Cleared on quit.
    public static let sshControl: URL = support.appendingPathComponent("ssh", isDirectory: true)

    /// `~/Library/Caches/MacMusicPlugin` — downloaded track bodies, extracted art,
    /// anything safe to lose.
    public static let caches: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacMusicPlugin", isDirectory: true)
    }()

    /// Per-run scratch directory for streamed downloads. Removed on quit.
    public static let scratch: URL = caches.appendingPathComponent("scratch", isDirectory: true)

    /// Creates every directory the app writes into. Safe to call repeatedly.
    public static func bootstrap() {
        for dir in [support, library, covers, sshControl, caches, scratch] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Wipes volatile directories. Call on launch and on quit.
    public static func clearVolatile() {
        for dir in [sshControl, scratch] {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
