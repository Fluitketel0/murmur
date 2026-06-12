import AppKit
import Sparkle

/// Thin wrapper over Sparkle's standard updater. Automatic background checks and silent
/// installation are configured in Info.plist (`SUEnableAutomaticChecks` /
/// `SUAutomaticallyUpdate` / `SUFeedURL` / `SUPublicEDKey`); this also exposes a manual
/// "Check for Updates" action and the controller a menu item can target directly.
@MainActor
final class AppUpdater {
    let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true kicks off the scheduled background checks immediately.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    /// Build a menu item wired to Sparkle's manual check (with its own validation).
    func makeMenuItem(title: String = "Check for Updates…") -> NSMenuItem {
        let item = NSMenuItem(title: title,
                              action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                              keyEquivalent: "")
        item.target = controller
        return item
    }
}
