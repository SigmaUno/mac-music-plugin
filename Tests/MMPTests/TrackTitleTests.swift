import Foundation
@testable import MacMusicPluginKit

enum TrackTitleTests {
    static func register() {
        func mk(_ title: String, _ artist: String = "", _ album: String = "") -> Track {
            Track(title: title, artist: artist, album: album)
        }

        Harness.test("track title: suffix form (menu bar)") {
            func s(_ t: String, _ a: String = "") -> String {
                TrackTitle.display(mk(t, a), number: .suffix)
            }
            Harness.expectEqual(s("01 Artist Bloom", "Artist"), "Bloom (01)")
            Harness.expectEqual(s("01 Bloom", "Artist"), "Bloom (01)")
            Harness.expectEqual(s("01 Artrist - Bloom", "Artrist"), "Bloom (01)")
            Harness.expectEqual(s("04 Radiohead - Lewis (Mistreated)", "Radiohead"),
                                "Lewis (Mistreated) (04)")
            // No leading track number → nothing is appended.
            Harness.expectEqual(s("True Love Tape Loop", "Alex G"), "True Love Tape Loop")
        }

        Harness.test("track title: prefix form (library list)") {
            func p(_ t: String, _ a: String = "") -> String {
                TrackTitle.display(mk(t, a), number: .prefix)
            }
            Harness.expectEqual(p("01 Artist Bloom", "Artist"), "01 Bloom")
            Harness.expectEqual(p("04 Radiohead - Lewis (Mistreated)", "Radiohead"), "04 Lewis (Mistreated)")
            // No leading track number → no prefix.
            Harness.expectEqual(p("True Love Tape Loop", "Alex G"), "True Love Tape Loop")
        }

        Harness.test("track title: omit form + number label (player header)") {
            let t = mk("04 Radiohead - Lewis (Mistreated)", "Radiohead")
            Harness.expectEqual(TrackTitle.display(t, number: .omit), "Lewis (Mistreated)")
            Harness.expectEqual(TrackTitle.numberLabel(t), "04")
            // No leading digits → empty label, not the playlist position.
            Harness.expectEqual(TrackTitle.numberLabel(mk("True Love Tape Loop")), "")
            Harness.expectEqual(TrackTitle.numberLabel(mk("Bloom")), "")
        }
    }
}
