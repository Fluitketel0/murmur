import Foundation

/// The single seam for speech-to-text. Swapping models (Parakeet → whisper.cpp →
/// Apple SpeechAnalyzer) means implementing this protocol and pointing the app at
/// the new type, no other code changes.
///
/// All engines consume 16 kHz mono Float32 PCM (see
/// `CrashSafeRecorder.transcriptionFormat`), so the recorder's output feeds any
/// engine directly.
protocol TranscriptionEngine: Sendable {
    /// Transcribe a finished audio file on disk. Implementations load their model
    /// lazily on first use.
    ///
    /// - Parameter onPartial: called with the cumulative transcript each time a
    ///   chunk finalizes, so callers can autosave progress. Engines that can't
    ///   stream simply call it once at the end (or not at all).
    func transcribe(fileAt url: URL,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> Transcript

    /// Load the model ahead of first use so the first real transcription isn't stuck on
    /// a slow cold load. Best-effort and idempotent; default is a no-op for engines that
    /// don't need it.
    func prewarm() async
}

extension TranscriptionEngine {
    func prewarm() async {}
}

/// Result of a transcription. Segments carry per-utterance timing (for SRT export
/// and, later, meeting/diarization views); `text` is the convenience concatenation.
struct Transcript: Sendable {
    struct Segment: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    let text: String
    let segments: [Segment]
}
