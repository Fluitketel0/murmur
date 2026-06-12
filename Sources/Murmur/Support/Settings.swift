import Foundation

/// Where the app shows up: in the menu bar, in the Dock, or both. Default menu-bar
/// only (the app is driven mostly by its global hotkey).
enum AppVisibility: String, CaseIterable, Sendable {
    case menuBarOnly
    case dockOnly
    case dockAndMenuBar

    var displayName: String {
        switch self {
        case .menuBarOnly: return "Menu bar only"
        case .dockOnly: return "Dock only"
        case .dockAndMenuBar: return "Dock & menu bar"
        }
    }

    /// Whether the menu-bar status item should be shown.
    var showsMenuBar: Bool { self != .dockOnly }
    /// Whether the app keeps a Dock icon even when no window is open.
    var keepsDockIcon: Bool { self != .menuBarOnly }
}

/// How long to keep recordings before they're auto-moved to Recently Deleted. The
/// chosen period is measured from when each recording was made.
enum AutoDeletePeriod: String, CaseIterable, Sendable {
    case never
    case oneMonth
    case threeMonths
    case sixMonths
    case oneYear

    var displayName: String {
        switch self {
        case .never: return "Never"
        case .oneMonth: return "After 1 month"
        case .threeMonths: return "After 3 months"
        case .sixMonths: return "After 6 months"
        case .oneYear: return "After 1 year"
        }
    }

    /// Seconds after which a recording is considered old, or nil for "never".
    var seconds: TimeInterval? {
        switch self {
        case .never: return nil
        case .oneMonth: return 30 * 86_400
        case .threeMonths: return 90 * 86_400
        case .sixMonths: return 180 * 86_400
        case .oneYear: return 365 * 86_400
        }
    }
}

/// Typed wrapper over UserDefaults for user-facing toggles. One place to define
/// defaults so the code and the settings UI agree.
enum Settings {
    /// Where the app appears (menu bar / Dock / both). Default menu-bar only.
    static var appVisibility: AppVisibility {
        get { AppVisibility(rawValue: UserDefaults.standard.string(forKey: "appVisibility") ?? "") ?? .menuBarOnly }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "appVisibility") }
    }

    /// Automatically copy a transcript to the clipboard when it finishes. Excludes
    /// dictation (which already types at the cursor). Default on.
    static var autoCopyToClipboard: Bool {
        get { UserDefaults.standard.object(forKey: "autoCopyToClipboard") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoCopyToClipboard") }
    }

    /// Play short sounds when recording starts and when a transcription finishes.
    /// Default off.
    static var soundEffects: Bool {
        get { UserDefaults.standard.object(forKey: "soundEffects") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "soundEffects") }
    }

    /// Auto-move recordings older than this into Recently Deleted. Default 1 year.
    static var autoDeleteAfter: AutoDeletePeriod {
        get { AutoDeletePeriod(rawValue: UserDefaults.standard.string(forKey: "autoDeleteAfter") ?? "") ?? .oneYear }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "autoDeleteAfter") }
    }

    /// Strip filler words (uh, um, äh, …) from transcripts. Default on.
    static var removeFillers: Bool {
        get { UserDefaults.standard.object(forKey: "removeFillers") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "removeFillers") }
    }

    /// Run an on-device AI pass that cleans stutters / false starts / self-corrections
    /// into a tidy message (Apple Foundation Models). Adds ~1-2 s before dictated text
    /// appears, so it's opt-in. Default off.
    static var polishTranscripts: Bool {
        get { UserDefaults.standard.object(forKey: "polishTranscripts") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "polishTranscripts") }
    }

    /// Mute the system output while a dictation is in progress, and restore the volume
    /// afterwards (app-agnostic; only kicks in if audio is actually playing). Default on.
    static var pauseMusicWhileDictating: Bool {
        get { UserDefaults.standard.object(forKey: "pauseMusicWhileDictating") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "pauseMusicWhileDictating") }
    }

    /// Label meeting speakers (Speaker 1 / 2 / …) via diarization. Default on.
    static var labelSpeakers: Bool {
        get { UserDefaults.standard.object(forKey: "labelSpeakers") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "labelSpeakers") }
    }

    /// The push-to-talk dictation trigger. Default: hold Fn. Migrates the old
    /// `dictationTrigger` string ("fn"/"rightOption") on first read.
    static var dictationShortcut: Shortcut {
        get { decodeShortcut("dictationShortcut") ?? migratedDictationDefault }
        set { encodeShortcut(newValue, "dictationShortcut") }
    }

    /// The meeting record toggle. Default: ⌥⌘E.
    static var meetingShortcut: Shortcut {
        get { decodeShortcut("meetingShortcut") ?? .optCmdE }
        set { encodeShortcut(newValue, "meetingShortcut") }
    }

    /// One-time default migrations, oldest first: Hyper+R (doesn't survive Hyperkey's
    /// event remapping) → ⌘E, then ⌘E ("Use Selection for Find" in many apps, which
    /// the tap would swallow) → ⌥⌘E. Each leaves any other deliberate choice untouched.
    static func migrateDefaultsIfNeeded() {
        let cmdEKey = "didMigrateMeetingToCmdE"
        if !UserDefaults.standard.bool(forKey: cmdEKey) {
            UserDefaults.standard.set(true, forKey: cmdEKey)
            if decodeShortcut("meetingShortcut") == .hyperR {
                meetingShortcut = .cmdE
            }
        }
        let optCmdEKey = "didMigrateMeetingToOptCmdE"
        if !UserDefaults.standard.bool(forKey: optCmdEKey) {
            UserDefaults.standard.set(true, forKey: optCmdEKey)
            if decodeShortcut("meetingShortcut") == nil || decodeShortcut("meetingShortcut") == .cmdE {
                meetingShortcut = .optCmdE
            }
        }
    }

    /// How the trigger gesture is interpreted. Default hold-to-talk (predictable;
    /// accidental taps won't start a recording).
    static var dictationMode: DictationMode {
        get { DictationMode(rawValue: UserDefaults.standard.string(forKey: "dictationMode") ?? "") ?? .holdToTalk }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "dictationMode") }
    }

    // MARK: Shortcut persistence

    private static var migratedDictationDefault: Shortcut {
        switch UserDefaults.standard.string(forKey: "dictationTrigger") {
        case "rightOption": return Shortcut(keyCode: nil, modifiers: .maskAlternate)
        default: return .fnHold
        }
    }

    private static func decodeShortcut(_ key: String) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    private static func encodeShortcut(_ shortcut: Shortcut, _ key: String) {
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
