import Foundation

/// Rules for playlist file names. A stem doubles as a filename component, so the
/// character set is deliberately tight. Mirrors `valid_playlist_name`,
/// `playlist_rank`, and the `INCOMING >>`/`<<` helpers in backend/app.c.
public enum PlaylistName {
    /// The reserved auto-collect playlist. Every source added anywhere is also
    /// appended here; it is rebuilt from the other playlists when viewed.
    public static let star = "*"

    /// The default playlist, seeded on first run.
    public static let home = "home"

    static let incomingPrefix = "INCOMING >> "
    static let incomingSuffix = " <<"

    /// 1–64 chars of `[A-Za-z0-9 _-]`, no leading or trailing space. Rules out
    /// `/`, `.`, `..` so a name can never escape the library directory. `*` is
    /// reserved and never passes here. Mirrors `valid_playlist_name`
    /// (backend/app.c:531).
    public static func isValid(_ name: String) -> Bool {
        let n = name.count
        guard n >= 1, n <= 64 else { return false }
        guard name.first != " ", name.last != " " else { return false }
        return name.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == " " || c == "_" || c == "-")
        }
    }

    /// The staging-playlist stem a directory scan into `target` writes to.
    public static func incomingName(for target: String) -> String {
        incomingPrefix + String(target.prefix(64)) + incomingSuffix
    }

    /// If `name` is a staging playlist, the validated target it feeds; else nil.
    /// Mirrors `incoming_target_of` (backend/app.c:502), including the rejection
    /// of a target that would not itself be a valid playlist name.
    public static func incomingTarget(of name: String) -> String? {
        guard name.hasPrefix(incomingPrefix), name.hasSuffix(incomingSuffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: incomingPrefix.count)
        let end = name.index(name.endIndex, offsetBy: -incomingSuffix.count)
        guard start < end else { return nil }
        let target = String(name[start..<end])
        return isValid(target) ? target : nil
    }

    /// Tab-strip ordering: `home`, then regular playlists, then staging lists,
    /// then `*`; ties broken case-insensitively. Mirrors `playlist_rank` /
    /// `playlist_cmp` (backend/app.c:557).
    public static func rank(_ name: String) -> Int {
        if name == home { return 0 }
        if name == star { return 3 }
        if incomingTarget(of: name) != nil { return 2 }
        return 1
    }

    public static func sorted(_ names: [String]) -> [String] {
        names.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }
}
