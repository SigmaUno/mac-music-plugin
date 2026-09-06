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

// MARK: - Binary fixture builders (FLAC / Vorbis-comment / Ogg)

func u32le(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
func u32be(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

/// A FLAC PICTURE block / `METADATA_BLOCK_PICTURE` payload wrapping `image`.
func flacPictureBlock(mime: String = "image/png", image: [UInt8]) -> [UInt8] {
    u32be(3) + u32be(mime.utf8.count) + Array(mime.utf8) + u32be(0)
        + u32be(1) + u32be(1) + u32be(8) + u32be(0) + u32be(image.count) + image
}

/// A Vorbis comment list body: `<u32le vendorLen><vendor><u32le count>(<u32le len><FIELD=value>)*`.
func vorbisCommentBody(vendor: String = "test", comments: [String]) -> [UInt8] {
    var b = u32le(vendor.utf8.count) + Array(vendor.utf8) + u32le(comments.count)
    for c in comments { b += u32le(c.utf8.count) + Array(c.utf8) }
    return b
}

/// An Ogg page for `serial` with a pre-built segment table.
func oggPageRaw(serial: Int, sequence: Int, segTable: [UInt8], body: [UInt8], continued: Bool) -> [UInt8] {
    var page: [UInt8] = Array("OggS".utf8) + [0x00, continued ? 0x01 : 0x00]
    page += Array(repeating: 0x00, count: 8)             // granule position
    page += u32le(serial) + u32le(sequence) + u32le(0)   // serial, seq, CRC (unchecked)
    page += [UInt8(segTable.count)] + segTable + body
    return page
}

/// One Ogg page carrying whole `packets` for `serial`. Each packet is laced into
/// 255-byte segments plus a terminating segment < 255 (0 when it divides evenly).
func oggPage(serial: Int, sequence: Int, packets: [[UInt8]], continued: Bool = false) -> [UInt8] {
    var segTable: [UInt8] = []
    var body: [UInt8] = []
    for packet in packets {
        var remaining = packet.count
        while remaining >= 255 { segTable.append(255); remaining -= 255 }
        segTable.append(UInt8(remaining))
        body += packet
    }
    return oggPageRaw(serial: serial, sequence: sequence, segTable: segTable, body: body, continued: continued)
}

/// A page holding one chunk of a packet that continues onto the next page: the
/// chunk is emitted as pure 255-lacing segments and must be a multiple of 255.
func oggContinuationPage(serial: Int, sequence: Int, chunk: [UInt8], continued: Bool) -> [UInt8] {
    precondition(chunk.count % 255 == 0 && !chunk.isEmpty)
    return oggPageRaw(serial: serial, sequence: sequence,
                      segTable: Array(repeating: 255, count: chunk.count / 255), body: chunk, continued: continued)
}

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
            func block(_ type: UInt8, _ body: [UInt8], last: Bool) -> [UInt8] {
                [(last ? 0x80 : 0) | type]
                    + [UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
            }
            let vc = vorbisCommentBody(comments: ["TITLE=Voyager", "ARTIST=Daft Punk", "album=random access memories"])
            let picBlock = flacPictureBlock(image: Array(png1x1))

            let flac = Data(Array("fLaC".utf8) + block(4, vc, last: false) + block(6, picBlock, last: true))
            guard let meta = FLACMetadata.parse(flac) else { Harness.expect(false, "parsed"); return }
            Harness.expectEqual(meta.title, "Voyager")
            Harness.expectEqual(meta.artist, "Daft Punk")
            Harness.expectEqual(meta.album, "random access memories", "field name is case-insensitive")
            Harness.expect(meta.artwork != nil && ImageKind.sniff(meta.artwork!) == .png, "PICTURE extracted")

            Harness.expect(FLACMetadata.parse(Data("ID3\u{03}not a flac".utf8)) == nil, "non-FLAC rejected")
        }

        Harness.test("VorbisComment decodes METADATA_BLOCK_PICTURE and legacy COVERART") {
            let b64pic = Data(flacPictureBlock(image: Array(jpeg1x1))).base64EncodedString()
            var viaBlock = ExtractedMetadata()
            VorbisComment.parse(vorbisCommentBody(comments: ["TITLE=X", "METADATA_BLOCK_PICTURE=\(b64pic)"]), into: &viaBlock)
            Harness.expect(viaBlock.artwork.map { ImageKind.sniff($0) } == .some(.jpeg), "art via METADATA_BLOCK_PICTURE")

            let b64raw = png1x1.base64EncodedString()
            var viaCoverart = ExtractedMetadata()
            VorbisComment.parse(vorbisCommentBody(comments: ["COVERART=\(b64raw)"]), into: &viaCoverart)
            Harness.expect(viaCoverart.artwork.map { ImageKind.sniff($0) } == .some(.png), "art via legacy COVERART")
        }

        Harness.test("OggMetadata: Opus (OpusTags) and Vorbis (\\x03vorbis) comment headers") {
            let pic = "METADATA_BLOCK_PICTURE=" + Data(flacPictureBlock(image: Array(png1x1))).base64EncodedString()
            let body = vorbisCommentBody(comments: ["TITLE=Get Lucky", "ARTIST=Daft Punk", "ALBUM=RAM", pic])

            let opusHead = Array("OpusHead".utf8) + Array(repeating: 0x00, count: 11)
            let opusTags = Array("OpusTags".utf8) + body
            let opus = Data(oggPage(serial: 42, sequence: 0, packets: [opusHead, opusTags]))
            guard let m = OggMetadata.parse(opus) else { Harness.expect(false, "opus parsed"); return }
            Harness.expectEqual(m.title, "Get Lucky")
            Harness.expectEqual(m.artist, "Daft Punk")
            Harness.expectEqual(m.album, "RAM")
            Harness.expect(m.artwork != nil, "opus embedded art")

            let vorbisID = [0x01] + Array("vorbis".utf8) + Array(repeating: 0x00, count: 22)
            let vorbisComment = [0x03] + Array("vorbis".utf8) + body + [0x01]   // trailing framing bit
            let ogg = Data(oggPage(serial: 7, sequence: 0, packets: [vorbisID, vorbisComment]))
            guard let v = OggMetadata.parse(ogg) else { Harness.expect(false, "vorbis parsed"); return }
            Harness.expectEqual(v.title, "Get Lucky")
            Harness.expect(v.artwork != nil, "vorbis embedded art survives the framing bit")

            Harness.expect(OggMetadata.parse(Data("RIFF....WAVEfmt ".utf8)) == nil, "non-Ogg rejected")
        }

        Harness.test("OggMetadata: a comment packet spanning two pages") {
            let filler = String(repeating: "x", count: 900)
            let body = vorbisCommentBody(comments: ["TITLE=Long One", "ARTIST=A", "ALBUM=\(filler)"])
            let head = Array("OpusHead".utf8) + Array(repeating: 0x00, count: 11)
            let tags = Array("OpusTags".utf8) + body

            // page 0: the identification packet.
            // page 1: a 510-byte chunk of the comment packet (pure 255 lacing -> continues).
            // page 2 (continued): the remainder, ending on a < 255 boundary.
            let split = 510
            let page0 = oggPage(serial: 1, sequence: 0, packets: [head])
            let page1 = oggContinuationPage(serial: 1, sequence: 1, chunk: Array(tags[..<split]), continued: false)
            let page2 = oggPage(serial: 1, sequence: 2, packets: [Array(tags[split...])], continued: true)

            guard let m = OggMetadata.parse(Data(page0 + page1 + page2)) else {
                Harness.expect(false, "spanning packet parsed"); return
            }
            Harness.expectEqual(m.title, "Long One")
            Harness.expectEqual(m.album, filler)
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

        Harness.testAsync("play-time backfill: real tags + art replace a scan placeholder row") {
            let (dir, cleanup) = Harness.tempDir("backfill-e2e")
            defer { cleanup() }

            // A real FLAC file: tags + embedded PICTURE, no audio frames —
            // enough for AVMetadataReader's container-parser fallback.
            func block(_ type: UInt8, _ body: [UInt8], last: Bool) -> [UInt8] {
                [(last ? 0x80 : 0) | type]
                    + [UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
            }
            let vc = vorbisCommentBody(comments: ["TITLE=Weird Fishes", "ARTIST=Radiohead", "ALBUM=In Rainbows"])
            let pic = flacPictureBlock(mime: "image/jpeg", image: Array(jpeg1x1))
            let flacURL = dir.appendingPathComponent("track.flac")
            try Data(Array("fLaC".utf8) + block(4, vc, last: false) + block(6, pic, last: true)).write(to: flacURL)

            let store = LibraryStore(directory: dir.appendingPathComponent("library"))
            try store.bootstrap()
            let src = Source(kind: .local, path: flacURL.path)
            _ = try store.addSource(src, metadata: TrackMetadata(title: "track",
                                                                 artist: "Unknown artist", album: "Unknown album"),
                                    toPlaylist: "home")

            let tags = await AVMetadataReader().read(flacURL)
            Harness.expectEqual(tags.artist, "Radiohead", "reader pulled the Vorbis ARTIST")
            Harness.expectEqual(tags.album, "In Rainbows")
            Harness.expect(tags.artwork.map { ImageKind.sniff($0) } == .some(.jpeg), "embedded PICTURE read")

            let cover = try CoverStore(directory: dir.appendingPathComponent("covers")).store(tags.artwork!).path
            let wrote = try store.backfillMetadata(forSourceKeys: [src.dedupKey],
                                                   artist: tags.artist, album: tags.album, cover: cover)
            Harness.expect(wrote.artist && wrote.album && wrote.cover, "all three written")

            let row = try store.load("home").tracks[0]
            Harness.expectEqual(row.artist, "Radiohead")
            Harness.expectEqual(row.album, "In Rainbows")
            Harness.expectEqual(row.cover, cover)
        }
    }
}
