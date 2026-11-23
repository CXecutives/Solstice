import Foundation

/// One key on the Mac's keyboard, by its Linux input code (what the engine's keyboard takes), with the
/// modifiers it needs held.
struct KeyStroke: Equatable {
    let code: UInt16
    var shift = false
    var option = false
}

/// Which keys type a character on the Mac, for the keyboard layout chosen in macOS. The keys are where
/// they are on a U.S. keyboard (the Linux codes name those places); the layout says what each one types.
enum KeyLayout: String, CaseIterable, Identifiable {
    case us
    case german


    var id: String { rawValue }

    var title: String {
        switch self {
        case .us: return "U.S."
        case .german: return "German"
        }
    }

    /// An ISO keyboard has the key beside the left Shift; macOS then reads the key left of 1 as on a European Mac.
    var isISO: Bool { self != .us }

    /// The layout for a keyboard language such as "de-DE": German for German outside Switzerland
    /// (Swiss German is a layout of its own), U.S. otherwise.
    static func forLanguage(_ tag: String?) -> KeyLayout {
        let parts = (tag ?? "").replacingOccurrences(of: "_", with: "-").split(separator: "-").map { $0.lowercased() }
        guard parts.first == "de" else { return .us }
        return parts.dropFirst().contains("ch") ? .us : .german
    }

    /// The keys that type c, in order: one for most characters, a dead key and then space for a few.
    /// nil: no key on this layout types it.
    func strokes(for c: Character) -> [KeyStroke]? {
        let table = self == .us ? Self.usTable : Self.germanTable
        if let strokes = table[c] { return strokes }
        // A capital letter: its letter with Shift (not ẞ: Shift-ß is ?).
        let lower = String(c).lowercased()
        guard lower != String(c), lower.uppercased() == String(c), lower.count == 1, c.isLetter,
              let strokes = table[Character(lower)], strokes.count == 1, !strokes[0].shift, !strokes[0].option
        else { return nil }
        return [KeyStroke(code: strokes[0].code, shift: true)]
    }

    // MARK: Tables

    private static let space = KeyStroke(code: 57)

    private static func plain(_ pairs: [(Character, UInt16)]) -> [(Character, [KeyStroke])] {
        pairs.map { ($0.0, [KeyStroke(code: $0.1)]) }
    }
    private static func shifted(_ pairs: [(Character, UInt16)]) -> [(Character, [KeyStroke])] {
        pairs.map { ($0.0, [KeyStroke(code: $0.1, shift: true)]) }
    }
    private static func option(_ pairs: [(Character, UInt16)]) -> [(Character, [KeyStroke])] {
        pairs.map { ($0.0, [KeyStroke(code: $0.1, option: true)]) }
    }
    private static func table(_ groups: [[(Character, [KeyStroke])]]) -> [Character: [KeyStroke]] {
        var t: [Character: [KeyStroke]] = [:]
        for group in groups {
            for (c, strokes) in group {
                precondition(t[c] == nil, "\(c) twice in a keyboard table")
                t[c] = strokes
            }
        }
        return t
    }

    /// Return, tab, space and the digits are in the same places on both.
    private static let common: [(Character, UInt16)] = [
        ("1", 2), ("2", 3), ("3", 4), ("4", 5), ("5", 6), ("6", 7), ("7", 8), ("8", 9), ("9", 10), ("0", 11),
        ("\t", 15), ("\n", 28), (" ", 57),
    ]

    private static let usTable: [Character: [KeyStroke]] = table([
        plain(common),
        plain([("q", 16), ("w", 17), ("e", 18), ("r", 19), ("t", 20), ("y", 21), ("u", 22), ("i", 23), ("o", 24), ("p", 25),
               ("a", 30), ("s", 31), ("d", 32), ("f", 33), ("g", 34), ("h", 35), ("j", 36), ("k", 37), ("l", 38),
               ("z", 44), ("x", 45), ("c", 46), ("v", 47), ("b", 48), ("n", 49), ("m", 50),
               ("-", 12), ("=", 13), ("[", 26), ("]", 27), (";", 39), ("'", 40), ("`", 41), ("\\", 43),
               (",", 51), (".", 52), ("/", 53)]),
        shifted([("!", 2), ("@", 3), ("#", 4), ("$", 5), ("%", 6), ("^", 7), ("&", 8), ("*", 9), ("(", 10), (")", 11),
                 ("_", 12), ("+", 13), ("{", 26), ("}", 27), (":", 39), ("\"", 40), ("~", 41), ("|", 43),
                 ("<", 51), (">", 52), ("?", 53)]),
    ])

    /// Apple's German layout on an ISO keyboard (QWERTZ). The key left of 1 is ^ (a dead key), the one beside the
    /// left Shift (Linux KEY_102ND, 86) is <, and the brackets, @, | and \ are with Option. ^, ` and ~ are dead
    /// keys: they type themselves once followed by a space.
    private static let germanTable: [Character: [KeyStroke]] = table([
        plain(common),
        plain([("q", 16), ("w", 17), ("e", 18), ("r", 19), ("t", 20), ("z", 21), ("u", 22), ("i", 23), ("o", 24), ("p", 25),
               ("ü", 26), ("+", 27),
               ("a", 30), ("s", 31), ("d", 32), ("f", 33), ("g", 34), ("h", 35), ("j", 36), ("k", 37), ("l", 38),
               ("ö", 39), ("ä", 40), ("#", 43),
               ("<", 86), ("y", 44), ("x", 45), ("c", 46), ("v", 47), ("b", 48), ("n", 49), ("m", 50),
               (",", 51), (".", 52), ("-", 53), ("ß", 12)]),
        shifted([("!", 2), ("\"", 3), ("§", 4), ("$", 5), ("%", 6), ("&", 7), ("/", 8), ("(", 9), (")", 10), ("=", 11),
                 ("?", 12), ("*", 27), ("'", 43), (">", 86), (";", 51), (":", 52), ("_", 53), ("°", 41)]),
        option([("@", 38), ("€", 18), ("[", 6), ("]", 7), ("|", 8), ("{", 9), ("}", 10)]),
        [("\\", [KeyStroke(code: 8, shift: true, option: true)]),
         ("^", [KeyStroke(code: 41), space]),
         ("`", [KeyStroke(code: 13, shift: true), space]),
         ("´", [KeyStroke(code: 13), space]),
         ("~", [KeyStroke(code: 49, option: true), space])],
    ])
}
