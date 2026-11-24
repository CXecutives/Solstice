import Foundation

/// What should have ended by now in a Mac's lifecycle and has not: a stop that hangs (the engine's STOPPING has no
/// end of its own), a pause or save that never returns (it blocks InstantResume's queue and all behind it), or macOS
/// not shutting down after its power button was pressed. The session shows a way out instead of spinning.
enum LifecycleWatchdog {
    /// A stop releases the machine in a second or two; a pause or save of a few GB takes a few seconds.
    static let stopLimit: TimeInterval = 30
    static let queueLimit: TimeInterval = 45
    /// macOS closes its apps first, and may ask about unsaved documents.
    static let shutdownLimit: TimeInterval = 90

    enum Stuck: Equatable {
        /// The Mac has been stopping for too long.
        case stopping
        /// A pause, save or run-on has not returned.
        case busy(String)
        /// The power button was pressed and macOS is still up.
        case shutdownIgnored

        var title: String {
            switch self {
            case .stopping: return "The Mac is not stopping"
            case .busy: return "The Mac is not responding"
            case .shutdownIgnored: return "macOS has not shut down"
            }
        }

        var text: String {
            switch self {
            case .stopping, .busy:
                return "Solstice could not finish with this Mac. Quit Solstice and open it again; the Mac's disk is safe."
            case .shutdownIgnored:
                return "It may be asking about unsaved documents on its screen. Force Off turns it off at once; anything not saved is lost."
            }
        }

        var logLine: String {
            switch self {
            case .stopping: return "the Mac has been stopping for over \(Int(LifecycleWatchdog.stopLimit)) s"
            case .busy(let what): return "\(what) has not returned in \(Int(LifecycleWatchdog.queueLimit)) s"
            case .shutdownIgnored: return "macOS is still up \(Int(LifecycleWatchdog.shutdownLimit)) s after its power button"
            }
        }
    }

    /// stoppingFor: how long the Mac has been stopping (nil if it is not); queue: what runs on InstantResume's queue
    /// and for how long; shutdownFor: how long since Shut Down pressed the power button of a Mac still running.
    static func check(stoppingFor: TimeInterval?, queue: (what: String, seconds: TimeInterval)?,
                      shutdownFor: TimeInterval?) -> Stuck? {
        if let s = stoppingFor, s > stopLimit { return .stopping }
        if let q = queue, q.seconds > queueLimit { return .busy(q.what) }
        if let s = shutdownFor, s > shutdownLimit { return .shutdownIgnored }
        return nil
    }
}
