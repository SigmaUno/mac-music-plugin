import SwiftUI

/// The item drawn in the system menu bar: a transport glyph and, when something
/// is loaded, a compact "Title · Artist". Mirrors the Omarchy bar widget's
/// glyph/label logic (BarWidget.qml around line 1030).
///
/// Milestone 1: static placeholder. Wired to `PlayerEngine` in milestone 3.
public struct MenuBarLabel: View {
    public init() {}

    public var body: some View {
        Image(systemName: "music.note")
    }
}
