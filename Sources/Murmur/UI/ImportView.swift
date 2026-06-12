import SwiftUI
import UniformTypeIdentifiers

/// Drag-and-drop (or pick) audio files to transcribe them. Files are *linked*,
/// not copied (the original stays where it is); the transcript lands in History.
/// Built mainly for voice memos recorded on an iPhone, phone, or Mac.
///
/// Audio only: the pipeline reads files with AVAudioFile, which can't open movie
/// containers, so accepting video would just produce "Transcription failed" rows.
struct ImportView: View {
    @Bindable var model: AppModel
    @Environment(\.fontScale) private var scale
    @State private var isTargeted = false

    /// Audio formats we'll accept (Voice Memos export m4a).
    private static let acceptedTypes: [UTType] = [.audio]

    var body: some View {
        VStack(spacing: 20 * scale) {
            dropZone
            Text("Drop a voice memo or recording here, or choose a file. The original isn't moved. Murmur links to it and transcribes a copy of the audio. Your transcript appears in History.")
                .scaledFont(12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28 * scale)
        .navigationTitle("Import a file")
    }

    private var dropZone: some View {
        VStack(spacing: 14 * scale) {
            Image(systemName: "square.and.arrow.down")
                .scaledFont(40)
                .foregroundStyle(Brand.wave)
            Text("Drag an audio file here")
                .scaledFont(15, weight: .semibold)
            Button("Choose File…", action: chooseFile)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260 * scale)
        .background(
            RoundedRectangle(cornerRadius: 16 * scale)
                .fill(isTargeted ? Brand.accent.opacity(0.12) : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16 * scale)
                .strokeBorder(isTargeted ? Brand.accent : Color.secondary.opacity(0.3),
                              style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = urls.filter(Self.isAcceptable)
            for url in accepted { model.importFile(url) }
            if !accepted.isEmpty { model.tab = .history }
            return !accepted.isEmpty
        } isTargeted: { isTargeted = $0 }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.acceptedTypes
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { model.importFile(url) }
        if !panel.urls.isEmpty { model.tab = .history }
    }

    /// Accept by content type (a dropped URL may not carry a UTI, so fall back to a
    /// generous extension list covering common voice-memo / recording formats).
    private static func isAcceptable(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension),
           acceptedTypes.contains(where: { type.conforms(to: $0) }) {
            return true
        }
        let exts: Set<String> = ["m4a", "mp3", "wav", "aiff", "aifc", "caf", "aac",
                                 "flac", "ogg", "opus"]
        return exts.contains(url.pathExtension.lowercased())
    }
}
