import AppKit
import CoreGraphics

/// A configurable global hotkey driven by a `Shortcut`. Reports press/release so it
/// can drive both push-to-talk (hold) and toggle (tap) behaviours:
///
/// - **Bare-modifier** shortcut (e.g. Fn): a `listenOnly` tap on `flagsChanged`. We
///   never consume it (the modifier may be used elsewhere); `onPress` fires when the
///   exact modifier set becomes held, `onRelease` when it's let go.
/// - **Chord** shortcut (modifiers + key): an active tap on key-down/up. The matching
///   key-down is **consumed** (so it doesn't also type) and fires `onPress`; the
///   key-up fires `onRelease`. Auto-repeat key-downs are consumed but don't re-fire.
///
/// Needs Accessibility permission, like the taps it replaces.
@MainActor
final class GlobalHotkey {
    private nonisolated let shortcut: Shortcut

    var onPress: (@MainActor () -> Void)?
    var onRelease: (@MainActor () -> Void)?
    /// Bare-modifier triggers only: fired when another key is pressed while the modifier
    /// is held, i.e. the modifier is being used in a key combo (e.g. Fn+Delete) rather
    /// than as a push-to-talk hold. The key is never consumed, so the combo still works.
    var onComboKey: (@MainActor () -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    var isRunning: Bool { eventTap != nil }

    init(shortcut: Shortcut) { self.shortcut = shortcut }

    func start() -> Bool {
        guard eventTap == nil else { return true }
        let isChord = shortcut.keyCode != nil

        let mask: CGEventMask = isChord
            ? (CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue))
            // Bare modifier: watch flagsChanged for the hold, and keyDown so we can tell
            // when the modifier is being used in a combo (e.g. Fn+Delete) and cancel.
            : (CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue))
        let options: CGEventTapOptions = isChord ? .defaultTap : .listenOnly

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let hk = Unmanaged<GlobalHotkey>.fromOpaque(refcon).takeUnretainedValue()
            return hk.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            // Append at the TAIL so we observe events *after* other taps have run -
            // crucially, after key remappers like Hyperkey rewrite CapsLock→⌘⌥⌃⇧.
            // A head-insert tap would see the raw keystroke before that rewrite, so a
            // Hyper-based shortcut would never match.
            place: .tailAppendEventTap,
            options: options,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("Failed to create hotkey tap (Accessibility permission?)")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        Log.info("Hotkey armed (\(shortcut.display))")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)   // fully tear down the tap, not just disable it
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isDown = false
    }

    /// Runs on the main run loop (where the tap was added), so we're on the main
    /// actor. Returns true to consume the event.
    private nonisolated func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated {
                // Reset held-state: if the key-up was dropped while the tap was disabled,
                // a stale `isDown` would ignore the next press / leave a hold stuck.
                isDown = false
                if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return false
        }

        if let kc = shortcut.keyCode {
            switch type {
            case .keyDown:
                guard event.getIntegerValueField(.keyboardEventKeycode) == kc,
                      modifiersMatch(event.flags) else { return false }
                // Auto-repeat: consume but don't re-fire while held.
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return true }
                MainActor.assumeIsolated { if !isDown { isDown = true; onPress?() } }
                return true
            case .keyUp:
                guard event.getIntegerValueField(.keyboardEventKeycode) == kc else { return false }
                // Only consume the key-up if we actually consumed the matching key-down;
                // otherwise we'd swallow an unrelated combo's key-up (same key, different
                // modifiers) and could leave that key stuck in another app.
                return MainActor.assumeIsolated {
                    guard isDown else { return false }
                    isDown = false
                    onRelease?()
                    return true
                }
            default:
                return false
            }
        } else {
            if type == .keyDown {
                // A key pressed while the bare modifier is held: it's being used as a
                // modifier (e.g. Fn+Delete), not a push-to-talk hold. Don't consume it
                // (the combo must still work); just notify so dictation can cancel.
                MainActor.assumeIsolated { if isDown { onComboKey?() } }
                return false
            }
            guard type == .flagsChanged else { return false }
            let down = bareModifierHeld(event.flags)
            MainActor.assumeIsolated {
                if down, !isDown { isDown = true; onPress?() }
                else if !down, isDown { isDown = false; onRelease?() }
            }
            return false   // never consume a bare modifier
        }
    }

    private nonisolated func modifiersMatch(_ flags: CGEventFlags) -> Bool {
        // Chords ignore Fn (F-keys/arrows set it spuriously) and require an exact
        // modifier match for the rest.
        let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        return flags.intersection(mask) == shortcut.flags.intersection(mask)
    }

    /// A bare-modifier trigger (e.g. hold Fn) counts as held when its required
    /// modifier(s) are *all* present, allowing extra modifiers on top. Using a subset
    /// test (not exact equality) means pressing another modifier mid-hold doesn't flip
    /// the trigger off and back on, and lets it start even if a modifier was already held.
    private nonisolated func bareModifierHeld(_ flags: CGEventFlags) -> Bool {
        let required = shortcut.flags.intersection(Shortcut.relevantMask)
        guard !required.isEmpty else { return false }
        return flags.intersection(required) == required
    }
}
