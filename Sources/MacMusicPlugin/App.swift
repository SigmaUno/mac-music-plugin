import SwiftUI
import MacMusicPluginKit

@main
struct MacMusicPluginApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PlayerPanel(engine: appDelegate.engine)
        } label: {
            MenuBarLabel(engine: appDelegate.engine)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns process-lifetime setup and teardown. `MenuBarExtra` alone gives no hook
/// for "app is launching" / "app is quitting", which is where directories are
/// created, the library is seeded, and the engine is started and stopped.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let library = LibraryStore()
    lazy var engine = PlayerEngine(library: library)

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
        Paths.clearVolatile()
    }
}
