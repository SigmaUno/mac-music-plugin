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
    /// stripped, and the track number re-attached per `number`. When the title
    /// carries no leading track number nothing is added — the track's place in
    /// the playlist is never substituted for a missing number.
    public static func display(_ track: Track, number: Number = .suffix) -> String {
        let (title, n) = parse(track)
        guard let n else { return title }
        let nn = String(format: "%02d", n)
        switch number {
        case .prefix: return "\(nn) \(title)"
        case .suffix: return "\(title) (\(nn))"
        case .omit:   return title
        }
    }

    /// The two-digit track number from the title's own leading digits, or ""
    /// when it has none.
    public static func numberLabel(_ track: Track) -> String {
        guard let n = parse(track).number else { return "" }
        return String(format: "%02d", n)
    }

    /// (cleaned title, track number). The number comes from the title's own
    /// leading digits; nil when it has none.
    static func parse(_ track: Track) -> (title: String, number: Int?) {
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

        return (rest, number)
    }
}
