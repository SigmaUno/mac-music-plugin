import SwiftUI
import MacMusicPluginKit

@main
struct MacMusicPluginApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PlayerPanel()
                .frame(width: 380)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns process-lifetime setup and teardown. `MenuBarExtra` alone gives no hook
/// for "app is launching" / "app is quitting", which is where the on-disk
/// directories are created and the volatile ones are swept.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.bootstrap()
        Paths.clearVolatile()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Paths.clearVolatile()
    }
}
