import AppKit

// Entry point for the SPM executable: boot AppKit without NIB. AppKit is
// main-thread-only, so make that isolation explicit to Swift 6.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    app.run()
}
