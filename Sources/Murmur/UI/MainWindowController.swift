import AppKit
import SwiftUI

/// Hosts the SwiftUI `MainView` in a single reusable AppKit window. The app is a
/// menu-bar (accessory) app, so there's no window by default; this is opened on
/// demand and kept alive (not released on close) so reopening is instant.
///
/// While the window is open we flip the app to a *regular* activation policy, so it
/// gains a Dock icon and shows its icon under the window in Mission Control / the app
/// switcher. When the window closes we drop back to *accessory* (menu-bar only).
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    /// Whether the window is currently on screen (drives the menu-bar-only Dock-icon
    /// policy: a Dock icon appears while the window is open, and goes away when closed).
    var isWindowVisible: Bool { window?.isVisible ?? false }

    /// Show the window (creating it on first use), selecting the given pane.
    func show(tab: AppModel.Tab? = nil) {
        if let tab { model.tab = tab }

        if window == nil {
            let hosting = NSHostingController(rootView: MainView(model: model))
            let win = NSWindow(contentViewController: hosting)
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            win.tabbingMode = .disallowed   // no window tabs (removes "Show Tab Bar" etc.)
            // Hide the title-bar text. SwiftUI renders a tab's title large/bold when its
            // content is a List but inline for the others, and won't reliably unify them,
            // so showing no title keeps every tab's title bar identical. The sidebar
            // already indicates the selected section. ("Murmur" is kept as the window's
            // internal title for the Window menu / Mission Control.)
            win.title = "Murmur"
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = false
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.setContentSize(NSSize(width: 1000, height: 620))
            win.center()
            win.setFrameAutosaveName("MurmurMainWindowV2")
            window = win
        }

        // Become a regular app so the window has a Dock icon + Mission Control label.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closing the window drops the Dock icon only in menu-bar-only mode; in Dock-only
    /// or Dock-and-menu-bar mode the app keeps its Dock presence.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(Settings.appVisibility.keepsDockIcon ? .regular : .accessory)
    }
}
