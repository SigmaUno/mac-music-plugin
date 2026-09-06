import Foundation
@testable import MacMusicPluginKit

enum TrackTitleTests {
    static func register() {
        func mk(_ title: String, _ artist: String = "", _ album: String = "") -> Track {
            Track(title: title, artist: artist, album: album)
        }

        Harness.test("track title: suffix form (menu bar)") {
            func s(_ t: String, _ a: String = "", pos: Int = 7) -> String {
                TrackTitle.display(mk(t, a), position: pos, number: .suffix)
            }
            Harness.expectEqual(s("01 Artist Bloom", "Artist"), "Bloom (01)")
            Harness.expectEqual(s("01 Bloom", "Artist"), "Bloom (01)")
            Harness.expectEqual(s("01 Artrist - Bloom", "Artrist"), "Bloom (01)")
            Harness.expectEqual(s("04 Radiohead - Lewis (Mistreated)", "Radiohead"),
                                "Lewis (Mistreated) (04)")
            Harness.expectEqual(s("True Love Tape Loop", "Alex G", pos: 3), "True Love Tape Loop (03)")
        }

        Harness.test("track title: prefix form (library list)") {
            func p(_ t: String, _ a: String = "", pos: Int = 7) -> String {
                TrackTitle.display(mk(t, a), position: pos, number: .prefix)
            }
            Harness.expectEqual(p("01 Artist Bloom", "Artist"), "01 Bloom")
            Harness.expectEqual(p("04 Radiohead - Lewis (Mistreated)", "Radiohead"), "04 Lewis (Mistreated)")
            Harness.expectEqual(p("True Love Tape Loop", "Alex G", pos: 3), "03 True Love Tape Loop")
        }

        Harness.test("track title: omit form + number label (player header)") {
            let t = mk("04 Radiohead - Lewis (Mistreated)", "Radiohead")
            Harness.expectEqual(TrackTitle.display(t, position: 7, number: .omit), "Lewis (Mistreated)")
            Harness.expectEqual(TrackTitle.numberLabel(t, position: 7), "04")
            Harness.expectEqual(TrackTitle.numberLabel(mk("True Love Tape Loop"), position: 3), "03")
            Harness.expectEqual(TrackTitle.numberLabel(mk("Bloom"), position: 0), "")
        }
    }
}
