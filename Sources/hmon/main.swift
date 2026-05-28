import AppKit

// Allow `hmon --disable-login` to cleanly unregister the login item during uninstall.
if CommandLine.arguments.contains("--disable-login") {
    LaunchAtLogin.setEnabled(false)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
