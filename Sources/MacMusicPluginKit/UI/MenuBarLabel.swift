import SwiftUI

/// The item drawn in the system menu bar: a transport glyph and, when something
/// is loaded, a compact "Title · Artist". Mirrors the Omarchy bar widget's
/// glyph/label logic (BarWidget.qml around line 1030).
///
/// The title is capped at `maxTitleWidth` so a long track never pushes the rest
/// of the menu bar off-screen, and a right-click on the item hides it entirely
/// (`StatusItemController` flips the stored `menuBarShowsTitle` flag), leaving
/// just the transport glyph.
@MainActor
public struct MenuBarLabel: View {
    /// Widest the title is allowed to get before it tail-truncates, in points.
    static let maxTitleWidth: CGFloat = 260

    private let engine: PlayerEngine
    @AppStorage("menuBarShowsTitle") private var showsTitle = true

    public init(engine: PlayerEngine) {
        self.engine = engine
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: glyph)
            if showsTitle, !compactTitle.isEmpty {
                Text(compactTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.maxTitleWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
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
