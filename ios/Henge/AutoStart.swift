import Foundation

/// Starting the last Mac by itself, with a guard against a Mac that keeps failing to come up.
enum AutoStart {
    static let key = "solstice.autoStartMac"
    private static let failuresKey = "solstice.autoStartFailures"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    /// How long a Mac has to be up with Solstice in front (wall time; paused for heat or storage counts, the background
    /// does not) before its start counts as one that got going.
    static let upFor: TimeInterval = 60
    /// Two starts in a row that never got going: auto-start holds off until one does.
    static let failureLimit = 2
    /// Counts an attempt; false after failureLimit in a row that never reached a running Mac.
    static func attempt() -> Bool {
        let failures = UserDefaults.standard.integer(forKey: failuresKey)
        guard failures < failureLimit else { return false }
        UserDefaults.standard.set(failures + 1, forKey: failuresKey)
        return true
    }
    /// A Mac got going (it was up a while in front): start counting afresh.
    static func succeeded() { UserDefaults.standard.set(0, forKey: failuresKey) }
    /// What the Home screen says when auto-start held off.
    static func heldOffNotice(_ name: String) -> String {
        "\(name) did not start by itself: the last two starts did not get going. Start it once by hand to turn this back on."
    }
}
