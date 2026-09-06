import Foundation
@testable import MacMusicPluginKit

/// Engine-level library edits used by the milestone-6 panel: add remote source,
/// edit tags, remove, and incoming accept/decline routed through the viewed
/// playlist.
enum EngineLibraryTests {
    @MainActor
    private static func engine(_ dir: URL) -> PlayerEngine {
        let store = LibraryStore(directory: dir.appendingPathComponent("library"))
        try? store.bootstrap()
        let defaults = UserDefaults(suiteName: "mmp-engine-\(UUID().uuidString)")!
        let e = PlayerEngine(library: store, loader: .local(), defaults: defaults,
                             metadata: StubMetadata(), covers: StubCovers())
        e.refreshPlaylists()
        return e
    }

    static func register() {
        Harness.testAsync("addRemoteSource: https rejects non-https, adds by name") {
            let (dir, cleanup) = Harness.tempDir("eng-remote"); defer { cleanup() }
            let e = engine(dir)
            await e.addRemoteSource(kind: .https, url: "http://insecure/x.flac")
            Harness.expectEqual(e.viewedTracks.count, 0, "http rejected")
            await e.addRemoteSource(kind: .https, url: "https://host/Song Name.flac")
            Harness.expectEqual(e.viewedTracks.count, 1)
            Harness.expectEqual(e.viewedTracks.first?.title, "Song Name")
            Harness.expectEqual(e.viewedTracks.first?.sources.first?.kind, .https)
        }

        Harness.testAsync("addRemoteSource: ssh validates identity") {
            let (dir, cleanup) = Harness.tempDir("eng-ssh"); defer { cleanup() }
            let e = engine(dir)
            await e.addRemoteSource(kind: .ssh, username: "bad user", host: "h", remotePath: "/m/a.flac")
            Harness.expectEqual(e.viewedTracks.count, 0, "space in username rejected")
            await e.addRemoteSource(kind: .network, username: "kevin", host: "10.0.0.2", remotePath: "/m/a.flac")
            Harness.expectEqual(e.viewedTracks.first?.sources.first?.kind, .network)
        }

        Harness.testAsync("editTrack + removeTrack on the viewed playlist") {
            let (dir, cleanup) = Harness.tempDir("eng-edit"); defer { cleanup() }
            let e = engine(dir)
            await e.addRemoteSource(kind: .https, url: "https://h/a.flac")
            let id = e.viewedTracks[0].id
            e.editTrack(id: id, title: "Renamed", artist: "New Artist", album: "New Album")
            Harness.expectEqual(e.viewedTracks[0].title, "Renamed")
            Harness.expectEqual(e.viewedTracks[0].artist, "New Artist")
            e.removeTrack(id: id)
            Harness.expectEqual(e.viewedTracks.count, 0)
        }

        Harness.testAsync("acceptIncoming moves a staged track and returns to target") {
            let (dir, cleanup) = Harness.tempDir("eng-incoming"); defer { cleanup() }
            let store = LibraryStore(directory: dir.appendingPathComponent("library"))
            try store.bootstrap()
            let keep = Track(title: "Keep", artist: "A", album: "R",
                             sources: [Source(kind: .local, path: "/k.mp3")])
            try store.writeStaging(target: "home", tracks: [keep])
            let defaults = UserDefaults(suiteName: "mmp-inc-\(UUID().uuidString)")!
            let e = PlayerEngine(library: store, loader: .local(), defaults: defaults,
                                 metadata: StubMetadata(), covers: StubCovers())
            e.refreshPlaylists()
            e.viewPlaylist(PlaylistName.incomingName(for: "home"))
            Harness.expect(e.viewedIncomingTarget == "home", "viewing the staging list")

            e.acceptIncoming(trackIDs: [keep.id])
            Harness.expectEqual(e.viewedPlaylist, "home", "returned to target after staging emptied")
            Harness.expectEqual(e.viewedTracks.map(\.title), ["Keep"])
        }
    }
}

private struct StubMetadata: MetadataReading {
    func read(_ url: URL) async -> ExtractedMetadata { ExtractedMetadata() }
}

private struct StubCovers: CoverService {
    func search(term: String) async throws -> [CoverResult] { [] }
    func downloadImage(from url: String) async throws -> Data { Data() }
}
