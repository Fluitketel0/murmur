import SwiftUI

/// Settings, mirrored from `Settings`/`AppCoordinator` via `AppModel`. Grouped into
/// a few sections; deliberately compact. Model switching is shown but not yet
/// changeable (one engine today).
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.fontScale) private var scale

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Picker("Show Murmur in", selection: $model.appVisibility) {
                    ForEach(AppVisibility.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Copy transcripts to the clipboard automatically", isOn: $model.autoCopyToClipboard)
                Toggle("Play sounds while recording and transcribing", isOn: $model.soundEffects)
            } header: {
                Text("General")
            } footer: {
                Text("Auto-copy puts each finished transcript on your clipboard. Dictation is excluded, since it types straight into the app you're using.")
            }

            Section {
                Toggle("Type with your voice (dictation)", isOn: $model.dictationEnabled)
                Picker("How the dictation key works", selection: $model.dictationMode) {
                    ForEach(DictationMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Mute audio while dictating", isOn: $model.pauseMusicWhileDictating)
            } header: {
                Text("Dictation")
            } footer: {
                Text(model.dictationEnabled
                     ? "Hold \(model.dictationTriggerDescription) anywhere, speak, and what you say is typed where your cursor is. Music is muted while you talk and comes back when you finish. Calls in a browser (like Google Meet) or an app like Zoom are left alone."
                     : "Turn this on to talk into any app with a keyboard shortcut and have it typed for you.")
            }

            Section {
                hotkeyRow("Key to dictate", $model.dictationShortcut) { model.resetDictationShortcut() }
                hotkeyRow("Key to record a meeting", $model.meetingShortcut) { model.resetMeetingShortcut() }
            } header: {
                Text("Keyboard shortcuts")
            } footer: {
                Text("Click a field, then press the keys you want (e.g. ⌥⌘E), or hold a single modifier like Fn. Press Esc to cancel, or ↺ to restore the default.")
            }

            Section {
                Toggle("Remove filler words (uh, um, äh)", isOn: $model.removeFillers)
                Toggle("Tidy up stutters and false starts with AI", isOn: $model.polishTranscripts)
                Toggle("Label each speaker in meetings", isOn: $model.labelSpeakers)
            } header: {
                Text("How transcripts are cleaned up")
            } footer: {
                Text(model.polishTranscripts
                     ? "When you change your mind mid-sentence (“the blue one, no, the red one”), an on-device AI keeps only what you meant. Adds about 1 to 2 seconds before the text appears."
                     : "Filler removal strips “uh/um”. Turn on AI tidying to also fix stutters and false starts.")
            }

            Section {
                LabeledContent("Speech-to-text model", value: "Parakeet TDT v3")
                LabeledContent("Space it uses", value: StorageInfo.format(model.storage.model))
            } header: {
                Text("Transcription model")
            } footer: {
                Text("Runs entirely on your Mac. Nothing is sent to the cloud. Understands German, English, Dutch and 22 more languages. Choosing a different model is coming later.")
            }

            Section {
                LabeledContent("Saved recordings") {
                    Text("\(model.recordings.count) · \(StorageInfo.format(model.storage.recordings))")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Where they're kept") {
                    Button("Show in Finder") { model.openRecordingsFolder() }
                }
                Picker("Auto-delete old recordings", selection: $model.autoDeleteAfter) {
                    ForEach(AutoDeletePeriod.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Audio \(StorageInfo.format(model.storage.audio)) · Transcripts \(StorageInfo.format(model.storage.text)). Dictations save only the text; meetings keep the audio too. Auto-deleted recordings move to Recently Deleted (kept 30 days) before being removed.")
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // Scale the form's text and controls with the window zoom (⌘=/-). macOS won't
        // font-scale form controls, so bump their control size in steps to keep pace.
        .font(.system(size: 13 * scale))
        .controlSize(scale >= 1.45 ? .extraLarge : (scale >= 1.15 ? .large : .regular))
        .task { model.refreshStorage() }
    }

    @ViewBuilder
    private func hotkeyRow(_ title: String, _ binding: Binding<Shortcut>, reset: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                ShortcutField(shortcut: binding)
                    .frame(width: 150, height: 22)
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset to default")
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }
}
