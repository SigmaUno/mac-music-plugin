import Foundation
@testable import MacMusicPluginKit

enum LibraryStoreTests {
    private static func freshStore() -> (LibraryStore, () -> Void) {
        let (dir, cleanup) = Harness.tempDir("lib")
        return (LibraryStore(directory: dir.appendingPathComponent("library")), cleanup)
    }

    private static func meta(_ title: String, _ artist: String = "A", _ album: String = "Rec") -> TrackMetadata {
        TrackMetadata(title: title, artist: artist, album: album)
    }

    static func register() {
        Harness.test("bootstrap seeds home and *") {
            let (store, cleanup) = freshStore()
            defer { cleanup() }
            try store.bootstrap()
            Harness.expect(store.playlistExists("home"), "home.json created")
            Harness.expect(store.playlistExists("*"), "*.json created")
            Harness.expectEqual(store.playlistNames(), ["home", "*"])
        }

        Harness.test("bootstrap migrates a legacy library.json") {
            let (dir, cleanup) = Harness.tempDir("legacy")
            defer { cleanup() }
            let legacy = dir.appendingPathComponent("library.json")
            try Data(ModelCodingTests.omarchyJSON.utf8).write(to: legacy)
            let store = LibraryStore(directory: dir.appendingPathComponent("library"))
            try store.bootstrap()
            let home = try store.load("home")
            Harness.expectEqual(home.tracks.count, 2, "legacy tracks migrated into home")
        }

        Harness.test("addSource creates then merges by title+artist+album") {
            let (store, cleanup) = freshStore()
            defer { cleanup() }
            try store.bootstrap()

            let first = try store.addSource(Source(kind: .local, path: "/a.mp3"),
                                            metadata: meta("Song"), toPlaylist: "home")
            guard case .created(let id1) = first else {
                Harness.expect(false, "first add should create"); return
            }

            let second = try store.addSource(Source(kind: .https, url: "https://x/a.flac"),
                                             metadata: meta("song"),  // case-insensitive match
                                             toPlaylist: "home")
            guard case .merged(let id2) = second else {
                Harness.expect(false, "second add should merge"); return
            }
            Harness.expectEqual(id1, id2)

            let home = try store.load("home")
            Harness.expectEqual(home.tracks.count, 1)
            Harness.expectEqual(home.tracks[0].sources.count, 2)
        }

        Harness.test("addSource rejects incomplete sources and blank metadata") {
            let (store, cleanup) = freshStore()
            defer { cleanup() }
            try store.bootstrap()
            var threw = false
            do { _ = try store.addSource(Source(kind: .ssh, path: "/a"), metadata: meta("X"),
                                         toPlaylist: "home") }
            catch { threw = (error as? LibraryError) == .incompleteSource }
            Harness.expect(threw, "incomplete ssh source rejected")

            threw = false
            do { _ = try store.addSource(Source(kind: .local, path: "/a"),
                                         metadata: TrackMetadata(title: "", artist: "a", album: "b"),
                                         toPlaylist: "home") }
            catch { threw = (error as? LibraryError) == .missingMetadata }
            Harness.expect(threw, "blank title rejected")
        }

        Harness.test("updateTrack changes fields; cover clear vs leave") {
            let (store, cleanup) = freshStore()
            defer { cleanup() }
            try store.bootstrap()
            guard case .created(let id) = try store.addSource(
                Source(kind: .local, path: "/a.mp3"), metadata: meta("Song"), toPlaylist: "home")
            else { Harness.expect(false, "setup"); return }

            try store.updateTrack(id: id, in: "home", title: "Renamed", cover: .some("/art.jpg"))
            var t = try store.load("home").tracks[0]
            Harness.expectEqual(t.title, "Renamed")
            Harness.expectEqual(t.artist, "A", "artist untouched")
            Harness.expectEqual(t.cover, "/art.jpg")

            try store.updateTrack(id: id, in: "home", cover: .some(nil))
            t = try store.load("home").tracks[0]
            Harness.expect(t.cover == nil, "cover cleared")
        }

        Harness.test("removeTrack drops the entry") {
            let (store, cleanup) = freshStore()
            defer { cleanup() }
            try store.bootstrap()
            guard case .created(let id) = try store.addSource(
                Source(kind: .local, path: "/a.mp3"), metadata: meta("Song"), toPlaylist: "home")
            else { Harness.expect(false, "setup"); return }
            try store.removeTrack(id: id, from: "home")
            Harness.expectEqual(try store.load("home").tracks.count, 0)
        }

        Harness.test("resolve picks the best fuzzy match") {
            let (store, cleanup) = freshStore()
            defer { cleanup() }
            try store.bootstrap()
            _ = try store.addSource(Source(kind: .local, path: "/a"), metadata: meta("Kashmir", "Led Zeppelin", "Physical Graffiti"), toPlaylist: "home")
            _ = try store.addSource(Source(kind: .local, path: "/b"), metadata: meta("Carouselambra", "Led Zeppelin", "In Through the Out Door"), toPlaylist: "home")

            let hit = store.resolve(title: "kashmir", artist: "led zeppelin", album: nil, in: "home")
            Harness.expectEqual(hit?.title, "Kashmir")
            let miss = store.resolve(title: "nothing here", artist: nil, album: nil, in: "home")
            Harness.expect(miss == nil, "no match returns nil")
        }

        Harness.test("createPlaylist validates and refuses duplicates / reserved") {
            let (store, cleanup) = freshStore()
            defer { cleanup() }
            try store.bootstrap()
            _ = try store.createPlaylist("Road Trip")
            Harness.expect(store.playlistExists("Road Trip"), "created")

            for (name, expected) in [("Road Trip", LibraryError.playlistExists("Road Trip")),
                                     ("*", LibraryError.reservedPlaylist("*")),
                                     ("bad/name", LibraryError.invalidPlaylistName("bad/name"))] {
                var got: LibraryError?
                do { _ = try store.createPlaylist(name) } catch { got = error as? LibraryError }
                Harness.expectEqual(got, expected)
            }
        }

        Harness.test("rebuildStar unions sources, de-duplicates, skips staging") {
            let (store, cleanup) = freshStore()
            defer { cleanup() }
            try store.bootstrap()
            _ = try store.createPlaylist("rock")
            // Same track, two playlists, one shared source + one unique each.
            _ = try store.addSource(Source(kind: .local, path: "/shared.mp3"), metadata: meta("Song"), toPlaylist: "home")
            _ = try store.addSource(Source(kind: .https, url: "https://x/only-home.flac"), metadata: meta("Song"), toPlaylist: "home")
            _ = try store.addSource(Source(kind: .local, path: "/shared.mp3"), metadata: meta("Song"), toPlaylist: "rock")
            _ = try store.addSource(Source(kind: .ssh, path: "/r", username: "u", ip: "1.1.1.1"), metadata: meta("Song"), toPlaylist: "rock")
            // A staging playlist that must be ignored.
            try store.createStagingForTest(target: "home", tracks: [
                Track(title: "Staged", artist: "Z", album: "Z", sources: [Source(kind: .local, path: "/staged")])
            ])

            try store.rebuildStar()
            let star = try store.load("*")
            Harness.expectEqual(star.tracks.count, 1, "one merged track")
            Harness.expectEqual(star.tracks[0].sources.count, 3, "shared source counted once")
            Harness.expect(!star.tracks.contains { $0.title == "Staged" }, "staging skipped")
        }

        Harness.test("accept / decline incoming") {
            let (store, cleanup) = freshStore()
            defer { cleanup() }
            try store.bootstrap()
            let t1 = Track(title: "Keep", artist: "A", album: "R", sources: [Source(kind: .local, path: "/k")])
            let t2 = Track(title: "Toss", artist: "A", album: "R", sources: [Source(kind: .local, path: "/t")])
            try store.createStagingForTest(target: "home", tracks: [t1, t2])
            let staging = PlaylistName.incomingName(for: "home")

            try store.acceptIncoming(trackIDs: [t1.id], from: staging)
            try store.declineIncoming(trackIDs: [t2.id], from: staging)

            Harness.expect(!store.playlistExists(staging), "empty staging file removed")
            let home = try store.load("home")
            Harness.expectEqual(home.tracks.map(\.title), ["Keep"])
        }
    }
}

// Test-only helper to stand up a staging playlist without the scanner.
extension LibraryStore {
    func createStagingForTest(target: String, tracks: [Track]) throws {
        let name = PlaylistName.incomingName(for: target)
        try save(Playlist(name: name, tracks: tracks))
    }
}
