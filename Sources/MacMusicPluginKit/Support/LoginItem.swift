import Foundation
import ServiceManagement

/// "Open at Login" backed by `SMAppService.mainApp`. Only works from a real
/// signed `.app` bundle (`scripts/bundle.sh` ad-hoc signs one); from a bare
/// `swift run` the calls throw and `isEnabled` reports false.
public enum LoginItem {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app as a login item. Throws when run outside
    /// a bundle or when the user has denied login items in System Settings.
    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        }
    }
}
