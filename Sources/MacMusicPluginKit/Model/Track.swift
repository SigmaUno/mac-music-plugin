import CryptoKit
import Foundation

/// A library entry: display metadata plus one or more `Source`s to fetch it
/// from. Mirrors `LibraryTrack` (backend/library_handler.h:31).
///
/// `id` is optional on disk (the Omarchy backend never writes one). A file
/// loaded without ids gets a **deterministic** id derived from its content, so
/// reloading the same playlist (which the panel does often) yields the same ids
/// and SwiftUI list identity stays stable — a fresh `UUID()` each load made a
/// 190-row scan result churn its whole `ForEach` on every refresh.
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
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover)
        sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? []
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? Track.deterministicID(title: title, artist: artist, album: album, sources: sources)
    }

    /// A stable id for an id-less on-disk track: a hash of its content, so the
    /// same playlist file always decodes to the same ids.
    static func deterministicID(title: String, artist: String, album: String, sources: [Source]) -> String {
        let material = ([title, artist, album] + sources.map(\.dedupKey)).joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return "t-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
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
