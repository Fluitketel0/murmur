import Foundation
import Observation
import SwiftUI

/// Observable bridge between the SwiftUI window and `AppCoordinator`. SwiftUI views
/// read `recordings` and the mirrored settings here; writes are routed back through
/// the coordinator (the single interface to the app's moving parts), so the menu-bar
/// UI and the window stay in agreement.
///
/// Settings are mirrored as stored properties (not computed pass-throughs) so the
/// Observation framework actually tracks them and re-renders on change. `sync()`
/// refreshes the mirrors from the source of truth whenever app state changes
/// (including changes made from the menu bar); the `refreshing` guard keeps those
/// refreshes from looping back through the write-through side effects.
@MainActor
@Observable
final class AppModel {
    @ObservationIgnored let coordinator: AppCoordinator
    @ObservationIgnored private var refreshing = false

    /// Recordings, newest first, mirrored from the store.
    var recordings: [Recording] = []
    /// Recently-deleted recordings, newest-deleted first.
    var deletedRecordings: [Recording] = []

    /// Which sidebar pane is selected; settable from the menu bar so "Settings…" can
    /// open straight to the right pane.
    var tab: Tab = .history

    enum Tab: Hashable { case history, importFiles, recentlyDeleted, settings }

    /// Window content zoom (⌘= / ⌘- / ⌘0). A plain multiplier on our font sizes -
    /// macOS ignores `dynamicTypeSize` for this kind of content, so we scale fonts
    /// ourselves (see `FontScale`/`scaledFont`). 1.0 = normal.
    var fontScale: CGFloat = 1.0
    func zoomIn() { setZoom(fontScale * 1.1) }
    func zoomOut() { setZoom(fontScale / 1.1) }
    func resetZoom() { fontScale = 1.0 }

    private func setZoom(_ value: CGFloat) {
        fontScale = min(max(value, 0.8), 2.0)
    }

    // Mirrored settings (write-through to the coordinator / Settings on change).
    var removeFillers = Settings.removeFillers {
        didSet { guard !refreshing else { return }; Settings.removeFillers = removeFillers; coordinator.onStateChange?() }
    }
    var polishTranscripts = Settings.polishTranscripts {
        didSet { guard !refreshing else { return }; Settings.polishTranscripts = polishTranscripts; coordinator.onStateChange?() }
    }
    var pauseMusicWhileDictating = Settings.pauseMusicWhileDictating {
        didSet { guard !refreshing else { return }; Settings.pauseMusicWhileDictating = pauseMusicWhileDictating; coordinator.onStateChange?() }
    }
    var labelSpeakers = Settings.labelSpeakers {
        didSet { guard !refreshing else { return }; Settings.labelSpeakers = labelSpeakers; coordinator.onStateChange?() }
    }
    var dictationEnabled = false {
        didSet {
            guard !refreshing, dictationEnabled != coordinator.dictationEnabled else { return }
            coordinator.toggleDictation()
            coordinator.armMeetingHotkey()
        }
    }
    var dictationShortcut = Settings.dictationShortcut {
        didSet { guard !refreshing, dictationShortcut != oldValue else { return }; coordinator.setDictationShortcut(dictationShortcut) }
    }
    var meetingShortcut = Settings.meetingShortcut {
        didSet { guard !refreshing, meetingShortcut != oldValue else { return }; coordinator.setMeetingShortcut(meetingShortcut) }
    }
    var dictationMode = Settings.dictationMode {
        didSet { guard !refreshing, dictationMode != oldValue else { return }; coordinator.setDictationMode(dictationMode) }
    }
    var launchAtLogin = LoginItem.isEnabled {
        didSet { guard !refreshing else { return }; LoginItem.setEnabled(launchAtLogin) }
    }
    var appVisibility = Settings.appVisibility {
        didSet { guard !refreshing, appVisibility != oldValue else { return }; Settings.appVisibility = appVisibility; coordinator.onStateChange?() }
    }
    var autoCopyToClipboard = Settings.autoCopyToClipboard {
        didSet { guard !refreshing else { return }; Settings.autoCopyToClipboard = autoCopyToClipboard }
    }
    var soundEffects = Settings.soundEffects {
        didSet { guard !refreshing else { return }; Settings.soundEffects = soundEffects }
    }
    var autoDeleteAfter = Settings.autoDeleteAfter {
        didSet { guard !refreshing, autoDeleteAfter != oldValue else { return }; Settings.autoDeleteAfter = autoDeleteAfter }
    }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        sync()
    }

    /// Pull every mirrored value back from the source of truth. Called on each app
    /// state change so the window reflects actions taken from the menu bar too.
    func sync() {
        refreshing = true
        defer { refreshing = false }
        // Assign only what actually changed. `sync()` fires on every state change,
        // including once per VAD segment during a transcription; the Observation macro
        // notifies on every set regardless of equality, so unconditional reassignment
        // would re-render any open window at segment cadence. (Direct `if x != new`
        // rather than an inout helper, since inout on an @Observable property can fire
        // the modify accessor's mutation even without a write.)
        let recs = coordinator.store.recordings.sorted { $0.startedAt > $1.startedAt }
        if recordings != recs { recordings = recs }
        let deleted = coordinator.store.deletedRecordings
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        if deletedRecordings != deleted { deletedRecordings = deleted }
        if removeFillers != Settings.removeFillers { removeFillers = Settings.removeFillers }
        if polishTranscripts != Settings.polishTranscripts { polishTranscripts = Settings.polishTranscripts }
        if pauseMusicWhileDictating != Settings.pauseMusicWhileDictating { pauseMusicWhileDictating = Settings.pauseMusicWhileDictating }
        if labelSpeakers != Settings.labelSpeakers { labelSpeakers = Settings.labelSpeakers }
        if dictationEnabled != coordinator.dictationEnabled { dictationEnabled = coordinator.dictationEnabled }
        if dictationShortcut != Settings.dictationShortcut { dictationShortcut = Settings.dictationShortcut }
        if meetingShortcut != Settings.meetingShortcut { meetingShortcut = Settings.meetingShortcut }
        if dictationMode != Settings.dictationMode { dictationMode = Settings.dictationMode }
        if launchAtLogin != LoginItem.isEnabled { launchAtLogin = LoginItem.isEnabled }
        if appVisibility != Settings.appVisibility { appVisibility = Settings.appVisibility }
        if autoCopyToClipboard != Settings.autoCopyToClipboard { autoCopyToClipboard = Settings.autoCopyToClipboard }
        if soundEffects != Settings.soundEffects { soundEffects = Settings.soundEffects }
        if autoDeleteAfter != Settings.autoDeleteAfter { autoDeleteAfter = Settings.autoDeleteAfter }
    }

    // MARK: Per-recording actions (routed to the coordinator)

    func copyTranscript(_ id: UUID) { coordinator.copyTranscript(id) }
    func revealInFinder(_ id: UUID) { coordinator.revealInFinder(id) }
    /// Move to Recently Deleted (restorable), not a permanent delete.
    func delete(_ id: UUID) { coordinator.softDelete(id) }
    /// Move many to Recently Deleted at once (bulk delete from History).
    func delete(_ ids: [UUID]) { coordinator.softDelete(ids) }
    func restore(_ id: UUID) { coordinator.restore(id) }
    func deletePermanently(_ id: UUID) { coordinator.deletePermanently(id) }
    func emptyTrash() { coordinator.emptyTrash() }
    func transcribe(_ id: UUID) { coordinator.transcribe(id) }
    func importFile(_ url: URL) { coordinator.importFile(url) }
    func openRecordingsFolder() { coordinator.openRecordingsFolder() }

    var dictationTriggerDescription: String { coordinator.dictationTrigger }

    func resetDictationShortcut() { dictationShortcut = .fnHold }
    func resetMeetingShortcut() { meetingShortcut = .optCmdE }

    // MARK: Storage

    var storage = StorageInfo.Sizes()

    /// Recompute on-disk sizes when the Settings pane appears. The filesystem walk runs
    /// off the main actor so a cold cache (or a large model dir) doesn't stall the UI.
    func refreshStorage() {
        Task {
            let sizes = await Task.detached { StorageInfo.measure() }.value
            storage = sizes
        }
    }
}
