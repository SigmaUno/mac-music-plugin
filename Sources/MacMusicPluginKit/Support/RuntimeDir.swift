import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// A short, private, per-user runtime directory for paths that must sit near the
/// filesystem root — chiefly the OpenSSH `ControlPath` socket, whose full path
/// has to fit a `sockaddr_un` (~104 usable bytes). `~/Library/Application
/// Support/MacMusicPlugin/ssh` is far too long, so this mirrors the C backend's
/// `/tmp/leecher-<uid>` fallback (`init_ipc_dir`, backend/app.c:211), including
/// the ownership check that refuses a pre-existing directory owned by anyone
/// else (or a symlink).
public enum RuntimeDir {
    /// `/tmp/mmp-<uid>` (0700, owned by us), or a `mkdtemp` fallback when that
    /// path is already taken by something we do not own.
    public static let base: URL = resolve()

    /// `<base>/ssh` — OpenSSH ControlMaster sockets. Swept by `clean()`.
    public static let ssh: URL = {
        let url = base.appendingPathComponent("ssh", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url
    }()

    public static func clean() {
        try? FileManager.default.removeItem(at: ssh)
        try? FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    private static func resolve() -> URL {
        let uid = getuid()
        let fm = FileManager.default
        let preferred = URL(fileURLWithPath: "/tmp/mmp-\(uid)", isDirectory: true)

        if !fm.fileExists(atPath: preferred.path) {
            try? fm.createDirectory(at: preferred, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        }
        if isPrivateDirectory(preferred.path, uid: uid) { return preferred }

        let template = strdup("/tmp/mmp-\(uid)-XXXXXX")!
        defer { free(template) }
        if let made = mkdtemp(template) {
            return URL(fileURLWithPath: String(cString: made), isDirectory: true)
        }
        return preferred
    }

    private static func isPrivateDirectory(_ path: String, uid: uid_t) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return false }   // not a symlink
        guard st.st_uid == uid else { return false }
        return (st.st_mode & 0o077) == 0
    }
}
