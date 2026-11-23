import Foundation

/// Starting the last Mac by itself, with a guard against a Mac that keeps failing to come up.
enum AutoStart {
    static let key = "solstice.autoStartMac"
    private static let failuresKey = "solstice.autoStartFailures"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    /// Counts an attempt; false after two in a row that never reached a running Mac.
    static func attempt() -> Bool {
        let failures = UserDefaults.standard.integer(forKey: failuresKey)
        guard failures < 2 else { return false }
        UserDefaults.standard.set(failures + 1, forKey: failuresKey)
        return true
    }
    /// A Mac got going (it ran for a while): start counting afresh.
    static func succeeded() { UserDefaults.standard.set(0, forKey: failuresKey) }
}
