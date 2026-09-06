import Foundation

/// Display-time cleanup for track titles. Files in the wild bury the real title
/// under a leading track number and a repeat of the artist name
/// (`01 Radiohead - Lewis (Mistreated)`). This never touches stored metadata —
/// it is applied as rows are drawn.
public enum TrackTitle {
    /// Where the track number sits relative to the cleaned title.
    public enum Number {
        /// `01 Lewis (Mistreated)` — for the library list.
        case prefix
        /// `Lewis (Mistreated) (01)` — for the menu-bar label.
        case suffix
        /// `Lewis (Mistreated)` — number dropped (the player header carries it
        /// in the album line instead).
        case omit
    }

    /// `track.title` with a leading track number and a leading artist name
    /// stripped, and the track number re-attached per `number`.
    public static func display(_ track: Track, position: Int, number: Number = .suffix) -> String {
        let (title, n) = parse(track, position: position)
        guard let n else { return title }
        let nn = String(format: "%02d", n)
        switch number {
        case .prefix: return "\(nn) \(title)"
        case .suffix: return "\(title) (\(nn))"
        case .omit:   return title
        }
    }

    /// The two-digit track number for this track — its own leading digits when
    /// present, else `position`. Empty when neither is usable.
    public static func numberLabel(_ track: Track, position: Int) -> String {
        guard let n = parse(track, position: position).number else { return "" }
        return String(format: "%02d", n)
    }

    /// (cleaned title, track number). The number comes from the title's own
    /// leading digits when it has them; otherwise `position` (the track's 1-based
    /// place in the playlist), or nil when that is not positive.
    static func parse(_ track: Track, position: Int) -> (title: String, number: Int?) {
        var rest = track.title.trimmingCharacters(in: .whitespaces)
        var number: Int?

        if let m = rest.range(of: #"^(\d{1,3})[ ._-]+"#, options: .regularExpression) {
            number = Int(rest[m].trimmingCharacters(in: CharacterSet(charactersIn: " ._-")))
            rest = String(rest[m.upperBound...])
        }

        let artist = track.artist.trimmingCharacters(in: .whitespaces)
        if !artist.isEmpty, rest.lowercased().hasPrefix(artist.lowercased()) {
            let stripped = String(rest.dropFirst(artist.count))
                .replacingOccurrences(of: #"^\s*[-–—:]?\s*"#, with: "", options: .regularExpression)
            if !stripped.isEmpty { rest = stripped }
        }

        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { rest = track.title.trimmingCharacters(in: .whitespaces) }

        return (rest, number ?? (position > 0 ? position : nil))
    }
}
