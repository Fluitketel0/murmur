import SwiftUI

/// Read-only detail for a single recording: title, metadata, AI summary, the full
/// transcript (selectable), and actions to copy / reveal / delete.
struct RecordingDetailView: View {
    let rec: Recording
    @Bindable var model: AppModel
    var onDelete: () -> Void

    @State private var confirmingDelete = false
    @Environment(\.fontScale) private var scale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16 * scale) {
                header
                metadata
                if let s = rec.summary, !s.isEmpty { summaryCard(s) }
                Divider()
                transcriptBody
            }
            .padding(20 * scale)
            // Cap the reading column at a comfortable width and center it in the pane,
            // so a maximized window doesn't stretch the transcript edge to edge (long,
            // sparse lines). The inner maxWidth also bounds the text so it wraps instead
            // of overflowing. Mirrors how the Settings Form constrains its own width;
            // scales with the zoom level so the line length stays balanced when zoomed.
            .frame(maxWidth: 720 * scale, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .confirmationDialog("Move to Recently Deleted?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.delete(rec.id); onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can restore it from Recently Deleted for 30 days before it's removed for good.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10 * scale) {
            Image(systemName: rec.sourceSymbol)
                .scaledFont(20).foregroundStyle(Brand.wave)
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text(rec.displayName).scaledFont(20, weight: .bold)
                    .fixedSize(horizontal: false, vertical: true)
                Text(rec.startedAt, format: .dateTime.weekday(.wide).month().day().hour().minute())
                    .scaledFont(12).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            actions
        }
    }

    /// Copy / Reveal / (Transcribe) / Delete. Lives in the view's own header, not the
    /// window toolbar: a `.toolbar` only appears on this tab, so it changed the title
    /// bar's height between tabs and shifted the traffic lights. Here it has a fixed home.
    private var actions: some View {
        HStack(spacing: 12 * scale) {
            Button { model.copyTranscript(rec.id) } label: { Image(systemName: "doc.on.doc") }
                .disabled(rec.transcript?.isEmpty ?? true)
                .help("Copy transcript")
            Button { model.revealInFinder(rec.id) } label: { Image(systemName: "folder") }
                .help("Reveal in Finder")
            if rec.transcription == .failed || rec.transcription == .none {
                Button { model.transcribe(rec.id) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Transcribe")
            }
            Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                .help("Delete")
        }
        .buttonStyle(.borderless)
        .scaledFont(15)
        .foregroundStyle(.secondary)
    }

    private var metadata: some View {
        HStack(spacing: 8 * scale) {
            chip(rec.sourceLabel, "tag")
            if let d = rec.durationText { chip(d, "clock") }
            if let app = rec.sourceApp {
                chip(app, rec.source == .dictation ? "arrow.right.square" : "speaker.wave.2")
            }
            if rec.wordCount > 0 { chip("\(rec.wordCount) words", "text.alignleft") }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .scaledFont(11).foregroundStyle(.secondary)
            .padding(.horizontal, 8 * scale).padding(.vertical, 4 * scale)
            .background(.quaternary, in: Capsule())
    }

    private func summaryCard(_ summary: String) -> some View {
        HStack(alignment: .top, spacing: 8 * scale) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text(summary).scaledFont(12)
            Spacer(minLength: 0)
        }
        .padding(12 * scale)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10 * scale))
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if let t = rec.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            Text(t)
                .scaledFont(13)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if rec.transcription == .running {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Transcribing…").foregroundStyle(.secondary) }
        } else {
            Text("No transcript.").foregroundStyle(.secondary)
        }
    }
}
