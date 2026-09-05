import Foundation
@testable import MacMusicPluginKit

enum PlaylistNameTests {
    static func register() {
        Harness.test("valid playlist names") {
            Harness.expect(PlaylistName.isValid("home"), "home")
            Harness.expect(PlaylistName.isValid("Road Trip 2026"), "spaces + digits")
            Harness.expect(PlaylistName.isValid("lo-fi_beats"), "dash + underscore")
            Harness.expect(PlaylistName.isValid(String(repeating: "a", count: 64)), "64 chars ok")
        }

        Harness.test("invalid playlist names") {
            Harness.expect(!PlaylistName.isValid(""), "empty")
            Harness.expect(!PlaylistName.isValid(" leading"), "leading space")
            Harness.expect(!PlaylistName.isValid("trailing "), "trailing space")
            Harness.expect(!PlaylistName.isValid("../etc"), "path traversal")
            Harness.expect(!PlaylistName.isValid("a/b"), "slash")
            Harness.expect(!PlaylistName.isValid("dot.name"), "dot")
            Harness.expect(!PlaylistName.isValid("*"), "star is reserved")
            Harness.expect(!PlaylistName.isValid(String(repeating: "a", count: 65)), "65 chars too long")
            Harness.expect(!PlaylistName.isValid("café"), "non-ASCII")
        }

        Harness.test("incoming target parsing") {
            Harness.expectEqual(PlaylistName.incomingName(for: "home"), "INCOMING >> home <<")
            Harness.expectEqual(PlaylistName.incomingTarget(of: "INCOMING >> home <<"), "home")
            Harness.expect(PlaylistName.incomingTarget(of: "home") == nil, "plain name has no target")
            Harness.expect(PlaylistName.incomingTarget(of: "INCOMING >> ../x <<") == nil,
                           "traversal target rejected")
            Harness.expect(PlaylistName.incomingTarget(of: "INCOMING >>  <<") == nil,
                           "empty target rejected")
        }

        Harness.test("tab ordering: home, regular, incoming, star") {
            let input = ["*", "zeppelin", "INCOMING >> home <<", "home", "abba"]
            Harness.expectEqual(PlaylistName.sorted(input),
                                ["home", "abba", "zeppelin", "INCOMING >> home <<", "*"])
        }
    }
}
