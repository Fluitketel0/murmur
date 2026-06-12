import Foundation
import FluidAudio

/// Default speech engine: NVIDIA Parakeet TDT v3 on the Apple Neural Engine via
/// FluidAudio. One multilingual model covers German, English, and Dutch (plus 22
/// other European languages) with automatic language detection.
///
/// Long recordings are split into ASR-ready speech segments with Silero VAD
/// (silence-trimmed, capped at ~14 s) and transcribed one segment at a time. That
/// bounds memory regardless of length, avoids transcribing silence, and lets the
/// caller autosave the transcript as each segment finalizes.
///
/// An `actor` so the (non-Sendable) FluidAudio managers are accessed serially and
/// the type satisfies `TranscriptionEngine: Sendable`.
actor ParakeetEngine: TranscriptionEngine {
    private var asr: AsrManager?
    private var vad: VadManager?

    /// Speech-segmentation tuning. We raise the silence gap that ends a chunk from the
    /// 0.75s default to 1.5s, so a normal thinking pause doesn't split the utterance.
    /// Each split tends to pick up a sentence-final period from the model, so fewer
    /// splits means fewer stray periods on pauses. The 14s max-chunk cap is unchanged,
    /// so memory stays bounded regardless of how long you talk.
    private static let segmentation = VadSegmentationConfig(minSilenceDuration: 1.5)

    enum EngineError: Error { case notPrepared }

    /// Download (first run only) and load the ASR + VAD Core ML models. Idempotent.
    private func prepare() async throws {
        if asr == nil {
            Log.info("Loading Parakeet v3 models (first run downloads them)...")
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asr = manager
        }
        if vad == nil {
            Log.info("Loading Silero VAD model...")
            vad = try await VadManager(config: .default)
        }
        Log.info("Speech models ready")
    }

    /// Load the ASR + VAD models now (in the background), so the first dictation or
    /// meeting transcription doesn't pay the cold-load cost on the critical path. This
    /// matters most right after a reboot or a macOS update, when CoreML recompiles the
    /// models for the Neural Engine, which can take tens of seconds.
    @discardableResult
    func prewarm() async -> Bool {
        do { try await prepare(); return true }
        catch {
            Log.error("Speech model prewarm failed: \(error.localizedDescription)")
            return false
        }
    }

    func transcribe(fileAt url: URL,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> Transcript {
        try await prepare()
        guard let asr, let vad else { throw EngineError.notPrepared }

        // Recordings are 16 kHz mono (the recorder's format), which VAD and ASR
        // consume directly. For anything else (e.g. an imported MP3), fall back to
        // FluidAudio's whole-file path, which resamples internally - and check the
        // format first so we don't load a large file into memory just to fall back.
        let (sampleRate, channels) = try AudioSamples.format(url)
        guard sampleRate == 16_000, channels == 1 else {
            var state = try TdtDecoderState()
            let r = try await asr.transcribe(url, decoderState: &state, language: nil)
            onPartial?(r.text)
            return Transcript(text: r.text, segments: [])
        }

        let (samples, _, _) = try AudioSamples.read(url)
        guard !samples.isEmpty else { return Transcript(text: "", segments: []) }

        let segments = try await vad.segmentSpeech(samples, config: Self.segmentation)
        if segments.isEmpty {
            return Transcript(text: "", segments: [])
        }

        var pieces: [Transcript.Segment] = []
        var cumulative = ""
        for seg in segments {
            let start = max(0, seg.startSample(sampleRate: 16_000))
            let end = min(samples.count, seg.endSample(sampleRate: 16_000))
            guard end > start else { continue }

            var state = try TdtDecoderState()
            let chunk = Array(samples[start..<end])
            let result = try await asr.transcribe(chunk, decoderState: &state, language: nil)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            pieces.append(Transcript.Segment(start: seg.startTime, end: seg.endTime, text: text))
            cumulative += cumulative.isEmpty ? text : " " + text
            onPartial?(cumulative)   // progressive autosave hook
        }

        return Transcript(text: cumulative, segments: pieces)
    }
}
