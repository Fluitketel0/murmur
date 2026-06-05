@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio

/// Records the microphone to disk **continuously**, so a crash or force-quit loses
/// at most the last buffer instead of the whole recording.
///
/// Pipeline: `AVAudioEngine` mic tap → `AVAudioConverter` to 16 kHz mono Float32 →
/// appended to an `AVAudioFile` (CAF). That format is exactly what the transcription
/// engine consumes, so recording and transcription share one pipeline. CAF is used
/// because it stays readable while still being written, its header doesn't depend
/// on a final size field the way canonical WAV does.
final class CrashSafeRecorder {

    /// The format every recording is written in, and every engine consumes.
    static let transcriptionFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false)!

    enum RecorderError: Error { case engineFailed(String) }

    /// Recreated on each `start()` so the input node always binds to the *current*
    /// default input device (a long-lived engine keeps using whatever was default when
    /// it was created, which goes silent if the user later switches mics).
    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var outputFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private(set) var isRecording = false

    /// Live input loudness (0...1), emitted per buffer from the audio thread so the
    /// UI can show a meter. Set before `start()`.
    var onLevel: (@Sendable (Float) -> Void)?

    /// Enable macOS voice processing (acoustic echo cancellation + noise suppression)
    /// on the mic, so meetings don't re-record the other participants coming out of the
    /// speakers. Set before `start()`. Off by default - dictation doesn't need it.
    var enableVoiceProcessing = false

    /// Begin writing mic audio to `url`. Returns once capture is running.
    func start(writingTo url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRecording else { return }

        // Fresh engine so the input node binds to whatever the default input is *now*.
        engine = AVAudioEngine()
        let input = engine.inputNode
        // Must be set before querying the input format / starting the engine.
        // Best-effort: if the system refuses it we still record, just without AEC.
        if enableVoiceProcessing {
            do { try input.setVoiceProcessingEnabled(true) }
            catch { Log.error("Voice processing unavailable: \(error.localizedDescription)") }
        }
        // Pin the input node to the current default input device explicitly, so we
        // record the mic the user is actually using (not a stale one).
        Self.bindDefaultInputDevice(input)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw RecorderError.engineFailed("No microphone input available")
        }
        Log.info("Recording input: \(Self.defaultInputDeviceName() ?? "default"), "
                 + "\(Int(inputFormat.sampleRate)) Hz \(inputFormat.channelCount) ch")

        let target = Self.transcriptionFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw RecorderError.engineFailed("Cannot convert mic format to 16 kHz mono")
        }
        self.converter = converter

        // CAF container with the 16 kHz mono Float32 settings.
        self.outputFile = try AVAudioFile(forWriting: url,
                                          settings: target.settings,
                                          commonFormat: .pcmFormatFloat32,
                                          interleaved: false)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            outputFile = nil
            self.converter = nil
            throw RecorderError.engineFailed(error.localizedDescription)
        }
        isRecording = true
        Log.info("Recording started → \(url.lastPathComponent)")
    }

    /// Stop capture and flush the file to disk.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        outputFile = nil   // closing the AVAudioFile flushes/finalizes the CAF
        converter = nil
        isRecording = false
        Log.info("Recording stopped")
    }

    // MARK: Input device selection

    /// Point the engine's input node at the current default input device, so we always
    /// capture from the mic the user is actually using. Best-effort: on failure we fall
    /// back to whatever the node defaulted to.
    private static func bindDefaultInputDevice(_ node: AVAudioInputNode) {
        guard var deviceID = defaultInputDevice, let unit = node.audioUnit else { return }
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { Log.error("Could not set input device (status \(status))") }
    }

    private static var defaultInputDevice: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    /// The default input device's human-readable name (for diagnostics).
    private static func defaultInputDeviceName() -> String? {
        guard let device = defaultInputDevice else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        let value = name as String
        return value.isEmpty ? nil : value
    }

    // MARK: Audio thread

    private func append(_ inBuffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let converter, let outputFile else { return }

        let target = Self.transcriptionFormat
        let ratio = target.sampleRate / inBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target,
                                               frameCapacity: capacity) else { return }

        // The converter calls this block synchronously inside convert(), so the
        // mutation is not actually concurrent; tell Swift 6 we accept that.
        nonisolated(unsafe) var consumed = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inBuffer
        }

        if let convError {
            Log.error("Convert failed: \(convError.localizedDescription)")
            return
        }
        guard status != .error, outBuffer.frameLength > 0 else { return }

        do {
            try outputFile.write(from: outBuffer)
        } catch {
            Log.error("Write failed: \(error.localizedDescription)")
        }

        if let onLevel { onLevel(Self.loudness(outBuffer)) }
    }

    /// RMS loudness of a mono Float buffer, scaled to a usable 0...1 range for a
    /// visual meter (a little gain so normal speech fills most of the bar).
    static func loudness(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += channel[i] * channel[i] }
        let rms = (sum / Float(count)).squareRoot()
        return min(1, rms * 6)
    }
}
