import SwiftUI

/// Browsable list of every recording, with a search box and a source-type filter on
/// the left and a read-only detail pane on the right.
struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var filter: SourceFilter = .all
    @State private var selectedID: UUID?

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all, dictation, meeting, imported
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .dictation: return "Dictation"
            case .meeting: return "Meetings"
            case .imported: return "Imports"
            }
        }
        func matches(_ r: Recording) -> Bool {
            switch self {
            case .all: return true
            case .dictation: return r.source == .dictation
            case .meeting: return r.source == .meeting
            case .imported: return r.source == .imported || r.source == .memo
            }
        }
    }

    private var filtered: [Recording] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return model.recordings.filter { rec in
            guard filter.matches(rec) else { return false }
            guard !q.isEmpty else { return true }
            return rec.displayName.lowercased().contains(q)
                || (rec.transcript?.lowercased().contains(q) ?? false)
                || (rec.summary?.lowercased().contains(q) ?? false)
                || (rec.sourceApp?.lowercased().contains(q) ?? false)
        }
    }

    /// Filtered recordings grouped into day sections, newest day first.
    private var sections: [(day: Date, items: [Recording])] {
        let groups = Dictionary(grouping: filtered, by: \.dayStart)
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    var body: some View {
        // A fixed-width list beside a flexible detail, with no draggable divider. An
        // earlier nested HSplitView let the list be dragged wider than the window could
        // accommodate, which grew the window off the left edge of the screen. With the
        // list pinned, resizing the window only resizes the detail pane.
        HStack(spacing: 0) {
            listColumn
                .frame(width: 340)
            Divider()
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search transcripts", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(8)

            Picker("", selection: $filter) {
                ForEach(SourceFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            Divider()

            if filtered.isEmpty {
                ContentUnavailableView(
                    model.recordings.isEmpty ? "No recordings yet" : "No matches",
                    systemImage: "waveform",
                    description: Text(model.recordings.isEmpty
                        ? "Dictate with your hotkey or record a meeting to get started."
                        : "Try a different search or filter."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                recordingsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var recordingsList: some View {
        List(selection: $selectedID) {
            ForEach(sections, id: \.day) { section in
                Section(Self.dayHeader(section.day)) {
                    ForEach(section.items) { rec in
                        row(for: rec)
                    }
                }
            }
        }
        .listStyle(.inset)
        // Open on the most recent recording rather than an empty detail pane (which
        // looks especially bare on a large or maximized window). Only when nothing is
        // already selected, so it never fights a selection the user made.
        .onAppear { if selectedID == nil { selectedID = filtered.first?.id } }
        // Delete the selected recording with the keyboard: the Delete key (the standard
        // list deletion), plus Command-Delete (Finder's "move to trash"). Soft delete,
        // so it's restorable from Recently Deleted.
        .onDeleteCommand(perform: deleteSelected)
        .onKeyPress(keys: [.delete]) { press in
            guard press.modifiers.contains(.command), selectedID != nil else { return .ignored }
            deleteSelected()
            return .handled
        }
    }

    private func row(for rec: Recording) -> some View {
        RecordingRow(rec: rec).tag(rec.id)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { deleteRow(rec.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
            .contextMenu {
                if rec.transcript?.isEmpty == false {
                    Button("Copy Transcript") { model.copyTranscript(rec.id) }
                }
                Button("Reveal in Finder") { model.revealInFinder(rec.id) }
                Divider()
                Button("Delete", role: .destructive) { deleteRow(rec.id) }
            }
    }

    /// Delete whatever row is selected (used by the Delete / Command-Delete shortcuts).
    private func deleteSelected() {
        if let id = selectedID { deleteRow(id) }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let id = selectedID, let rec = model.recordings.first(where: { $0.id == id }) {
            RecordingDetailView(rec: rec, model: model) { selectedID = nil }
        } else {
            ContentUnavailableView("Select a recording",
                                   systemImage: "doc.text.magnifyingglass",
                                   description: Text("Pick a recording to read its transcript."))
        }
    }

    /// Soft-delete a row, clearing the detail pane if it was the selected one.
    private func deleteRow(_ id: UUID) {
        if selectedID == id { selectedID = nil }
        model.delete(id)
    }

    private static func dayHeader(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(day, equalTo: Date(), toGranularity: .year)
            ? "EEEE, MMM d" : "MMM d, yyyy"
        return f.string(from: day)
    }
}

/// One row in the history list: source icon, title, one-line preview, and a compact
/// metadata footer (time · duration · app · words).
private struct RecordingRow: View {
    let rec: Recording
    @Environment(\.fontScale) private var scale

    var body: some View {
        HStack(alignment: .top, spacing: 10 * scale) {
            Image(systemName: rec.sourceSymbol)
                .scaledFont(14)
                .foregroundStyle(Brand.wave)
                .frame(width: 22 * scale, height: 22 * scale)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2 * scale) {
                Text(rec.displayName).scaledFont(13).lineLimit(1)
                Text(rec.previewLine)
                    .scaledFont(12).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6 * scale) {
                    Text(rec.startedAt, format: .dateTime.hour().minute())
                    metaDot
                    Text(rec.sourceLabel)
                    if let d = rec.durationText { metaDot; Text(d) }
                    if let app = rec.sourceApp {
                        metaDot
                        // For dictations the app is where the text was typed (arrow);
                        // for meetings it's whose audio was captured (speaker).
                        Image(systemName: rec.source == .dictation ? "arrow.right" : "speaker.wave.2.fill")
                        Text(app).lineLimit(1)
                    }
                    if rec.wordCount > 0 { metaDot; Text("\(rec.wordCount) words") }
                }
                .scaledFont(11).foregroundStyle(.tertiary)
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
            statusBadge
        }
        .padding(.vertical, 3)
    }

    private var metaDot: some View { Text("·").foregroundStyle(.quaternary) }

    @ViewBuilder
    private var statusBadge: some View {
        switch rec.transcription {
        case .running: ProgressView().controlSize(.small)
        case .failed:  Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:       EmptyView()
        }
    }
}
