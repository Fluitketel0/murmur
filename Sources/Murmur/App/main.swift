import AppKit

// Start in whatever the visibility setting calls for: accessory (no Dock icon) ONLY
// when "Menu bar only" is selected; otherwise a regular app with a Dock icon. We decide
// this in code rather than via LSUIElement in Info.plist, so the app is still indexed by
// Spotlight / Raycast as a launchable app. AppDelegate keeps it in sync afterwards
// (e.g. switching to .regular while a window is open).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(Settings.appVisibility.keepsDockIcon ? .regular : .accessory)
app.run()
