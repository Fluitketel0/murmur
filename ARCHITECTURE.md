# Murmur, Architecture

A lean, native-Swift macOS app for private speech-to-text. Requires macOS 15+ on
Apple Silicon; the optional on-device AI summary and stutter cleanup use Apple
Foundation Models, which need macOS 26 (they are skipped on 15). Four capabilities,
one shared core:

1. **Crash-safe recording**, audio streams to disk continuously, so a crash never
   loses more than the last fraction of a second.
2. **Push-to-talk dictation**, a global hotkey records, transcribes, and types the
   text at the cursor in any app.
3. **Meeting capture**, your mic and the system/app audio as two separate clean tracks.
4. **File import**, drop in an audio file and transcribe it.

## Design principles

- **Lean.** No Electron/Tauri/React, no Rust. Pure Swift, AppKit, SwiftUI, AVFoundation.
- **Maintainable and swappable.** The speech model sits behind one protocol
  (`TranscriptionEngine`); switching from Parakeet to whisper.cpp or Apple's
  SpeechAnalyzer is a localized change, not a rewrite.
- **Crash-safe by construction.** Recordings stream to disk as they happen, tracked in
  a journal. On launch any in-progress recording or transcription is recovered.
- **Private by default.** All audio and transcription stay on-device. The only network
  access is the one-time model download and the update check.

## Module map

```
Sources/Murmur/
  App/            NSApplication bootstrap, menu-bar UI, app coordinator, main menu
  Recording/      Crash-safe recorder, journal + recovery, meeting capture
                  (mic + system audio), Markdown/YAML export
  Transcription/  TranscriptionEngine protocol, Parakeet/FluidAudio engine,
                  speaker diarizer, AI summary + stutter polish
  Dictation/      Global hotkey, configurable shortcut, text injection, push-to-talk
  UI/             SwiftUI window (history, import, recently deleted, settings),
                  recording HUD, brand palette
  Support/        Paths, settings, logging, audio ducking, sounds, storage, updater,
                  and small shared helpers
```

## Speech engine

- **Default:** NVIDIA Parakeet TDT v3 (0.6B) via [FluidAudio](https://github.com/FluidInference/FluidAudio),
  on the Apple Neural Engine. Covers German, English, Dutch, and 22 other European
  languages with automatic language detection, one model for all.
- **Audio contract:** the engine consumes 16 kHz mono Float32 PCM. The recorder always
  writes that format, so recording and transcription share one pipeline.
- **Segmentation:** long audio is split into speech chunks with Silero VAD (silence
  trimmed, capped at ~14s) and transcribed chunk by chunk, which bounds memory and
  lets the transcript autosave progressively.
- **Swapping models:** implement `TranscriptionEngine` and point the coordinator at the
  new type. Candidates are listed in PLAN.md.

## Crash-safe recording

- Capture the mic via `AVAudioEngine` (bound to the current default input device),
  downsample to 16 kHz mono Float32 with `AVAudioConverter`, and append each buffer to
  an `AVAudioFile` (CAF container).
- CAF stays readable mid-write (its header does not depend on a final size field the way
  canonical WAV does), so an interrupted recording is recoverable as-is.
- A small JSON **journal** (`journal.json`) records every recording. A clean stop marks
  it `finished`; on launch any entry still marked `recording` is a crash orphan that we
  finalize, and any unfinished transcription is retried.

## On-disk layout (human- and agent-readable)

Each recording is a self-contained folder, so you (or a script) can read everything
about it without joining across files:

```
~/Library/Application Support/Murmur/Recordings/
  index.yaml                     manifest (YAML list), newest first
  2026-06-01_171530/
      audio.caf                  16 kHz mono audio (meetings keep mic.caf + system.caf)
      transcript.md              YAML frontmatter + transcript body
```

- `transcript.md` frontmatter: `id, title, summary, created, duration_seconds, source,
  words, audio`. Meetings interleave speaker-labelled turns; dictations are saved
  text-only (no audio).
- Titles are derived offline from the first words; summaries are an optional one-liner
  from Apple's on-device model.
- `journal.json` is the app's fast internal state; `transcript.md` + `index.yaml` are
  derived exports, so there is a single source of truth.

## Permissions (TCC)

- **Microphone**, recording (`NSMicrophoneUsageDescription`).
- **Accessibility**, the global hotkey + typing text into other apps (dictation).
- **Screen Recording / system audio** (`NSAudioCaptureUsageDescription`), capturing the
  other side of a meeting.

Requested just-in-time, only when a feature first needs them. Grants are tied to the
code signature, so we sign with a *stable self-signed identity* (`scripts/make-cert.sh`)
and they survive rebuilds. The app is **not sandboxed** (a sandbox blocks sending paste
events to other apps).

## Building from source

There is no Xcode project; the app is built with SwiftPM and two scripts.

```sh
./scripts/make-cert.sh   # once: a stable self-signed identity so permission grants persist
./scripts/build.sh       # build the .app bundle (or: ./scripts/build.sh release)
open dist/Murmur.app
```

`make-cert.sh` is optional but recommended: without it the build signs ad-hoc, and
macOS re-prompts for every permission on each rebuild. `scripts/release.sh` cuts a
signed release (see Distribution below).

## Distribution and updates

- The app is signed with the local self-signed identity and is **not notarized** (no
  paid Apple Developer account), so the first launch needs a one-time "Open Anyway" in
  System Settings.
- Released as a zipped `.app` on GitHub Releases. **Sparkle** powers automatic background
  updates: it checks `appcast.xml` (served from the repo), verifies each download against
  the embedded EdDSA public key, and installs silently. See `scripts/release.sh`.
```
