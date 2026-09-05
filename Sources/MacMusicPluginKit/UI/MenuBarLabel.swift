import SwiftUI

/// The item drawn in the system menu bar: a transport glyph and, when something
/// is loaded, a compact "Title · Artist". Mirrors the Omarchy bar widget's
/// glyph/label logic (BarWidget.qml around line 1030).
public struct MenuBarLabel: View {
    private let engine: PlayerEngine

    public init(engine: PlayerEngine) {
        self.engine = engine
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: glyph)
            if !compactTitle.isEmpty {
                Text(compactTitle).lineLimit(1)
            }
        }
    }

    private var glyph: String {
        if engine.isLoading { return "arrow.triangle.2.circlepath" }
        if engine.selectedIndex < 0 { return "music.note" }
        return engine.isPlaying ? "pause.fill" : "play.fill"
    }

    private var compactTitle: String {
        guard engine.selectedIndex >= 0 else { return "" }
        let artist = engine.artist.isEmpty || engine.artist == "No Artist" ? "" : " · \(engine.artist)"
        return "\(engine.title)\(artist)"
    }
}
