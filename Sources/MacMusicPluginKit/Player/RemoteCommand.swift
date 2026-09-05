import Foundation

/// Argument-vector builders for the `curl` and `ssh` subprocesses that fetch
/// remote tracks. Pure and allocation-free of any process state, so the exact
/// command lines are unit-testable without spawning anything.
///
/// Ports the C backend's transport plumbing: `valid_ssh_name` / `ssh_quote` /
/// `remote_cat_command` / `build_ssh_argv` (backend/app.c) and the shared
/// hardening + multiplexing option sets (backend/ssh_opts.c).
public enum RemoteCommand {

    // MARK: SSH / local-network identity validation

    /// Characters allowed in a `USERNAME` or `IP`/host. Mirrors `valid_ssh_name`
    /// (backend/app.c:825): alphanumerics plus `.`, `-`, `_`, and — for the host
    /// only, so IPv6 literals pass — `:`. Anything else (spaces, shell
    /// metacharacters, `/`, `@`) is rejected so a crafted value can never split
    /// into extra `ssh` arguments or a second remote command.
    public static func isValidName(_ value: String?, allowColon: Bool) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return value.allSatisfy { c in
            guard let a = c.asciiValue else { return false }
            let isAlnum = (a >= 48 && a <= 57) || (a >= 65 && a <= 90) || (a >= 97 && a <= 122)
            return isAlnum || c == "." || c == "-" || c == "_" || (allowColon && c == ":")
        }
    }

    /// Single-quotes `value` for a POSIX shell, so the remote shell treats it
    /// literally and it can never inject additional commands. `'` becomes
    /// `'\''`. Mirrors `ssh_quote` / `remote_cat_command` (backend/app.c:857).
    public static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The remote command run over `ssh`: `cat -- '<path>'`. A single argv
    /// element; the local side never interprets it. Mirrors `remote_cat_command`.
    public static func remoteCat(path: String) -> String {
        "cat -- " + singleQuoted(path)
    }

    // MARK: Option sets

    /// Connection-hardening options applied to every `ssh` spawned, so a dead or
    /// filtered host fails in ~5s instead of the multi-minute kernel TCP timeout
    /// and a mid-transfer drop is noticed within ~15s. Mirrors
    /// `SSH_HARDENING_OPTS_ARGV` (backend/ssh_opts.h).
    static let hardeningOptions: [String] = [
        "-o", "BatchMode=yes",
        "-o", "RequestTTY=no",
        "-o", "ClearAllForwardings=yes",
        "-o", "LogLevel=ERROR",
        "-o", "ConnectTimeout=5",
        "-o", "ServerAliveInterval=5",
        "-o", "ServerAliveCountMax=3",
    ]

    /// How long OpenSSH keeps a multiplexed master alive after the last channel
    /// closes, so back-to-back tracks from one host reuse the connection instead
    /// of repeating the TCP + key-exchange + auth handshake. Mirrors
    /// `SSH_CONTROL_PERSIST` (backend/ssh_opts.c).
    static let controlPersistSeconds = 30

    /// `ControlMaster` options pointing at a socket under `controlDirectory`
    /// (`Paths.sshControl`). Empty when `controlDirectory` is nil — the caller
    /// then behaves exactly as an un-multiplexed `ssh`. Mirrors `ssh_opts_init`.
    static func controlOptions(controlDirectory: URL?) -> [String] {
        guard let dir = controlDirectory else { return [] }
        // The socket path (dir + "/cm-" + 64-hex %C hash + NUL) must fit a
        // sockaddr_un (~104 usable bytes); fall back to no multiplexing if not.
        guard dir.path.utf8.count + "/cm-".utf8.count + 64 < 104 else { return [] }
        return [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(dir.path)/cm-%C",
            "-o", "ControlPersist=\(controlPersistSeconds)",
        ]
    }

    // MARK: Full argv

    /// `ssh -F /dev/null <hardening> <control> -- user@host "cat -- '<path>'"`.
    /// `-F /dev/null` ignores the user's `~/.ssh/config` so behaviour does not
    /// drift with unrelated host stanzas. Mirrors `build_ssh_argv`.
    ///
    /// - Returns: nil when `username`/`ip` fail validation.
    public static func sshCat(username: String, ip: String, remotePath: String,
                              controlDirectory: URL? = Paths.sshControl) -> [String]? {
        guard isValidName(username, allowColon: false),
              isValidName(ip, allowColon: true),
              !remotePath.isEmpty else { return nil }
        var argv = ["ssh", "-F", "/dev/null"]
        argv += hardeningOptions
        argv += controlOptions(controlDirectory: controlDirectory)
        argv += ["--", "\(username)@\(ip)", remoteCat(path: remotePath)]
        return argv
    }

    /// `curl` argv that writes the body of `url` to stdout, failing hard on a
    /// non-2xx status, refusing anything but `https://`, and bounding both the
    /// connect and total transfer time. Mirrors `stream_https` (backend/app.c:993).
    ///
    /// - Returns: nil when `url` is not an `https://` URL.
    public static func curl(url: String) -> [String]? {
        guard url.lowercased().hasPrefix("https://") else { return nil }
        return [
            "curl", "--fail", "--location", "--max-redirs", "5",
            "--proto", "=https", "--tlsv1.2",
            "--connect-timeout", "15", "--max-time", "1800",
            "--silent", "--show-error",
            "--output", "-", "--", url,
        ]
    }
}
