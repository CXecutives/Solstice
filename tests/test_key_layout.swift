import Foundation

@main
struct KeyLayoutTests {
    static func one(_ layout: KeyLayout, _ c: Character) -> KeyStroke? {
        guard let s = layout.strokes(for: c), s.count == 1 else { return nil }
        return s[0]
    }

    static func main() {
        // Every printable ASCII character, Return and tab has keys on both layouts, and no two characters share them.
        let ascii = (32...126).map { Character(UnicodeScalar(UInt8($0))) } + ["\n", "\t"]
        for layout in KeyLayout.allCases {
            var seen: [String: Character] = [:]
            for c in ascii {
                guard let strokes = layout.strokes(for: c) else { preconditionFailure("\(layout): no keys for \(c)") }
                let name = strokes.map { "\($0.code)\($0.shift ? "s" : "")\($0.option ? "o" : "")" }.joined(separator: ",")
                precondition(seen[name] == nil, "\(layout): \(c) and \(seen[name]!) type the same keys")
                seen[name] = c
            }
        }

        // U.S.
        precondition(one(.us, "z") == KeyStroke(code: 44))
        precondition(one(.us, "Z") == KeyStroke(code: 44, shift: true))
        precondition(one(.us, "@") == KeyStroke(code: 3, shift: true))
        precondition(one(.us, "~") == KeyStroke(code: 41, shift: true))
        precondition(KeyLayout.us.strokes(for: "ä") == nil)
        precondition(KeyLayout.us.strokes(for: "é") == nil)
        precondition(!KeyLayout.us.isISO)

        // German (Apple's layout): QWERTZ, umlauts, and the Option characters.
        precondition(one(.german, "z") == KeyStroke(code: 21))
        precondition(one(.german, "y") == KeyStroke(code: 44))
        precondition(one(.german, "Y") == KeyStroke(code: 44, shift: true))
        precondition(one(.german, "ä") == KeyStroke(code: 40))
        precondition(one(.german, "Ä") == KeyStroke(code: 40, shift: true))
        precondition(one(.german, "Ö") == KeyStroke(code: 39, shift: true))
        precondition(one(.german, "ü") == KeyStroke(code: 26))
        precondition(one(.german, "ß") == KeyStroke(code: 12))
        precondition(KeyLayout.german.strokes(for: "ẞ") == nil) // Shift-ß is ?
        precondition(one(.german, "?") == KeyStroke(code: 12, shift: true))
        precondition(one(.german, "€") == KeyStroke(code: 18, option: true))
        precondition(one(.german, "@") == KeyStroke(code: 38, option: true))
        precondition(one(.german, "[") == KeyStroke(code: 6, option: true))
        precondition(one(.german, "]") == KeyStroke(code: 7, option: true))
        precondition(one(.german, "{") == KeyStroke(code: 9, option: true))
        precondition(one(.german, "}") == KeyStroke(code: 10, option: true))
        precondition(one(.german, "|") == KeyStroke(code: 8, option: true))
        precondition(one(.german, "\\") == KeyStroke(code: 8, shift: true, option: true))
        precondition(one(.german, "/") == KeyStroke(code: 8, shift: true))
        precondition(one(.german, "<") == KeyStroke(code: 86))
        precondition(one(.german, ">") == KeyStroke(code: 86, shift: true))
        precondition(one(.german, "-") == KeyStroke(code: 53))
        precondition(one(.german, "'") == KeyStroke(code: 43, shift: true))
        precondition(KeyLayout.german.strokes(for: "~") == [KeyStroke(code: 49, option: true), KeyStroke(code: 57)])
        precondition(KeyLayout.german.strokes(for: "^") == [KeyStroke(code: 41), KeyStroke(code: 57)])
        precondition(KeyLayout.german.strokes(for: "`") == [KeyStroke(code: 13, shift: true), KeyStroke(code: 57)])
        precondition(KeyLayout.german.strokes(for: "é") == nil)
        precondition(KeyLayout.german.isISO)

        // The set up command types on both.
        for layout in KeyLayout.allCases {
            precondition("curl -s http://10.0.2.4/.henge/install | sh".allSatisfy { layout.strokes(for: $0) != nil })
        }

        // The default follows the keyboard's language.
        precondition(KeyLayout.forLanguage("de-DE") == .german)
        precondition(KeyLayout.forLanguage("de_AT") == .german)
        precondition(KeyLayout.forLanguage("de") == .german)
        precondition(KeyLayout.forLanguage("de-CH") == .us)
        precondition(KeyLayout.forLanguage("en-US") == .us)
        precondition(KeyLayout.forLanguage(nil) == .us)
        print("key layout ok")
    }
}
