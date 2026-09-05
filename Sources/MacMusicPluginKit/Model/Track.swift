import Foundation

/// A library entry: display metadata plus one or more `Source`s to fetch it
/// from. Mirrors `LibraryTrack` (backend/library_handler.h:31).
///
/// `id` is optional on disk (the Omarchy backend never writes one). When a file
/// is loaded without ids, the store synthesises stable ones and persists them on
/// the next save, so SwiftUI list identity survives reordering and edits.
public struct Track: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    /// Absolute path to a user-chosen cover image; nil means "use embedded art".
    public var cover: String?
    public var sources: [Source]

    public init(id: String = UUID().uuidString,
                title: String,
                artist: String,
                album: String,
                cover: String? = nil,
                sources: [Source] = []) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.cover = cover
        self.sources = sources
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, album, cover, sources
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover)
        sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encode(album, forKey: .album)
        if let cover { try c.encode(cover, forKey: .cover) }
        try c.encode(sources, forKey: .sources)
    }

    /// The first source that has everything its kind needs.
    public var firstUsableSource: Source? {
        sources.first { $0.isComplete }
    }
}
