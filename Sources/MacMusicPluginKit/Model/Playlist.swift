import Foundation

/// The on-disk shape of a playlist file: `{ "version": 1, "tracks": [...] }`.
public struct PlaylistFile: Codable, Equatable, Sendable {
    public var version: Int
    public var tracks: [Track]

    public init(version: Int = 1, tracks: [Track] = []) {
        self.version = version
        self.tracks = tracks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
    }

    private enum CodingKeys: String, CodingKey { case version, tracks }
}

/// A playlist loaded into memory: its stem (file name without `.json`) and tracks.
public struct Playlist: Equatable, Identifiable, Sendable {
    public var name: String
    public var tracks: [Track]

    public var id: String { name }

    public init(name: String, tracks: [Track] = []) {
        self.name = name
        self.tracks = tracks
    }

    /// How the tab strip shortens `INCOMING >> foo <<` to `+ foo`.
    public var displayName: String {
        if let target = PlaylistName.incomingTarget(of: name) { return "+ \(target)" }
        return name
    }

    public var isIncoming: Bool { PlaylistName.incomingTarget(of: name) != nil }
    public var isStar: Bool { name == PlaylistName.star }
}
