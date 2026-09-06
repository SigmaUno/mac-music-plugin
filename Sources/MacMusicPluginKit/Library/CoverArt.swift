import Foundation

/// The image formats we are willing to store as a cover — sniffed from the
/// leading bytes, never trusted from a file name or a Content-Type. Mirrors
/// `image_extension` (backend/app.c).
public enum ImageKind: Equatable, Sendable {
    case jpeg
    case png

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        }
    }

    public static func sniff(_ data: Data) -> ImageKind? {
        if data.count >= 3, data[data.startIndex] == 0xFF,
           data[data.index(data.startIndex, offsetBy: 1)] == 0xD8,
           data[data.index(data.startIndex, offsetBy: 2)] == 0xFF {
            return .jpeg
        }
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if data.count >= 8, Array(data.prefix(8)) == pngMagic { return .png }
        return nil
    }
}

/// One candidate from the iTunes Search API. `artworkURL` has already been
/// upscaled from the 100×100 thumbnail iTunes returns.
public struct CoverResult: Equatable, Sendable, Identifiable {
    public var artworkURL: String
    public var title: String
    public var artist: String
    public var album: String

    public var id: String { artworkURL }

    public init(artworkURL: String, title: String, artist: String, album: String) {
        self.artworkURL = artworkURL
        self.title = title
        self.artist = artist
        self.album = album
    }
}

/// iTunes hands back a `.../100x100bb.jpg` thumbnail; the same path serves any
/// size, so swap the last `100x100` segment for `600x600`. Mirrors
/// `upscale_artwork` (backend/app.c).
public func upscaleArtworkURL(_ url: String) -> String {
    guard let range = url.range(of: "100x100", options: .backwards) else { return url }
    return url.replacingCharacters(in: range, with: "600x600")
}

/// Looks up candidate artwork and downloads a chosen image. A protocol so the
/// engine's cover flow is testable without hitting the network.
public protocol CoverService: Sendable {
    /// Queries the iTunes Search API. Anonymous — no key, no account.
    func search(term: String) async throws -> [CoverResult]
    /// Fetches the bytes at an `https://` artwork URL.
    func downloadImage(from url: String) async throws -> Data
}

public enum CoverError: Error, Equatable {
    case badQuery
    case network(String)
    case notAnImage
    case tooLarge
}

/// `URLSession`-backed `CoverService`. Replaces the C backend's `curl`
/// shell-outs to `itunes.apple.com` and the artwork CDN.
public struct SystemCoverService: CoverService {
    private let maxImageBytes: Int

    public init(maxImageBytes: Int = 8 * 1024 * 1024) {
        self.maxImageBytes = maxImageBytes
    }

    public func search(term: String) async throws -> [CoverResult] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CoverError.badQuery }
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "8"),
        ]
        guard let url = components.url else { throw CoverError.badQuery }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw CoverError.network(error.localizedDescription)
        }
        return Self.parse(data)
    }

    public func downloadImage(from url: String) async throws -> Data {
        guard url.lowercased().hasPrefix("https://"), let parsed = URL(string: url) else {
            throw CoverError.badQuery
        }
        var request = URLRequest(url: parsed)
        request.timeoutInterval = 25
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw CoverError.network(error.localizedDescription)
        }
        guard data.count <= maxImageBytes else { throw CoverError.tooLarge }
        guard ImageKind.sniff(data) != nil else { throw CoverError.notAnImage }
        return data
    }

    /// The iTunes response shape is fixed; decode just the fields we use.
    static func parse(_ data: Data) -> [CoverResult] {
        struct Response: Decodable {
            struct Item: Decodable {
                let artworkUrl100: String?
                let trackName: String?
                let artistName: String?
                let collectionName: String?
            }
            let results: [Item]
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return decoded.results.compactMap { item in
            guard let art = item.artworkUrl100, !art.isEmpty else { return nil }
            return CoverResult(artworkURL: upscaleArtworkURL(art),
                               title: item.trackName ?? "",
                               artist: item.artistName ?? "",
                               album: item.collectionName ?? "")
        }
    }
}

/// Owns `Paths.covers`: writes a downloaded or user-supplied image in under a
/// unique name once its bytes are confirmed to be a real JPEG/PNG, and removes
/// only files it put there. Mirrors `cover_apply_job` / `is_stored_cover`.
public struct CoverStore {
    public let directory: URL

    public init(directory: URL = Paths.covers) {
        self.directory = directory
    }

    /// Validates `data`, writes it in, and returns the stored file URL.
    @discardableResult
    public func store(_ data: Data, nonce: Int = Int(Date().timeIntervalSince1970)) throws -> URL {
        guard let kind = ImageKind.sniff(data) else { throw CoverError.notAnImage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "cover-\(nonce)-\(UUID().uuidString.prefix(8)).\(kind.fileExtension)"
        let url = directory.appendingPathComponent(name)
        try AtomicFile.write(data, to: url)
        return url
    }

    /// True when `path` is a file this store wrote — the only files it may
    /// delete when a cover is replaced.
    public func owns(_ path: String) -> Bool {
        URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
    }

    public func removeIfOwned(_ path: String?) {
        guard let path, owns(path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
