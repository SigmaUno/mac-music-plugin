import Foundation

/// Fuzzy string comparison used for track lookup and merge decisions. Ported
/// from `string_score` (backend/library_handler.c:216): case-insensitive, with
/// 100 = exact, 70 = value contains query, 50 = query contains value, else 0.
enum MatchScore {
    static func score(_ value: String?, _ query: String?) -> Int {
        guard let query, !query.isEmpty, let value else { return 0 }
        let v = value.lowercased()
        let q = query.lowercased()
        if v == q { return 100 }
        if v.contains(q) { return 70 }
        if q.contains(v) { return 50 }
        return 0
    }

    /// Whether two metadata triples are the "same track" for merge purposes:
    /// exact (case-insensitive) title AND artist AND album. Mirrors the match
    /// test in `library_handler_add_source` (backend/library_handler.c:487).
    static func sameTrack(_ a: (title: String, artist: String, album: String),
                          _ b: (title: String, artist: String, album: String)) -> Bool {
        score(a.title, b.title) == 100
            && score(a.artist, b.artist) == 100
            && score(a.album, b.album) == 100
    }
}
