# Murmur, Status and Roadmap

The full change history lives in git. This file is the current state and what's next.

## Shipped

The four core capabilities and the polish around them are done and released:

- **Crash-safe recording** with journal + recovery on launch.
- **Push-to-talk dictation**: configurable hotkey, four interaction modes
  (hold / tap-toggle / hybrid / hold-with-latch), text injected at the cursor, clipboard
  preserved. Holding the trigger as part of a key combo (e.g. Fn+Delete) cancels instead
  of dictating. Return / Command-Delete to finish a hands-free dictation.
- **Meeting capture**: mic + system audio as two tracks, speaker diarization, interleaved
  chronological transcript, source-app labelling.
- **File import**: drag-and-drop or pick an audio/video file (linked, not copied).
- **Transcription**: Parakeet TDT v3 on the Neural Engine via FluidAudio, Silero VAD
  segmentation, filler-word removal, optional AI summary + stutter cleanup (Apple
  Foundation Models, macOS 26).
- **History window**: searchable, day-grouped, read-only detail; soft delete with a
  30-day Recently Deleted, plus auto-delete retention.
- **Quality of life**: mute background audio while dictating (leaves browser/call apps
  alone), auto-copy to clipboard, sound effects, menu-bar/Dock visibility modes, launch
  at login, window zoom, brand palette + icon.
- **Automatic updates** via Sparkle (background, silent), plus a Check for Updates item.

## Roadmap / ideas

- **Onboarding flow**: first-run walkthrough that requests each permission with rationale
  and lets the user choose where recordings are stored. For when others install it.
- **Model switcher** (Fast / Accurate) once a second engine is added.
- **URL import** (YouTube etc. via yt-dlp) and audio extraction from video containers.
- **Manual language override** for the rare case where one utterance mixes languages
  (auto-detect can misfire; per-language audio is accurate).
- **Terminal typing fallback**: CGEvent Unicode typing for apps where paste is unreliable.
- **Smarter titles/summaries**: optional LLM-generated titles/tags; backfill summaries
  for old recordings.

## Model-swap candidates (behind `TranscriptionEngine`)

- Parakeet TDT v3 / FluidAudio (current default; de/en/nl + 22 more, ANE, low RAM).
- whisper.cpp large-v3-turbo (Metal/Core ML), for the ~75 non-European languages.
- Apple SpeechAnalyzer (macOS 26), fastest and zero bundle size, if quality proves out.
