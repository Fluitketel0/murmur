import AppKit

// Menu-bar app: start as an accessory (no Dock icon, no window). We set this in code
// rather than via LSUIElement in Info.plist, so the app is still indexed by Spotlight /
// Raycast as a launchable app. AppDelegate may switch to .regular per the visibility
// setting / when a window opens.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
