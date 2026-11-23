import UIKit

/// A keyboard attached to the device. iOS reports each key going down and coming up by its HID usage,
/// which is what the Mac's USB keyboard sends, so every key and modifier goes straight across.
enum HardwareKeys {
    private static var held: Set<UInt8> = []
    private static var lastKey: CFTimeInterval = 0
    private static var lastCommand: (usage: UInt8, at: CFTimeInterval)?

    /// Shortcuts iPadOS would otherwise keep for itself (its windows' ⌘W and ⌘M, its menu bar's commands), as key
    /// commands that come before the system's. ⌘Tab, ⌘Space, ⌘H and the screenshot keys stay iPadOS's: no app gets
    /// those. The letters are the ones in the same place on U.S. and German keyboards (all but Y and Z), so the key
    /// the Mac gets is the one pressed.
    static func keyCommands(action: Selector) -> [UIKeyCommand] {
        let keys = "abcdefghijklmnopqrstuvwx,.".map(String.init)
        let chords: [UIKeyModifierFlags] = [.command, [.command, .shift], [.command, .alternate], [.command, .control]]
        return chords.flatMap { flags in
            keys.map { key in
                let command = UIKeyCommand(input: key, modifierFlags: flags, action: action)
                command.wantsPriorityOverSystemBehavior = true
                command.allowsAutomaticLocalization = false
                command.allowsAutomaticMirroring = false
                return command
            }
        }
    }

    /// One of those: its key, down and up (the modifiers went over as presses). If iPadOS delivered the press too,
    /// it is sent once.
    static func perform(_ command: UIKeyCommand) {
        guard let input = command.input, let usage = usage(for: input), !held.contains(usage) else { return }
        lastCommand = (usage, CACurrentMediaTime())
        henge_vm_key_hid(usage, 1)
        henge_vm_key_hid(usage, 0)
        lastKey = CACurrentMediaTime()
        StickyKeys.shared.used()
    }

    /// The HID usage of a key command's letter, comma or period.
    private static func usage(for input: String) -> UInt8? {
        guard input.count == 1, let c = input.lowercased().unicodeScalars.first else { return nil }
        switch c {
        case "a"..."z": return UInt8(0x04 + c.value - ("a" as UnicodeScalar).value)
        case ",": return 0x36
        case ".": return 0x37
        default: return nil
        }
    }

    /// With the on-screen keyboard's view holding the keyboard, iOS may also offer a hardware key as
    /// text, and again as it repeats. The Mac has the key already, and repeats it itself.
    static var keyJustPressed: Bool {
        held.contains { $0 < 0xe0 } || CACurrentMediaTime() - lastKey < 0.1
    }

    /// Sends the presses that are keys, and returns the rest.
    static func send(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        var rest = Set<UIPress>()
        // A chord can arrive in one unordered Set. Press modifiers first and
        // release them last so the guest sees the intended shortcut.
        let ordered = presses.sorted { a, b in
            let aCode = a.key?.keyCode.rawValue ?? 0
            let bCode = b.key?.keyCode.rawValue ?? 0
            let aModifier = (0xe0...0xe7).contains(aCode)
            let bModifier = (0xe0...0xe7).contains(bCode)
            if aModifier != bModifier { return down ? aModifier : !aModifier }
            return aCode < bCode
        }
        for press in ordered {
            guard let raw = press.key?.keyCode.rawValue, raw >= 0x04, raw <= 0xe7 else {
                rest.insert(press)
                continue
            }
            let usage = UInt8(raw)
            // The key command for this key sent it a moment ago.
            if down, let last = lastCommand, last.usage == usage, CACurrentMediaTime() - last.at < 0.05 { continue }
            henge_vm_key_hid(usage, down ? 1 : 0)
            if usage < 0xe0 { lastKey = CACurrentMediaTime() }
            if down {
                held.insert(usage)
            } else {
                held.remove(usage)
                if usage < 0xe0 { StickyKeys.shared.used() } // one key after a tap on ⇧, ⌃, ⌥ or ⌘
            }
        }
        return rest
    }

    /// iPadOS can keep a key's release when it takes over, as it does for ⌘-Tab: the Mac must not
    /// go on thinking the key is down.
    static func releaseAll() {
        for usage in held { henge_vm_key_hid(usage, 0) }
        held.removeAll()
    }
}
