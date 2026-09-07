import SwiftUI
import MacMusicPluginKit

@main
struct MacMusicPluginApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Owns process-lifetime setup and teardown, and the menu-bar status item.
/// `MenuBarExtra` gave no hook for "app is launching" / "app is quitting" and no
/// way to see right-clicks, so the status item is managed directly by
/// `StatusItemController`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let library = LibraryStore()
    lazy var engine = PlayerEngine(library: library)
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.bootstrap()
        Paths.clearVolatile()
        do {
            try library.bootstrap()
            try library.rebuildStar()
        } catch {
            NSLog("MacMusicPlugin: library bootstrap failed: \(error)")
        }
        engine.start()
        statusItem = StatusItemController(engine: engine)
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
        Paths.clearVolatile()
    }
}
