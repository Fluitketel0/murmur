import AVFoundation
import AppKit
import ApplicationServices

/// Owns the app's moving parts and the recording lifecycle. The menu-bar UI talks
/// only to this object.
@MainActor
final class AppCoordinator {
    let store = RecordingStore()
    private let engine: TranscriptionEngine = ParakeetEngine()
    private let diarizer = Diarizer()

    private lazy var meeting: MeetingRecorder = {
        let m = MeetingRecorder()
        m.onLevel = { [weak self] level in
            Task { @MainActor in self?.onAudioLevel?(level) }
        }
        return m
    }()
    private var currentMeeting: Recording?
    /// Apps that actually produced audio during the current meeting (sampled while
    /// recording), used to label the source - more accurate than the frontmost window.
    private var meetingAudioApps: Set<String> = []
    private var sourceAppTimer: Timer?

    /// Toggles meeting recording. Default ⌥⌘E; user-configurable.
    private lazy var meetingHotkey: GlobalHotkey = makeMeetingHotkey()

    private func makeMeetingHotkey() -> GlobalHotkey {
        let h = GlobalHotkey(shortcut: Settings.meetingShortcut)
        h.onPress = { [weak self] in self?.toggleMeeting() }
        return h
    }

    private lazy var dictation: DictationController = {
        let d = DictationController(engine: engine)
        d.canStart = { [weak self] in
            guard let self else { return false }
            return !self.isMeetingRecording   // not while a meeting is recording
        }
        d.onStateChange = { [weak self] in self?.onStateChange?() }
        d.onLevel = { [weak self] level in self?.onAudioLevel?(level) }
        d.onTranscript = { [weak self] text, duration, targetApp in
            self?.saveDictation(text: text, duration: duration, targetApp: targetApp)
        }
        return d
    }()

    /// Fired whenever recording starts or stops, so the UI can refresh, including
    /// after the asynchronous microphone-permission prompt resolves.
    var onStateChange: (@MainActor () -> Void)?

    /// Live mic loudness (0...1) while recording or dictating, for the meter HUD.
    var onAudioLevel: (@MainActor (Float) -> Void)?

    var isMeetingRecording: Bool { meeting.isRecording }

    // MARK: Dictation

    var dictationEnabled: Bool { dictation.isEnabled }
    var isDictating: Bool { dictation.isDictating }
    /// A dictation has been captured and is being transcribed (the HUD stays up).
    var isFinishingDictation: Bool { dictation.isFinishing }
    var dictationTrigger: String { dictation.triggerDescription }

    /// Whether the speech model has finished loading. Drives the HUD's "Loading model"
    /// vs "Transcribing" message while a dictation is finishing.
    private(set) var engineReady = false

    func toggleDictation() {
        dictation.toggle()
        if dictation.isEnabled { prewarmEngine() }   // load the model before it's needed
    }

    /// Re-arm dictation at launch if it was enabled last session (silent; no prompt).
    func restoreDictation() {
        dictation.restoreIfPreviouslyEnabled()
        if dictation.isEnabled { prewarmEngine() }
    }

    /// Load the speech model in the background so the first dictation/transcription isn't
    /// stuck on a slow cold load (worst right after a reboot or macOS update, when CoreML
    /// recompiles for the Neural Engine). Idempotent and cheap to call repeatedly.
    func prewarmEngine() {
        guard !engineReady else { return }
        Task {
            // Only mark ready on success, so a failed load (e.g. the first-run model
            // download with no network) is retried the next time prewarm is called.
            engineReady = await engine.prewarm()
            onStateChange?()
        }
    }

    var dictationMode: DictationMode { Settings.dictationMode }

    func setDictationMode(_ mode: DictationMode) {
        Settings.dictationMode = mode
        onStateChange?()
    }

    /// Change the push-to-talk trigger shortcut. Rebuilds the event tap so the change
    /// takes effect immediately (even while dictation is enabled).
    func setDictationShortcut(_ shortcut: Shortcut) {
        dictation.setShortcut(shortcut)
        onStateChange?()
    }

    /// Change the meeting toggle shortcut, re-arming the tap if Accessibility allows.
    func setMeetingShortcut(_ shortcut: Shortcut) {
        guard shortcut != Settings.meetingShortcut else { return }
        Settings.meetingShortcut = shortcut
        meetingHotkey.stop()
        meetingHotkey = makeMeetingHotkey()
        armMeetingHotkey()
        onStateChange?()
    }

    var meetingShortcut: Shortcut { Settings.meetingShortcut }

    // MARK: Settings

    var fillerRemovalEnabled: Bool { Settings.removeFillers }

    func toggleFillerRemoval() {
        Settings.removeFillers.toggle()
        onStateChange?()
    }

    var speakerLabelsEnabled: Bool { Settings.labelSpeakers }

    func toggleSpeakerLabels() {
        Settings.labelSpeakers.toggle()
        onStateChange?()
    }

    /// Called once at launch: recover anything a previous crash left in progress,
    /// then resume any transcription that didn't finish.
    func recoverOrphansAtLaunch() {
        store.runRetention(autoDeleteAfter: Settings.autoDeleteAfter)
        // Free any transcription a crash left "running" so the retry below re-runs it.
        store.demoteRunningTranscriptions()
        let recovered = store.recoverOrphans()
        if !recovered.isEmpty {
            Log.info("Recovered \(recovered.count) recording(s) from a previous session")
        }
        retryPendingTranscriptions()
    }

    /// Re-enqueue any recording that has audio but no finished transcript. A crash
    /// during transcription leaves a `.running`/`.failed`/`.none` entry; this makes
    /// transcription self-heal on the next launch.
    private func retryPendingTranscriptions() {
        for rec in store.recordings where rec.transcription != .done {
            guard FileManager.default.fileExists(atPath: rec.url.path) else { continue }
            // Launch-retry, not a user action: don't play a sound or touch the clipboard.
            if rec.source == .meeting { transcribeMeeting(rec.id, userInitiated: false) }
            else { transcribe(rec.id, userInitiated: false) }
        }
    }

    func openRecordingsFolder() {
        NSWorkspace.shared.open(Paths.recordings)
    }

    // MARK: File import

    /// Import an audio file by linking to it (not copying) and transcribing it.
    /// Intended for a future UI; for now it's driven by opening a file with the app.
    func importFile(_ url: URL) {
        let rec = store.beginImport(originalURL: url)
        onStateChange?()
        transcribe(rec.id)
    }

    // MARK: Meeting capture (mic + system audio, two tracks)

    func toggleMeeting() {
        if isMeetingRecording { stopMeeting() } else { startMeeting() }
    }

    /// Arm the Hyper+R meeting hotkey if Accessibility is granted (the chord needs
    /// an active event tap). Silent and idempotent; the menu works regardless.
    func armMeetingHotkey() {
        guard !meetingHotkey.isRunning, AXIsProcessTrusted() else { return }
        _ = meetingHotkey.start()
    }

    func startMeeting() {
        guard !isDictating, !isMeetingRecording else { return }
        prewarmEngine()   // get the model loading while the meeting records
        requestMicrophone { [weak self] granted in
            guard let self else { return }
            guard granted else { self.presentMicrophoneDenied(); return }
            // Re-check after the async permission prompt.
            guard !self.isMeetingRecording, !self.isDictating else { return }
            // Label only with an app that's actually outputting audio (not the frontmost
            // window); tracking below keeps refining the set as the meeting goes on.
            let app = AudioProcessProbe.audioProducingApps().first?.localizedName
            let rec = self.store.beginRecording(source: .meeting, sourceApp: app)
            do {
                try self.meeting.start(micURL: rec.micURL, systemURL: rec.systemURL)
                self.currentMeeting = rec
                // Record each track's start instant so transcription can align them on a
                // common timeline (persisted, so a crash-retry stays aligned too).
                self.store.update(rec.id) {
                    $0.micStartedAt = self.meeting.micStartedAt
                    $0.systemStartedAt = self.meeting.systemStartedAt
                }
                self.startSourceAppTracking(rec.id)
                Sounds.recordingStarted()
            } catch {
                self.store.delete(rec.id)
                self.currentMeeting = nil
                self.presentError("Couldn't start meeting recording",
                                  "\(error)\n\nMeeting capture needs system-audio access. "
                                  + "Approve the prompt, or enable it under System Settings → "
                                  + "Privacy & Security, then try again.")
            }
            self.onStateChange?()
        }
    }

    /// Sample which apps are producing audio every few seconds while recording, and
    /// keep the meeting's source label as the union of them. The other side may be
    /// silent at the very start, so a single check at record time isn't enough.
    private func startSourceAppTracking(_ id: UUID) {
        meetingAudioApps = []
        sampleAudioApps(id)
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleAudioApps(id) }
        }
        RunLoop.main.add(timer, forMode: .common)
        sourceAppTimer = timer
    }

    private func sampleAudioApps(_ id: UUID) {
        guard currentMeeting?.id == id else { return }
        let names = AudioProcessProbe.audioProducingApps().compactMap(\.localizedName)
        let updated = meetingAudioApps.union(names)
        guard updated != meetingAudioApps else { return }
        meetingAudioApps = updated
        store.updateSourceApp(id, app: meetingAudioApps.sorted().joined(separator: ", "))
        onStateChange?()
    }

    func stopMeeting() {
        sourceAppTimer?.invalidate()
        sourceAppTimer = nil
        meeting.stop()
        Sounds.recordingStopped()
        if let rec = currentMeeting {
            store.finishRecording(rec.id)
            transcribeMeeting(rec.id)
        }
        currentMeeting = nil
        onStateChange?()
    }

    /// Transcribe a meeting's two tracks into one chronological conversation: your mic
    /// is "You"; the system side is the producing app's name (or "Speaker 1 / 2 / …"
    /// when diarization finds multiple voices). Turns from both tracks are interleaved
    /// by time, so it reads as a back-and-forth instead of two walls of text.
    func transcribeMeeting(_ id: UUID, userInitiated: Bool = true) {
        guard let rec = store.recording(id), rec.transcription != .running else { return }
        store.setTranscriptionStatus(id, .running)
        onStateChange?()

        let micURL = rec.micURL
        let systemURL = rec.systemURL
        let them = rec.sourceApp ?? "Them"
        let folder = rec.folder
        let (youOffset, themOffset) = Self.trackOffsets(micStart: rec.micStartedAt,
                                                        systemStart: rec.systemStartedAt)
        Task { [self] in
            async let mineTranscript = transcribeFile(micURL)
            async let theirsTranscript = transcribeFile(systemURL)
            async let theirsSpeakers = diarizeIfEnabled(systemURL)

            let youTurns = Self.turns(from: await mineTranscript, fallbackSpeaker: "You") { _ in "You" }
            let themTurns = Self.systemTurns(from: await theirsTranscript,
                                             speakers: await theirsSpeakers, appName: them)
            // Shift each track onto a shared t=0 (the two captures start a few ms apart)
            // before interleaving, so turn ordering at boundaries is correct.
            let combined = Self.interleave(Self.shift(youTurns, by: youOffset)
                                           + Self.shift(themTurns, by: themOffset))

            // No speech on either track → don't keep an empty recording folder.
            guard !combined.isEmpty else {
                await MainActor.run {
                    self.store.delete(id)
                    self.onStateChange?()
                    Log.info("Discarded silent meeting \(folder) (no speech)")
                }
                return
            }

            await MainActor.run {
                self.store.setTranscript(id, text: combined)
                self.onStateChange?()
                self.onTranscriptionFinished(id, userInitiated: userInitiated)
                Log.info("Transcribed meeting \(folder): \(combined.count) chars")
            }
            if let summary = await Summarizer.summarize(combined) {
                await MainActor.run {
                    self.store.setSummary(id, text: summary)
                    self.onStateChange?()
                }
            }
        }
    }

    private func diarizeIfEnabled(_ url: URL) async -> [SpeakerSegment] {
        guard Settings.labelSpeakers else { return [] }
        return await diarizer.diarize(fileAt: url)
    }

    private func transcribeFile(_ url: URL) async -> Transcript {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Transcript(text: "", segments: [])
        }
        do {
            return try await engine.transcribe(fileAt: url, onPartial: nil)
        } catch {
            Log.error("Track transcription failed: \(error.localizedDescription)")
            return Transcript(text: "", segments: [])
        }
    }

    /// One labelled turn in a meeting transcript.
    private struct Turn {
        let start: TimeInterval
        let speaker: String
        var text: String
    }

    /// How far to shift each track's segment times so both sit on a common t=0 (the
    /// earlier track is the origin). The two engines start a few ms apart, so without
    /// this the later-starting track's turns read as earlier than they actually were.
    /// Returns zero offsets when the timestamps aren't available (old/recovered records).
    private static func trackOffsets(micStart: Date?, systemStart: Date?) -> (you: TimeInterval, them: TimeInterval) {
        guard let micStart, let systemStart else { return (0, 0) }
        let base = min(micStart, systemStart)
        return (micStart.timeIntervalSince(base), systemStart.timeIntervalSince(base))
    }

    /// Offset every turn's start by `offset` seconds (no-op when zero).
    private static func shift(_ turns: [Turn], by offset: TimeInterval) -> [Turn] {
        guard offset != 0 else { return turns }
        return turns.map { Turn(start: $0.start + offset, speaker: $0.speaker, text: $0.text) }
    }

    /// Split a transcript into cleaned, speaker-labelled turns (one per segment).
    /// Falls back to a single turn from the whole text when there are no segments.
    private static func turns(from transcript: Transcript,
                              fallbackSpeaker: String,
                              speaker: (Transcript.Segment) -> String) -> [Turn] {
        let segmentTurns = transcript.segments.compactMap { seg -> Turn? in
            let text = TextCleaner.process(seg.text).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Turn(start: seg.start, speaker: speaker(seg), text: text)
        }
        if !segmentTurns.isEmpty { return segmentTurns }
        let whole = TextCleaner.process(transcript.text).trimmingCharacters(in: .whitespacesAndNewlines)
        return whole.isEmpty ? [] : [Turn(start: 0, speaker: fallbackSpeaker, text: whole)]
    }

    /// The other side of a meeting: label each segment with the diarized speaker when
    /// there are multiple voices, otherwise with the producing app's name.
    private static func systemTurns(from transcript: Transcript,
                                    speakers: [SpeakerSegment],
                                    appName: String) -> [Turn] {
        let distinct = Set(speakers.map(\.speakerId))
        guard distinct.count > 1 else {
            return turns(from: transcript, fallbackSpeaker: appName) { _ in appName }
        }
        var labels: [String: String] = [:]
        func label(for sid: String) -> String {
            if let existing = labels[sid] { return existing }
            let name = "Speaker \(labels.count + 1)"
            labels[sid] = name
            return name
        }
        func overlap(_ s: SpeakerSegment, _ seg: Transcript.Segment) -> Double {
            max(0, min(s.end, seg.end) - max(s.start, seg.start))
        }
        return turns(from: transcript, fallbackSpeaker: appName) { seg in
            let mid = (seg.start + seg.end) / 2
            let match = speakers.first(where: { $0.start <= mid && mid <= $0.end })
                ?? speakers.max(by: { overlap($0, seg) < overlap($1, seg) })
            return match.map { label(for: $0.speakerId) } ?? "Speaker 1"
        }
    }

    /// Merge turns from both tracks into one chronological transcript, coalescing
    /// consecutive turns from the same speaker into a single paragraph.
    private static func interleave(_ turns: [Turn]) -> String {
        let sorted = turns.sorted { $0.start < $1.start }
        var merged: [Turn] = []
        for turn in sorted {
            if !merged.isEmpty, merged[merged.count - 1].speaker == turn.speaker {
                merged[merged.count - 1].text += " " + turn.text
            } else {
                merged.append(turn)
            }
        }
        return merged.map { "**\($0.speaker):** \($0.text)" }.joined(separator: "\n\n")
    }

    // MARK: Transcription

    /// Transcribe a finished recording. Runs off the main actor; autosaves progress
    /// to transcript.md and, on completion, the store writes the final Markdown +
    /// manifest. Safe to call again to retry a failed one.
    func transcribe(_ id: UUID, userInitiated: Bool = true) {
        guard let rec = store.recording(id), rec.transcription != .running else { return }
        store.setTranscriptionStatus(id, .running)
        onStateChange?()

        let url = rec.url
        let transcriptURL = rec.transcriptURL
        let folder = rec.folder
        Task { [engine, self] in
            // Called as each VAD segment finalizes: write the .txt immediately
            // (durable autosave) and reflect progress in the UI.
            let onPartial: @Sendable (String) -> Void = { partial in
                try? partial.write(to: transcriptURL, atomically: true, encoding: .utf8)
                Task { @MainActor in
                    self.store.setPartialTranscript(id, text: partial)
                    self.onStateChange?()
                }
            }
            do {
                let transcript = try await engine.transcribe(fileAt: url, onPartial: onPartial)
                let cleaned = TextCleaner.process(transcript.text)
                // Optional on-device AI polish (stutters / false starts), best-effort.
                let text = await Polisher.polishIfEnabled(cleaned)
                await MainActor.run {
                    // setTranscript writes the final transcript.md + refreshes INDEX.md.
                    self.store.setTranscript(id, text: text)
                    self.onStateChange?()
                    self.onTranscriptionFinished(id, userInitiated: userInitiated)
                    Log.info("Transcribed \(folder): \(text.count) chars")
                }
                // Best-effort on-device summary (Apple Intelligence); updates the
                // transcript.md + INDEX.md again when ready.
                if let summary = await Summarizer.summarize(text) {
                    await MainActor.run {
                        self.store.setSummary(id, text: summary)
                        self.onStateChange?()
                    }
                }
            } catch {
                await MainActor.run {
                    self.store.setTranscriptionStatus(id, .failed)
                    self.onStateChange?()
                    Log.error("Transcription failed for \(folder): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Save a dictation as a text-only history entry, then summarize it on-device.
    private func saveDictation(text: String, duration: TimeInterval, targetApp: String?) {
        let id = store.addDictation(text: text, duration: duration, targetApp: targetApp)
        onStateChange?()
        Task { [self] in
            if let summary = await Summarizer.summarize(text) {
                await MainActor.run {
                    self.store.setSummary(id, text: summary)
                    self.onStateChange?()
                }
            }
        }
    }

    /// Side effects when a (non-dictation) transcription finishes: an optional success
    /// sound and an optional auto-copy of the transcript to the clipboard.
    private func onTranscriptionFinished(_ id: UUID, userInitiated: Bool) {
        // Skip for launch-retry / crash-recovery: those aren't a user action, so they
        // shouldn't play a sound or overwrite whatever is on the clipboard.
        guard userInitiated else { return }
        Sounds.transcriptionDone()
        if Settings.autoCopyToClipboard { copyTranscript(id) }
    }

    // MARK: Recently Deleted

    var deletedRecordings: [Recording] { store.deletedRecordings }

    /// Soft-delete: move to Recently Deleted (restorable).
    func softDelete(_ id: UUID) {
        store.softDelete(id)
        onStateChange?()
    }

    func restore(_ id: UUID) {
        store.restore(id)
        onStateChange?()
    }

    func deletePermanently(_ id: UUID) {
        store.delete(id)
        onStateChange?()
    }

    func emptyTrash() {
        store.emptyTrash()
        onStateChange?()
    }

    /// Put a recording's transcript on the clipboard (for quick reuse).
    func copyTranscript(_ id: UUID) {
        guard let text = store.recording(id)?.transcript, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func revealInFinder(_ id: UUID) {
        guard let rec = store.recording(id) else { return }
        let target = rec.transcription == .done ? rec.transcriptURL : rec.url
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: Permissions

    private func requestMicrophone(_ completion: @escaping @MainActor (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in completion(granted) }
            }
        default:
            completion(false)
        }
    }

    private func presentMicrophoneDenied() {
        let alert = NSAlert()
        alert.messageText = "Microphone access needed"
        alert.informativeText = "Enable Murmur under System Settings → Privacy & "
            + "Security → Microphone, then try again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func presentError(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
