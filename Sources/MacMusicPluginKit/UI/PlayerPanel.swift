import SwiftUI

/// The popover shown when the menu bar item is clicked. Over the milestones this
/// grows into the full now-playing / transport / library panel that mirrors the
/// Omarchy plugin's `PopupCard`.
///
/// Milestone 1: placeholder shell with the paths it will use, plus Quit.
public struct PlayerPanel: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Mac Music Plugin")
                    .font(.headline)
            }

            Text("Nothing playing")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            Text("Library: \(Paths.library.path)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)

            Divider()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(16)
    }
}
