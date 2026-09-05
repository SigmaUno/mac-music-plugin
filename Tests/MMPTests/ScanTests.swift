import Foundation
@testable import MacMusicPluginKit

/// Writes a fixed listing (or throws) instead of spawning `ssh`.
struct StubFetcher: RemoteFetcher {
    var stdout: String = ""
    var error: TrackLoadError?

    func run(argv: [String], destination: URL, maxBytes: Int) async throws {
        if let error { throw error }
        try Data(stdout.utf8).write(to: destination)
    }
}

enum ScanTests {
    static func register() {
        Harness.test("isAudioName + track naming") {
            Harness.expect(DirectoryScanner.isAudioName("Song.FLAC"), "case-insensitive extension")
            Harness.expect(!DirectoryScanner.isAudioName("cover.jpg"), "not audio")
            let t = DirectoryScanner.track(forPath: "/m/03 - Kashmir.flac",
                                           source: Source(kind: .local, path: "/m/03 - Kashmir.flac"))
            Harness.expectEqual(t.title, "03 - Kashmir")
            Harness.expectEqual(t.artist, "Unknown artist")
        }

        Harness.test("scanLocal: one level, audio only, sorted") {
            let (dir, cleanup) = Harness.tempDir("scan-local"); defer { cleanup() }
            for name in ["b.mp3", "a.flac", "notes.txt", ".hidden.mp3"] {
                try Data("x".utf8).write(to: dir.appendingPathComponent(name))
            }
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"),
                                                    withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("sub/deep.mp3"))

            let tracks = DirectoryScanner().scanLocal(directory: dir.path)
            Harness.expectEqual(tracks.map(\.title), ["a", "b"], "sorted, audio only, no dotfiles or recursion")
            Harness.expectEqual(tracks.first?.sources.first?.kind, .local)
        }

        Harness.testAsync("scanRemote: parses find output into ssh/network tracks") {
            let fetcher = StubFetcher(stdout: "/music/One.flac\n/music/Two.mp3\n\n")
            let scanner = DirectoryScanner(fetcher: fetcher, controlDirectory: nil)
            let tracks = try await scanner.scanRemote(kind: .network, username: "kevin",
                                                      host: "10.0.0.5", directory: "/music")
            Harness.expectEqual(tracks.map(\.title), ["One", "Two"])
            let src = tracks.first!.sources.first!
            Harness.expectEqual(src.kind, .network)
            Harness.expectEqual(src.username, "kevin")
            Harness.expectEqual(src.ip, "10.0.0.5")
            Harness.expectEqual(src.path, "/music/One.flac")
        }

        Harness.testAsync("scanRemote: no matches is an empty result, not an error") {
            let fetcher = StubFetcher(error: .transport("source returned no data"))
            let tracks = try await DirectoryScanner(fetcher: fetcher, controlDirectory: nil)
                .scanRemote(kind: .ssh, username: "u", host: "h", directory: "/empty")
            Harness.expectEqual(tracks.count, 0)
        }

        Harness.testAsync("scanRemote: rejects a bad identity before spawning") {
            var threw = false
            do {
                _ = try await DirectoryScanner(controlDirectory: nil)
                    .scanRemote(kind: .ssh, username: "bad;user", host: "h", directory: "/m")
            } catch { threw = (error as? DirectoryScanner.ScanError) == .invalidIdentity }
            Harness.expect(threw, "invalid identity rejected")
        }

        Harness.testAsync("engine.startScan (local) stages into INCOMING and shows it") {
            let (dir, cleanup) = Harness.tempDir("scan-engine"); defer { cleanup() }
            let music = dir.appendingPathComponent("music")
            try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
            for name in ["x.mp3", "y.flac"] { try Data("x".utf8).write(to: music.appendingPathComponent(name)) }

            let store = LibraryStore(directory: dir.appendingPathComponent("library"))
            try store.bootstrap()
            let defaults = UserDefaults(suiteName: "mmp-scan-\(UUID().uuidString)")!
            let e = PlayerEngine(library: store, loader: .local(), defaults: defaults,
                                 metadata: StubMeta(), covers: StubCov())
            e.refreshPlaylists()

            await e.startScan(kind: .local, directory: music.path)
            for _ in 0..<50 where e.isScanning { try? await Task.sleep(for: .milliseconds(20)) }

            Harness.expectEqual(e.viewedPlaylist, "INCOMING >> home <<")
            Harness.expectEqual(e.viewedTracks.map(\.title).sorted(), ["x", "y"])
            Harness.expectEqual(e.viewedIncomingTarget, "home")

            e.acceptIncoming(trackIDs: e.viewedTracks.map(\.id))
            Harness.expectEqual(e.viewedPlaylist, "home")
            Harness.expectEqual(e.viewedTracks.count, 2, "accepted into home")
        }
    }
}

private struct StubMeta: MetadataReading {
    func read(_ url: URL) async -> ExtractedMetadata { ExtractedMetadata() }
}
private struct StubCov: CoverService {
    func search(term: String) async throws -> [CoverResult] { [] }
    func downloadImage(from url: String) async throws -> Data { Data() }
}
