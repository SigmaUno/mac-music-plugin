import Foundation
@testable import MacMusicPluginKit

enum ModelCodingTests {
    // A playlist file exactly as the Omarchy backend writes it: SCREAMING
    // transport keys, lowercase `kind`, `null` for absent fields, no `id`.
    static let omarchyJSON = """
    {
      "version": 1,
      "tracks": [
        {
          "title": "Test Song",
          "artist": "Test Artist",
          "album": "Test Album",
          "sources": [
            { "kind": "https", "PATH": null, "USERNAME": null, "URL": "https://example.com/a.flac", "IP": null },
            { "kind": "ssh", "PATH": "/music/a.flac", "USERNAME": "kevin", "URL": null, "IP": "192.168.1.2" }
          ]
        },
        {
          "title": "Local Only",
          "artist": "Someone",
          "album": "Disc",
          "cover": "/Users/kevin/art.jpg",
          "sources": [
            { "kind": "local", "PATH": "/Users/kevin/a.mp3", "USERNAME": null, "URL": null, "IP": null }
          ]
        }
      ]
    }
    """

    static func register() {
        Harness.test("decodes an Omarchy-format playlist file") {
            let data = Data(omarchyJSON.utf8)
            let file = try JSONDecoder().decode(PlaylistFile.self, from: data)
            Harness.expectEqual(file.version, 1)
            Harness.expectEqual(file.tracks.count, 2)

            let t0 = file.tracks[0]
            Harness.expectEqual(t0.title, "Test Song")
            Harness.expectEqual(t0.sources.count, 2)
            Harness.expectEqual(t0.sources[0].kind, .https)
            Harness.expectEqual(t0.sources[0].url, "https://example.com/a.flac")
            Harness.expect(t0.sources[0].path == nil, "absent PATH decodes to nil")
            Harness.expectEqual(t0.sources[1].kind, .ssh)
            Harness.expectEqual(t0.sources[1].username, "kevin")
            Harness.expectEqual(t0.sources[1].ip, "192.168.1.2")
            Harness.expect(!t0.id.isEmpty, "synthesised an id for an id-less track")

            Harness.expectEqual(file.tracks[1].cover, "/Users/kevin/art.jpg")
        }

        Harness.test("re-encodes with SCREAMING keys and lowercase kind") {
            let source = Source(kind: .ssh, path: "/m/x.flac", username: "u", ip: "10.0.0.1")
            let data = try JSONEncoder().encode(source)
            let text = String(decoding: data, as: UTF8.self)
            Harness.expect(text.contains("\"PATH\""), "emits PATH")
            Harness.expect(text.contains("\"USERNAME\""), "emits USERNAME")
            Harness.expect(text.contains("\"IP\""), "emits IP")
            Harness.expect(text.contains("\"kind\":\"ssh\""), "kind stays lowercase")
            Harness.expect(text.contains("\"URL\":null"), "absent field written as null")
        }

        Harness.test("round-trips through decode/encode/decode") {
            let file = try JSONDecoder().decode(PlaylistFile.self, from: Data(omarchyJSON.utf8))
            let reEncoded = try JSONEncoder().encode(file)
            let again = try JSONDecoder().decode(PlaylistFile.self, from: reEncoded)
            Harness.expectEqual(file.tracks.map(\.title), again.tracks.map(\.title))
            Harness.expectEqual(again.tracks[0].sources[1].path, "/music/a.flac")
        }

        Harness.test("Source.isComplete matches the C rules") {
            Harness.expect(Source(kind: .local, path: "/a").isComplete, "local needs PATH")
            Harness.expect(!Source(kind: .local).isComplete, "local without PATH incomplete")
            Harness.expect(Source(kind: .https, url: "https://x").isComplete, "https needs URL")
            Harness.expect(!Source(kind: .ssh, path: "/a", username: "u").isComplete,
                           "ssh without IP incomplete")
            Harness.expect(Source(kind: .network, path: "/a", username: "u", ip: "1.2.3.4").isComplete,
                           "network needs PATH+USERNAME+IP")
        }

        Harness.test("Source.dedupKey distinguishes kinds and fields") {
            let a = Source(kind: .ssh, path: "/a", username: "u", ip: "1.1.1.1")
            let b = Source(kind: .network, path: "/a", username: "u", ip: "1.1.1.1")
            Harness.expect(a.dedupKey != b.dedupKey, "different kind => different key")
            let c = Source(kind: .ssh, path: "/a", username: "u", ip: "1.1.1.1")
            Harness.expectEqual(a.dedupKey, c.dedupKey)
        }
    }
}
