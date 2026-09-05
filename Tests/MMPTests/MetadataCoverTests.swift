import Foundation
@testable import MacMusicPluginKit

/// Returns scripted metadata regardless of the URL.
struct FakeMetadataReader: MetadataReading {
    let result: ExtractedMetadata
    func read(_ url: URL) async -> ExtractedMetadata { result }
}

/// Scripted iTunes results and image bytes; records what it was asked.
final class FakeCoverService: CoverService, @unchecked Sendable {
    nonisolated(unsafe) private(set) var searchedTerms: [String] = []
    nonisolated(unsafe) private(set) var downloadedURLs: [String] = []

    private let results: [CoverResult]
    private let image: Data
    private let searchError: CoverError?

    init(results: [CoverResult] = [], image: Data = jpeg1x1, searchError: CoverError? = nil) {
        self.results = results
        self.image = image
        self.searchError = searchError
    }

    func search(term: String) async throws -> [CoverResult] {
        searchedTerms.append(term)
        if let searchError { throw searchError }
        return results
    }

    func downloadImage(from url: String) async throws -> Data {
        downloadedURLs.append(url)
        return image
    }
}

/// Smallest bytes that pass `ImageKind.sniff` as JPEG / PNG.
let jpeg1x1 = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0x00, count: 20))
let png1x1 = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x00, count: 20))

enum MetadataCoverTests {
    // A trimmed iTunes Search API response (real field names and escaping).
    static let itunesJSON = """
    {
     "resultCount": 2,
     "results": [
      {"wrapperType":"track", "trackName":"Get Lucky", "artistName":"Daft Punk",
       "collectionName":"Random Access Memories",
       "artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/abc/100x100bb.jpg"},
      {"wrapperType":"track", "trackName":"Instant Crush", "artistName":"Daft Punk",
       "collectionName":"Random Access Memories",
       "artworkUrl60":"https://is1-ssl.mzstatic.com/image/thumb/def/60x60bb.jpg"}
     ]
    }
    """

    static func register() {
        Harness.test("hasRealText + trackMetadata fallback chain") {
            Harness.expect(hasRealText("x"), "non-space is real")
            Harness.expect(!hasRealText("   "), "whitespace only is not")
            Harness.expect(!hasRealText(nil), "nil is not")

            let full = ExtractedMetadata(title: "T", artist: "A", album: "Rec")
            Harness.expectEqual(full.trackMetadata(fallbackTitle: "file").artist, "A")

            let none = ExtractedMetadata()
            let meta = none.trackMetadata(fallbackTitle: "my song")
            Harness.expectEqual(meta.title, "my song", "empty title falls back to file name")
            Harness.expectEqual(meta.artist, "Unknown artist")
            Harness.expectEqual(meta.album, "Unknown album")
            Harness.expect(none.isEmpty, "no tags, no artwork => empty")
        }

        Harness.test("ImageKind.sniff reads magic bytes, not names") {
            Harness.expectEqual(ImageKind.sniff(jpeg1x1), .jpeg)
            Harness.expectEqual(ImageKind.sniff(png1x1), .png)
            Harness.expect(ImageKind.sniff(Data("GIF89a...".utf8)) == nil, "gif rejected")
            Harness.expect(ImageKind.sniff(Data()) == nil, "empty rejected")
            Harness.expectEqual(ImageKind.jpeg.fileExtension, "jpg")
        }

        Harness.test("upscaleArtworkURL swaps the last size segment") {
            Harness.expectEqual(upscaleArtworkURL("https://x/100x100bb.jpg"), "https://x/600x600bb.jpg")
            Harness.expectEqual(upscaleArtworkURL("https://x/100x100/y/100x100bb.jpg"),
                                "https://x/100x100/y/600x600bb.jpg", "only the last segment")
            Harness.expectEqual(upscaleArtworkURL("https://x/art.jpg"), "https://x/art.jpg", "no size, unchanged")
        }

        Harness.test("SystemCoverService.parse: upscales, drops entries with no artwork") {
            let results = SystemCoverService.parse(Data(itunesJSON.utf8))
            Harness.expectEqual(results.count, 1, "the artworkUrl60-only record is skipped")
            Harness.expectEqual(results[0].artworkURL, "https://is1-ssl.mzstatic.com/image/thumb/abc/600x600bb.jpg")
            Harness.expectEqual(results[0].title, "Get Lucky")
            Harness.expectEqual(results[0].artist, "Daft Punk")
            Harness.expectEqual(results[0].album, "Random Access Memories")
            Harness.expect(SystemCoverService.parse(Data("not json".utf8)).isEmpty, "garbage => no results")
        }

        Harness.test("CoverStore stores validated images and only deletes its own") {
            let (dir, cleanup) = Harness.tempDir("covers")
            defer { cleanup() }
            let store = CoverStore(directory: dir)

            let url = try store.store(png1x1, nonce: 7)
            Harness.expectEqual(url.pathExtension, "png")
            Harness.expect(FileManager.default.fileExists(atPath: url.path), "written")
            Harness.expect(store.owns(url.path), "recognises its own file")
            Harness.expect(!store.owns("/etc/hosts"), "does not claim outside files")

            var threw = false
            do { _ = try store.store(Data("nope".utf8)) } catch { threw = true }
            Harness.expect(threw, "non-image rejected")

            let outsider = dir.deletingLastPathComponent().appendingPathComponent("keep.png")
            try png1x1.write(to: outsider)
            store.removeIfOwned(outsider.path)
            Harness.expect(FileManager.default.fileExists(atPath: outsider.path), "outside file left alone")
            store.removeIfOwned(url.path)
            Harness.expect(!FileManager.default.fileExists(atPath: url.path), "own file removed")
        }

        Harness.test("LibraryStore.applyCover: direct on a playlist, clears with nil") {
            let (dir, cleanup) = Harness.tempDir("cover-lib")
            defer { cleanup() }
            let store = LibraryStore(directory: dir)
            try store.bootstrap()
            let outcome = try store.addSource(Source(kind: .local, path: "/m/a.mp3"),
                                              metadata: TrackMetadata(title: "A", artist: "B", album: "C"),
                                              toPlaylist: "home")
            guard case .created(let id) = outcome else { Harness.expect(false, "created"); return }

            try store.applyCover(toTrackID: id, in: "home", coverPath: "/covers/x.jpg")
            Harness.expectEqual(try store.load("home").tracks[0].cover, "/covers/x.jpg")
            try store.applyCover(toTrackID: id, in: "home", coverPath: nil)
            let cleared = try store.load("home").tracks[0].cover
            Harness.expect(cleared == nil, "nil clears it")
        }

        Harness.test("LibraryStore.applyCover on * pushes to origin playlists and rebuilds") {
            let (dir, cleanup) = Harness.tempDir("cover-star")
            defer { cleanup() }
            let store = LibraryStore(directory: dir)
            try store.bootstrap()
            let src = Source(kind: .https, url: "https://x/track.flac")
            try store.addSource(src, metadata: TrackMetadata(title: "T", artist: "A", album: "R"),
                                toPlaylist: "home")
            try store.rebuildStar()
            let starID = try store.load("*").tracks.first { $0.sources.contains(src) }!.id

            try store.applyCover(toTrackID: starID, in: "*", coverPath: "/covers/star.jpg")

            Harness.expectEqual(try store.load("home").tracks[0].cover, "/covers/star.jpg",
                                "the origin playlist got the cover")
            Harness.expectEqual(try store.load("*").tracks[0].cover, "/covers/star.jpg",
                                "and the rebuilt * reflects it")
        }

        Harness.test("FLACMetadata parses Vorbis comments and an embedded PICTURE") {
            func u32le(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
            func u32be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
            func block(_ type: UInt8, _ body: [UInt8], last: Bool) -> [UInt8] {
                [(last ? 0x80 : 0) | type] + [UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
            }

            let comments = ["TITLE=Voyager", "ARTIST=Daft Punk", "album=random access memories"]
            var vc: [UInt8] = u32le(6) + Array("vendor".utf8) + u32le(UInt32(comments.count))
            for c in comments { vc += u32le(UInt32(c.utf8.count)) + Array(c.utf8) }

            let pic = Array(png1x1)
            var picBlock: [UInt8] = u32be(3) + u32be(9) + Array("image/png".utf8) + u32be(0)
            picBlock += u32be(1) + u32be(1) + u32be(8) + u32be(0) + u32be(UInt32(pic.count)) + pic

            let flac = Data(Array("fLaC".utf8) + block(4, vc, last: false) + block(6, picBlock, last: true))
            guard let meta = FLACMetadata.parse(flac) else { Harness.expect(false, "parsed"); return }
            Harness.expectEqual(meta.title, "Voyager")
            Harness.expectEqual(meta.artist, "Daft Punk")
            Harness.expectEqual(meta.album, "random access memories", "field name is case-insensitive")
            Harness.expect(meta.artwork != nil && ImageKind.sniff(meta.artwork!) == .png, "PICTURE extracted")

            Harness.expect(FLACMetadata.parse(Data("ID3\u{03}not a flac".utf8)) == nil, "non-FLAC rejected")
        }

        Harness.testAsync("addLocalFile imports real tags, else falls back to the file name") {
            let (dir, cleanup) = Harness.tempDir("engine-meta")
            defer { cleanup() }
            let library = LibraryStore(directory: dir.appendingPathComponent("library"))
            try library.bootstrap()
            let defaults = UserDefaults(suiteName: "mmp-meta-\(UUID().uuidString)")!

            let tagged = PlayerEngine(library: library, defaults: defaults,
                                      metadata: FakeMetadataReader(result:
                                        ExtractedMetadata(title: "Real Title", artist: "Real Artist", album: "Real Album")),
                                      covers: FakeCoverService())
            try await tagged.addLocalFile(path: "/music/track-01.mp3")
            Harness.expectEqual(tagged.viewedTracks.first?.artist, "Real Artist")

            let bare = PlayerEngine(library: library, defaults: defaults,
                                    metadata: FakeMetadataReader(result: ExtractedMetadata()),
                                    covers: FakeCoverService())
            try await bare.addLocalFile(path: "/music/Nice Song.flac")
            let added = bare.viewedTracks.first { $0.title == "Nice Song" }
            Harness.expect(added != nil, "untagged file imported under its base name")
            Harness.expectEqual(added?.artist, "Unknown artist")
        }

        Harness.testAsync("cover actions are a no-op while nothing is playing") {
            let (dir, cleanup) = Harness.tempDir("engine-cover")
            defer { cleanup() }
            let library = LibraryStore(directory: dir.appendingPathComponent("library"))
            try library.bootstrap()
            let defaults = UserDefaults(suiteName: "mmp-cover-\(UUID().uuidString)")!
            let service = FakeCoverService(results: [
                CoverResult(artworkURL: "https://x/600x600bb.jpg", title: "T", artist: "A", album: "R"),
            ])
            let engine = PlayerEngine(library: library, defaults: defaults,
                                      metadata: FakeMetadataReader(result: ExtractedMetadata()),
                                      covers: service)

            engine.searchCoverArt()
            engine.searchCoverArt(query: "daft punk get lucky")
            engine.applyCoverArt(CoverResult(artworkURL: "https://x/600x600bb.jpg", title: "", artist: "", album: ""))
            engine.removeCoverArt()
            try await Task.sleep(for: .milliseconds(50))

            Harness.expect(service.searchedTerms.isEmpty, "no search request without a playing track")
            Harness.expect(service.downloadedURLs.isEmpty, "no download without a playing track")
            Harness.expect(engine.coverResults.isEmpty, "no results published")
        }
    }
}
