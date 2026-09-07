import AppKit
import SwiftUI
import MacMusicPluginKit

/// Owns the menu-bar status item directly rather than through `MenuBarExtra`.
/// SwiftUI's `MenuBarExtra` gives no hook for secondary clicks, so we manage an
/// `NSStatusItem` ourselves: a left-click toggles the player panel, a
/// right-click (or control-click) hides/shows the title, collapsing the item to
/// just the transport glyph. The choice is remembered in `UserDefaults`.
@MainActor
final class StatusItemController {
    static let showsTitleKey = "menuBarShowsTitle"

    private let engine: PlayerEngine
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    init(engine: PlayerEngine) {
        self.engine = engine
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: PlayerPanel(engine: engine))

        if let button = statusItem.button {
            let host = LabelHostingView(rootView: MenuBarLabel(engine: engine))
            host.sizingOptions = .intrinsicContentSize
            host.autoresizingMask = [.width, .height]
            host.onResize = { [weak self] width in self?.statusItem.length = width }
            host.frame = button.bounds
            button.addSubview(host)

            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)

        if isSecondary {
            let defaults = UserDefaults.standard
            let shown = defaults.object(forKey: Self.showsTitleKey) as? Bool ?? true
            defaults.set(!shown, forKey: Self.showsTitleKey)
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

/// An `NSHostingView` that reports its width whenever SwiftUI relays it out, so
/// the status item can be resized to fit the current label.
private final class LabelHostingView<Content: View>: NSHostingView<Content> {
    var onResize: ((CGFloat) -> Void)?
    private var lastReported: CGFloat = -1

    override func layout() {
        super.layout()
        let width = fittingSize.width
        guard width > 0, abs(width - lastReported) > 0.5 else { return }
        lastReported = width
        onResize?(width)
    }
}
