import AppKit
import CoreGraphics

/// A user-configurable global shortcut. Two shapes:
/// - **Chord**: modifiers + a key (`keyCode != nil`), e.g. ⌃⌥⌘⇧R. Fired on key-down;
///   for push-to-talk we also track key-up for the "release".
/// - **Bare modifier**: no key (`keyCode == nil`), e.g. Fn - held down for
///   push-to-talk. Only modifiers that don't type on their own make good hold
///   triggers (Fn is the safe default).
struct Shortcut: Codable, Equatable, Sendable {
    /// nil = a held bare-modifier trigger; otherwise a CG virtual keycode.
    var keyCode: Int64?
    /// Raw `CGEventFlags`, masked to the modifiers we track.
    var modifiers: UInt64

    static let relevantMask: CGEventFlags =
        [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]

    var flags: CGEventFlags {
        CGEventFlags(rawValue: modifiers).intersection(Self.relevantMask)
    }

    init(keyCode: Int64?, modifiers: CGEventFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevantMask).rawValue
    }

    /// Whether this is a usable shortcut (has a key, or at least one modifier).
    var isValid: Bool { keyCode != nil || !flags.isEmpty }

    /// Human-readable, e.g. "⌃⌥⌘⇧R", "Fn", "⌥Space".
    var display: String {
        var s = ""
        let f = flags
        if f.contains(.maskSecondaryFn) { s += "Fn " }
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        if let kc = keyCode { s += Self.keyName(kc) }
        let out = s.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? "Unset" : out
    }

    // MARK: Common defaults

    /// Hold Fn (Globe) - the default push-to-talk trigger.
    static let fnHold = Shortcut(keyCode: nil, modifiers: .maskSecondaryFn)
    /// ⌥⌘E - the default meeting toggle. A real modifier combo (unlike a Hyper chord,
    /// it survives key remappers like Hyperkey) that apps rarely claim - plain ⌘E is
    /// "Use Selection for Find" in many apps, so the tap would swallow it. E = 14.
    static let optCmdE = Shortcut(keyCode: 14, modifiers: [.maskCommand, .maskAlternate])
    /// ⌘E - the previous meeting default; kept for migration.
    static let cmdE = Shortcut(keyCode: 14, modifiers: .maskCommand)
    /// Hyper+R (⌃⌥⌘⇧R) - the previous meeting default; kept for migration. R = 15.
    static let hyperR = Shortcut(keyCode: 15,
                                 modifiers: [.maskCommand, .maskAlternate, .maskControl, .maskShift])

    /// A small keycode→label map for display. Falls back to "Key <n>".
    static func keyName(_ code: Int64) -> String {
        if let n = names[code] { return n }
        return "Key \(code)"
    }

    private static let names: [Int64: String] = [
        0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",
        14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",
        26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",37:"L",38:"J",
        39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",50:"`",
        36:"Return",48:"Tab",49:"Space",51:"Delete",53:"Esc",
        96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",109:"F10",111:"F12",
        118:"F4",120:"F2",122:"F1",
        123:"←",124:"→",125:"↓",126:"↑",
    ]
}
