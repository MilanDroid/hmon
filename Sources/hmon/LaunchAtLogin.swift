import Foundation
import ServiceManagement

/// Wraps SMAppService.mainApp so the popover can toggle launch-at-login.
/// Requires the binary to be running from inside a proper .app bundle.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do {
            if on {
                if SMAppService.mainApp.status == .enabled { return true }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("hmon: launch-at-login toggle failed: \(error)")
            return false
        }
    }
}
