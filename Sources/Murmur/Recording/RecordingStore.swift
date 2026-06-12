import Foundation

/// One recording's metadata, as persisted in the journal.
///
/// On disk each recording is a self-contained folder under `Recordings/`:
/// ```
/// Recordings/2026-05-31-171530/
///     audio.caf        the audio
///     transcript.md    YAML frontmatter + transcript (human- and agent-readable)
/// ```
struct Recording: Codable, Identifiable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case recording   // in progress (or orphaned by a crash if seen at launch)
        case finished    // cleanly stopped
        case recovered   // was in progress at a crash; finalized on next launch
    }

    enum Transcription: String, Codable, Sendable {
        case none        // not transcribed yet
        case running     // transcription in progress
        case done        // transcript available
        case failed      // transcription errored; can retry
    }

    /// Where the audio came from. Drives how the transcript is exported (memos get a
    /// plain body; meetings/imports get timestamped, eventually speaker-labelled,
    /// segments).
    enum Source: String, Codable, Sendable {
        case memo
        case dictation
        case meeting
        case imported   // a file the user dropped in; we link to it, never copy it
    }

    let id: UUID
    var folder: String
    var startedAt: Date
    var finishedAt: Date?
    var status: Status
    var source: Source = .memo
    var transcription: Transcription = .none
    var transcript: String?
    var title: String?
    var summary: String?
    /// Set for sources that keep no audio (dictation); otherwise read from the file.
    var durationSeconds: Double?
    /// For meetings: the app whose audio was captured (e.g. "zoom.us", "Safari").
    var sourceApp: String?
    /// For imports: the original file's path. We link to it rather than copy it.
    var originalPath: String?
    /// For meetings: the wall-clock instant each track actually started capturing. The
    /// two engines start a few ms apart, so these let us align both tracks to a common
    /// t=0 before interleaving turns (otherwise near-boundary turns can mis-order).
    var micStartedAt: Date?
    var systemStartedAt: Date?
    /// When the recording was moved to Recently Deleted (soft delete). Nil = active.
    /// Items linger here until restored or purged after the trash retention window.
    var deletedAt: Date?

    var dir: URL { Paths.recordings.appendingPathComponent(folder, isDirectory: true) }

    /// Meetings keep two tracks; everything else a single `audio.caf`.
    var micURL: URL { dir.appendingPathComponent("mic.caf") }
    var systemURL: URL { dir.appendingPathComponent("system.caf") }

    /// The audio to transcribe: mic track for meetings, the linked original for
    /// imports, otherwise the folder's `audio.caf`.
    var url: URL {
        switch source {
        case .meeting: return micURL
        case .imported: return originalPath.map { URL(fileURLWithPath: $0) }
            ?? dir.appendingPathComponent("audio.caf")
        default: return dir.appendingPathComponent("audio.caf")
        }
    }
    var transcriptURL: URL { dir.appendingPathComponent("transcript.md") }

    var displayName: String { title ?? Self.dateFormatter.string(from: startedAt) }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()
}

/// The previous flat layout (`Recordings/<timestamp>.caf` + `.txt`), read only to
/// migrate old journals into the folder-per-recording layout.
private struct LegacyRecording: Decodable {
    let id: UUID
    let filename: String
    let startedAt: Date
    var finishedAt: Date?
    let status: Recording.Status
    var transcription: Recording.Transcription?
    var transcript: String?

    func migrated() -> Recording {
        Recording(id: id,
                  folder: (filename as NSString).deletingPathExtension,
                  startedAt: startedAt,
                  finishedAt: finishedAt,
                  status: status,
                  source: .memo,
                  transcription: transcription ?? .none,
                  transcript: transcript,
                  title: transcript.map(RecordTitle.make))
    }
}

/// Crash-safe journal of recordings. Writes a small JSON file (`journal.json`)
/// mirroring what is on disk, so a crash mid-recording leaves a clear trail to
/// recover from on the next launch.
///
/// This is the macOS-native equivalent of a write-ahead log: mark intent
/// (`status: recording`) *before* writing audio, then mark completion on a clean
/// stop. Anything still `recording` at launch is an orphan from a crash.
@MainActor
final class RecordingStore {
    /// Everything we track, active and trashed. The journal persists this whole list;
    /// callers see the filtered views below.
    private var entries: [Recording] = []

    /// How long trashed recordings linger in Recently Deleted before being purged.
    static let trashRetention: TimeInterval = 30 * 86_400

    /// Active (not-deleted) recordings.
    var recordings: [Recording] { entries.filter { $0.deletedAt == nil } }
    /// Recordings sitting in Recently Deleted.
    var deletedRecordings: [Recording] { entries.filter { $0.deletedAt != nil } }

    init() {
        load()
        migrateFilesIfNeeded()
        normalizeFolderNames()   // one-time: unify old naming eras to <date>_<time>[_id]
    }

    // MARK: Mutations

    func beginRecording(source: Recording.Source = .memo, sourceApp: String? = nil) -> Recording {
        let id = UUIDv7.generate()
        let folder = Self.folderName(for: id)
        var rec = Recording(id: id, folder: folder, startedAt: Date(),
                            finishedAt: nil, status: .recording, source: source)
        rec.sourceApp = sourceApp
        // Meetings get a stable title up front (the transcript starts with section
        // headings, which wouldn't make a good auto-title).
        if source == .meeting {
            rec.title = "Meeting" + (sourceApp.map { " · \($0)" } ?? "")
        }
        makeFolder(for: rec)
        entries.append(rec)
        save()
        return rec
    }

    /// Create a recording's folder, logging a failure (disk full, permissions) rather
    /// than swallowing it: a silent failure could let a later same-second recording
    /// reuse the name and overwrite this one.
    private func makeFolder(for rec: Recording) {
        do {
            try FileManager.default.createDirectory(at: rec.dir, withIntermediateDirectories: true)
        } catch {
            Log.error("Failed to create folder \(rec.folder): \(error.localizedDescription)")
        }
    }

    /// Register an imported file: a finished, transcribe-pending record that *links*
    /// to the original (no audio copied). The folder holds only `transcript.md`.
    func beginImport(originalURL: URL) -> Recording {
        let id = UUIDv7.generate()
        let folder = Self.folderName(for: id)
        var rec = Recording(id: id, folder: folder, startedAt: Date(),
                            finishedAt: Date(), status: .finished, source: .imported)
        rec.originalPath = originalURL.path
        rec.title = originalURL.deletingPathExtension().lastPathComponent
        makeFolder(for: rec)
        entries.append(rec)
        save()
        return rec
    }

    func finishRecording(_ id: UUID) {
        update(id) { rec in
            rec.status = .finished
            rec.finishedAt = Date()
        }
    }

    /// Find recordings left `recording` by a previous crash. The audio is already
    /// on disk (CAF stays readable mid-write); we just finalize the bookkeeping.
    /// An orphan with no audio file (crashed before the first buffer was written) is
    /// dropped rather than surfaced as a permanently-broken row.
    func recoverOrphans() -> [Recording] {
        var recovered: [Recording] = []
        let orphans = entries.filter { $0.status == .recording }
        for rec in orphans {
            guard FileManager.default.fileExists(atPath: rec.url.path) else {
                Log.error("Orphan \(rec.folder) had no audio file; removing")
                delete(rec.id)
                continue
            }
            update(rec.id) { r in
                r.status = .recovered
                r.finishedAt = r.finishedAt ?? Date()
            }
            if let r = entries.first(where: { $0.id == rec.id }) {
                recovered.append(r)
                Log.info("Recovered orphaned recording \(r.folder)")
            }
        }
        return recovered
    }

    /// Reset any transcription left `.running` by a crash back to `.none`, so the
    /// launch retry actually re-runs it. The retry path skips `.running` entries, so
    /// without this a crash mid-transcription would stick on "Transcribing…" forever.
    func demoteRunningTranscriptions() {
        for rec in entries where rec.transcription == .running {
            update(rec.id) { $0.transcription = .none }
            Log.info("Reset stuck transcription for \(rec.folder)")
        }
    }

    func setTranscriptionStatus(_ id: UUID, _ status: Recording.Transcription) {
        update(id) { $0.transcription = status }
    }

    /// Update the transcript text mid-transcription without marking it done.
    func setPartialTranscript(_ id: UUID, text: String) {
        update(id) { $0.transcript = text }
    }

    func setTranscript(_ id: UUID, text: String) {
        update(id) { rec in
            rec.transcript = text
            rec.transcription = .done
        }
        finalizeAndExport(id)   // write transcript.md + refresh INDEX.md
    }

    /// Update a meeting's detected source app (and its title) mid-recording.
    func updateSourceApp(_ id: UUID, app: String) {
        update(id) { rec in
            guard rec.sourceApp != app else { return }
            rec.sourceApp = app
            if rec.source == .meeting { rec.title = "Meeting · \(app)" }
        }
    }

    func setSummary(_ id: UUID, text: String) {
        update(id) { $0.summary = text }
        finalizeAndExport(id)   // rewrite transcript.md + index.yaml with the summary
    }

    /// Persist a dictation as a text-only record (no audio kept): a folder with just
    /// `transcript.md`, listed in Recent and the index like any recording.
    @discardableResult
    func addDictation(text: String, duration: TimeInterval, targetApp: String? = nil) -> UUID {
        let id = UUIDv7.generate()
        let folder = Self.folderName(for: id)
        var rec = Recording(id: id, folder: folder,
                            startedAt: Date().addingTimeInterval(-duration),
                            finishedAt: Date(), status: .finished, source: .dictation,
                            transcription: .done, transcript: text)
        rec.title = RecordTitle.make(from: text)
        rec.durationSeconds = duration
        rec.sourceApp = targetApp   // the app the text was typed into
        makeFolder(for: rec)
        entries.append(rec)
        save()
        writeMarkdown(for: rec)
        regenerateIndex()
        return id
    }

    func recording(_ id: UUID) -> Recording? {
        entries.first { $0.id == id }
    }

    /// Permanently remove a recording: delete its folder and forget it. Used for
    /// already-empty records (failed/silent meetings) and for emptying the trash.
    func delete(_ id: UUID) {
        if let rec = entries.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: rec.dir)
        }
        entries.removeAll { $0.id == id }
        save()
        regenerateIndex()
    }

    // MARK: Recently Deleted (soft delete)

    /// Move a recording to Recently Deleted. The folder stays on disk; the record is
    /// flagged so it drops out of the active lists and the index.
    func softDelete(_ id: UUID) {
        update(id) { if $0.deletedAt == nil { $0.deletedAt = Date() } }
        regenerateIndex()
    }

    /// Bring a recording back from Recently Deleted.
    func restore(_ id: UUID) {
        update(id) { $0.deletedAt = nil }
        if let rec = recording(id) { writeMarkdown(for: rec) }
        regenerateIndex()
    }

    /// Permanently remove everything currently in Recently Deleted.
    func emptyTrash() {
        for rec in deletedRecordings {
            try? FileManager.default.removeItem(at: rec.dir)
        }
        entries.removeAll { $0.deletedAt != nil }
        save()
        regenerateIndex()
    }

    /// Apply retention: move recordings older than the chosen period into Recently
    /// Deleted, and permanently purge trashed items past the trash window. Run at launch.
    func runRetention(autoDeleteAfter: AutoDeletePeriod) {
        let now = Date()
        if let maxAge = autoDeleteAfter.seconds {
            for rec in recordings where now.timeIntervalSince(rec.startedAt) > maxAge {
                update(rec.id) { if $0.deletedAt == nil { $0.deletedAt = now } }
                Log.info("Auto-moved \(rec.folder) to Recently Deleted (older than \(autoDeleteAfter.displayName))")
            }
        }
        let purge = deletedRecordings.filter {
            ($0.deletedAt.map { now.timeIntervalSince($0) } ?? 0) > Self.trashRetention
        }
        for rec in purge {
            try? FileManager.default.removeItem(at: rec.dir)
            Log.info("Purged \(rec.folder) from Recently Deleted (past 30-day window)")
        }
        if !purge.isEmpty { entries.removeAll { rec in purge.contains { $0.id == rec.id } } }
        save()
        regenerateIndex()
    }

    // MARK: Persistence

    func update(_ id: UUID, _ mutate: (inout Recording) -> Void) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        mutate(&entries[idx])
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.journal) else { return }
        if let recs = try? Self.decoder.decode([Recording].self, from: data) {
            entries = recs
        } else if let legacy = try? Self.decoder.decode([LegacyRecording].self, from: data) {
            entries = legacy.map { $0.migrated() }
            save()
            Log.info("Migrated \(entries.count) recording(s) to the folder layout")
        } else {
            // Starting with an empty list means the next save() would overwrite the
            // unreadable journal and lose every recording's metadata for good. Keep a
            // copy aside so it can still be inspected and recovered by hand.
            let backup = Paths.appSupport.appendingPathComponent("journal.unreadable.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: Paths.journal, to: backup)
            Log.error("Failed to read journal (unrecognized format); copied to \(backup.lastPathComponent)")
        }
    }

    func save() {
        do {
            let data = try Self.encoder.encode(entries)
            try data.write(to: Paths.journal, options: .atomic)
        } catch {
            Log.error("Failed to write journal: \(error.localizedDescription)")
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static let folderFormatter: DateFormatter = {
        let f = DateFormatter()
        // Underscores separate the parts: <date>_<time>[_<disambiguator>].
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    /// A timestamp folder name (`2026-05-31_171530`). Only if that already exists
    /// (two recordings in the same second) do we disambiguate with a short tail of
    /// the UUID, separated by an underscore, so names stay clean in the common case.
    static func folderName(for id: UUID) -> String {
        let base = folderFormatter.string(from: Date())
        let dir = Paths.recordings.appendingPathComponent(base)
        guard FileManager.default.fileExists(atPath: dir.path) else { return base }
        return "\(base)_\(id.uuidString.suffix(4).lowercased())"
    }
}
