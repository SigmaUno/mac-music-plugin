import AVFoundation
import Foundation

/// Title / artist / album read off an audio file, plus its embedded cover image
/// when it carries one. The macOS counterpart of `metadata.c`'s
/// `mediainfo`/`ffprobe` shell-outs — AVFoundation reads the tags natively, so
/// there is no external tool to depend on.
public struct ExtractedMetadata: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    /// Raw bytes of the embedded artwork (JPEG or PNG), if any.
    public var artwork: Data?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, artwork: Data? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
    }

    public var isEmpty: Bool {
        !hasRealText(title) && !hasRealText(artist) && !hasRealText(album) && artwork == nil
    }

    /// Turns raw tags into the non-empty triple `LibraryStore.addSource`
    /// requires: a present tag wins, otherwise the file's base name for the
    /// title and the same "Unknown …" placeholders the C `build_song_query_for`
    /// falls back to.
    public func trackMetadata(fallbackTitle: String) -> TrackMetadata {
        TrackMetadata(
            title: hasRealText(title) ? title! : fallbackTitle,
            artist: hasRealText(artist) ? artist! : "Unknown artist",
            album: hasRealText(album) ? album! : "Unknown album")
    }
}

/// True when `s` has at least one non-whitespace character. Mirrors
/// `has_real_text` (backend/app.c).
func hasRealText(_ s: String?) -> Bool {
    guard let s else { return false }
    return s.contains { !$0.isWhitespace }
}

/// Reads `ExtractedMetadata` from a file URL. A protocol so the engine's import
/// path can be tested without real tagged media.
public protocol MetadataReading: Sendable {
    func read(_ url: URL) async -> ExtractedMetadata
}

/// AVFoundation-backed reader: pulls the common metadata (`title`, `artist`,
/// `albumName`, `artwork`) that ID3, iTunes/MP4 and Vorbis-comment tags all map
/// onto. Never throws — a missing or unreadable file yields empty metadata and
/// the caller falls back to the file name.
public struct AVMetadataReader: MetadataReading {
    public init() {}

    public func read(_ url: URL) async -> ExtractedMetadata {
        var result = ExtractedMetadata()

        let asset = AVURLAsset(url: url)
        for item in (try? await asset.load(.commonMetadata)) ?? [] {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle:
                result.title = (try? await item.load(.stringValue)) ?? nil
            case .commonKeyArtist, .commonKeyCreator, .commonKeyAuthor:
                if !hasRealText(result.artist) { result.artist = (try? await item.load(.stringValue)) ?? nil }
            case .commonKeyAlbumName:
                result.album = (try? await item.load(.stringValue)) ?? nil
            case .commonKeyArtwork:
                if let data = (try? await item.load(.dataValue)) ?? nil { result.artwork = data }
            default:
                break
            }
        }

        // AVFoundation plays FLAC but exposes none of its Vorbis-comment tags or
        // PICTURE block, so parse those directly and fill any gaps.
        if url.pathExtension.lowercased() == "flac", let flac = FLACMetadata.read(url) {
            if !hasRealText(result.title) { result.title = flac.title }
            if !hasRealText(result.artist) { result.artist = flac.artist }
            if !hasRealText(result.album) { result.album = flac.album }
            if result.artwork == nil { result.artwork = flac.artwork }
        }

        return result
    }
}
