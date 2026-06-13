import SwiftUI

/// The window's root: a fixed sidebar that switches between History, Import, Recently
/// Deleted, and Settings. Kept deliberately small - the app is driven mostly by the
/// global hotkey; this window is for browsing past recordings and changing settings
/// without hunting through the menu bar.
struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        // A fixed sidebar beside the detail, as a plain HStack rather than a
        // NavigationSplitView. The split view kept the divider draggable (its column-width
        // limits weren't enforced against a drag, so the sidebar could be widened until the
        // window grew off the left of the screen) and collapsible. A four-item nav list
        // needs neither: a fixed-width column can't be dragged or hidden, so the sidebar
        // always stays put and visible. The detail sits in a NavigationStack so its views
        // keep their titles and toolbars (Copy / Reveal / Delete).
        HStack(spacing: 0) {
            sidebar
                .frame(width: 193)
            Divider()
            // The window title bar shows no text (hidden in MainWindowController): SwiftUI
            // forces a large, bold title whenever a tab's content is a List (History,
            // Recently Deleted) but an inline one for the Form/VStack tabs, and won't
            // reliably let us unify them. The sidebar already shows the selected section,
            // so hiding the redundant title makes every tab's title bar identical.
            NavigationStack {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 840, minHeight: 520)
        .tint(Brand.accent)
        .environment(\.fontScale, model.fontScale)
    }

    private var sidebar: some View {
        List(selection: $model.tab) {
            Label("History", systemImage: "clock.arrow.circlepath")
                .tag(AppModel.Tab.history)
            Label("Import a file", systemImage: "square.and.arrow.down")
                .tag(AppModel.Tab.importFiles)
            Label {
                Text("Recently Deleted")
            } icon: {
                Image(systemName: "trash")
            }
            .badge(model.deletedRecordings.count)
            .tag(AppModel.Tab.recentlyDeleted)
            Label("Settings", systemImage: "gearshape")
                .tag(AppModel.Tab.settings)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.tab {
        case .history:         HistoryView(model: model)
        case .importFiles:     ImportView(model: model)
        case .recentlyDeleted: RecentlyDeletedView(model: model)
        case .settings:        SettingsView(model: model)
        }
    }
}
