import SwiftUI
import MacMusicPluginKit

@main
struct MacMusicPluginApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PlayerPanel(library: appDelegate.library)
                .frame(width: 380)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns process-lifetime setup and teardown. `MenuBarExtra` alone gives no hook
/// for "app is launching" / "app is quitting", which is where the on-disk
/// directories are created, the library is seeded, and volatile state is swept.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let library = LibraryStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.bootstrap()
        Paths.clearVolatile()
        do {
            try library.bootstrap()
            try library.rebuildStar()
        } catch {
            NSLog("MacMusicPlugin: library bootstrap failed: \(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Paths.clearVolatile()
    }
}
