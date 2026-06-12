@preconcurrency import AVFoundation
import Foundation

/// Agent- and human-facing exports: a self-describing `transcript.md` per recording
/// and a top-level `INDEX.md` manifest.
extension RecordingStore {
    /// Give a finished recording a title and write its `transcript.md`, then refresh
    /// the manifest. Safe to call repeatedly (idempotent overwrite).
    func finalizeAndExport(_ id: UUID) {
        guard let rec = recording(id) else { return }
        let title = rec.title ?? RecordTitle.make(from: rec.transcript)
        if rec.title != title { update(id) { $0.title = title } }
        // Compute and persist the audio duration once (for meetings/imports that don't
        // store it up front), so `regenerateIndex` doesn't reopen audio files every time.
        if rec.durationSeconds == nil {
            let seconds = duration(of: rec)
            if seconds > 0 { update(id) { $0.durationSeconds = seconds } }
        }
        writeMarkdown(for: recording(id) ?? rec)
        regenerateIndex()
    }

    /// Write the per-recording Markdown: YAML frontmatter + transcript body. Memos
    /// get a plain body; meetings/imports will additionally get a timestamped (and
    /// later speaker-labelled) segments section.
    func writeMarkdown(for rec: Recording) {
        let body = (rec.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = body.split(whereSeparator: \.isWhitespace).count

        var lines = ["---"]
        lines.append("id: \(rec.id.uuidString)")
        lines.append("title: \(yamlString(rec.title ?? "Untitled recording"))")
        if let summary = rec.summary { lines.append("summary: \(yamlString(summary))") }
        lines.append("created: \(Self.isoFormatter.string(from: rec.startedAt))")
        lines.append("duration_seconds: \(Int((rec.durationSeconds ?? duration(of: rec)).rounded()))")
        lines.append("source: \(rec.source.rawValue)")
        if let app = rec.sourceApp { lines.append("app: \(yamlString(app))") }
        lines.append("words: \(wordCount)")
        // Imports link to the original file (not copied); others reference the
        // audio captured in this folder.
        if rec.source == .imported, let path = rec.originalPath {
            lines.append("source_file: \(yamlString(path))")
        } else {
            lines.append("audio: \(rec.url.lastPathComponent)")
        }
        lines.append("---")
        lines.append("")
        if let summary = rec.summary { lines.append("> \(summary)"); lines.append("") }
        lines.append(body.isEmpty ? "_(no speech detected)_" : body)
        lines.append("")

        let markdown = lines.joined(separator: "\n")
        try? markdown.write(to: rec.transcriptURL, atomically: true, encoding: .utf8)
    }

    /// Regenerate the manifest: a YAML list an agent (or you) reads first to decide
    /// what to open. Newest first. Human-readable and trivially parseable.
    func regenerateIndex() {
        let sorted = recordings.sorted { $0.startedAt > $1.startedAt }
        var lines = [
            "# Murmur recordings index. Newest first.",
            "# Auto-generated; edit a recording's transcript.md instead of this file.",
            "",
        ]
        for rec in sorted {
            lines.append("- id: \(rec.id.uuidString)")
            lines.append("  date: \(Self.isoFormatter.string(from: rec.startedAt))")
            lines.append("  title: \(yamlString(rec.title ?? "Untitled recording"))")
            if let summary = rec.summary { lines.append("  summary: \(yamlString(summary))") }
            lines.append("  duration_seconds: \(Int((rec.durationSeconds ?? duration(of: rec)).rounded()))")
            lines.append("  source: \(rec.source.rawValue)")
            lines.append("  transcription: \(rec.transcription.rawValue)")
            lines.append("  folder: \(yamlString(rec.folder))")
            if rec.transcription == .done {
                lines.append("  transcript: \(yamlString(rec.folder + "/transcript.md"))")
            }
        }
        lines.append("")
        try? lines.joined(separator: "\n").write(to: Paths.index, atomically: true, encoding: .utf8)

        // Remove the old Markdown manifest if it's lingering from a previous version.
        try? FileManager.default.removeItem(at: Paths.recordings.appendingPathComponent("INDEX.md"))
    }

    /// One-time migration of any recordings still in the old flat layout into the
    /// folder layout, then (re)export finished ones and rebuild the manifest.
    /// Conservative: only moves a file when its destination doesn't already exist.
    func migrateFilesIfNeeded() {
        let fm = FileManager.default
        for rec in recordings where !fm.fileExists(atPath: rec.url.path) {
            let legacyAudio = Paths.recordings.appendingPathComponent(rec.folder + ".caf")
            guard fm.fileExists(atPath: legacyAudio.path) else { continue }
            try? fm.createDirectory(at: rec.dir, withIntermediateDirectories: true)
            try? fm.moveItem(at: legacyAudio, to: rec.url)
            let legacyText = Paths.recordings.appendingPathComponent(rec.folder + ".txt")
            if fm.fileExists(atPath: legacyText.path) {
                try? fm.moveItem(at: legacyText, to: rec.transcriptURL)
            }
            Log.info("Migrated \(rec.folder) into folder layout")
        }
        // Re-export only what's missing or incomplete. Unconditionally re-exporting
        // every finished recording would rewrite each transcript.md and regenerate the
        // index once per recording on every launch - I/O that grows with history size.
        for rec in recordings where rec.transcription == .done {
            if rec.durationSeconds == nil || !fm.fileExists(atPath: rec.transcriptURL.path) {
                finalizeAndExport(rec.id)
            }
        }
        regenerateIndex()
    }

    /// One-time normalization of folder names to the underscore scheme
    /// `<date>_<time>[_<id>]`. Earlier builds used `<date>-<time>` and, before that,
    /// `<date>T<HHmm>-<hex>`; this unifies all of them so the Recordings folder reads
    /// consistently. A pure rename (keeps the timestamp), only when the destination is
    /// free; skips anything already in the new format.
    func normalizeFolderNames() {
        let fm = FileManager.default
        // Include trashed recordings: their folders are still on disk, so a rename
        // must not collide with them either.
        var taken = Set((recordings + deletedRecordings).map(\.folder))
        var changed = false
        for rec in recordings {
            let canonical = Self.canonicalFolderName(rec.folder)
            guard canonical != rec.folder, !taken.contains(canonical) else { continue }
            let src = Paths.recordings.appendingPathComponent(rec.folder, isDirectory: true)
            let dst = Paths.recordings.appendingPathComponent(canonical, isDirectory: true)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            do {
                try fm.moveItem(at: src, to: dst)
                taken.remove(rec.folder); taken.insert(canonical)
                update(rec.id) { $0.folder = canonical }
                changed = true
                Log.info("Renamed folder \(rec.folder) → \(canonical)")
            } catch {
                Log.error("Folder rename failed for \(rec.folder): \(error.localizedDescription)")
            }
        }
        // `update()` already saved the journal on each rename; just refresh the index.
        if changed { regenerateIndex() }
    }

    /// Rewrite a legacy folder name to `<date>_<time>[_<id>]`. Matches both the
    /// `2026-06-01-074535[-ABCD]` and `2026-06-01T0717[-e934]` shapes; leaves names
    /// that don't match (already normalized, or unexpected) untouched.
    static func canonicalFolderName(_ name: String) -> String {
        let pattern = "^(\\d{4}-\\d{2}-\\d{2})[-T](\\d{4,6})(?:[-_]([0-9A-Za-z]+))?$"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let dateR = Range(m.range(at: 1), in: name),
              let timeR = Range(m.range(at: 2), in: name)
        else { return name }
        let date = String(name[dateR]), time = String(name[timeR])
        var out = "\(date)_\(time)"
        if let sufR = Range(m.range(at: 3), in: name) {
            out += "_\(name[sufR].lowercased())"
        }
        return out
    }

    // MARK: Helpers

    private func duration(of rec: Recording) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: rec.url) else { return 0 }
        let rate = file.fileFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : 0
    }

    /// Quote a string for YAML, escaping embedded quotes/backslashes and flattening
    /// any newlines (titles/summaries are single-line).
    private func yamlString(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
