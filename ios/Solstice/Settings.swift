import Foundation

/// Every UserDefaults key the app uses. The strings are what is stored and stay as they are (a renamed key would lose
/// what people set); the "solstice." ones date from before Solstice.
enum SettingKey: String, CaseIterable {
    // JIT
    case jitAtLaunch = "solstice.jit.autoEnable"
    case jitPairingSource = "solstice.jitPairingSource"
    // Pointer & Trackpad
    case touchMode = "solstice.touch.mode"
    case touchHold = "solstice.touch.hold"
    case touchTapDrag = "solstice.touch.tapDrag"
    case scrollSpeed = "solstice.mouse.scrollSpeed"
    case mouseSpeed = "solstice.mouse.speed"
    case reverseScrolling = "solstice.mouse.reverse"
    case swapMouseButtons = "solstice.mouse.swapRightAndMiddle"
    // Mac's Keyboard
    case keyLayout = "solstice.keyboard.layout"
    case syncClipboard = "solstice.sharing.syncClipboard"
    // When You Leave
    case keepAwake = "solstice.keepAlive"
    case instantResume = "solstice.instantResume"
    case autoStartMac = "solstice.autoStartMac"
    case autoStartFailures = "solstice.autoStartFailures"
    // Appearance
    case appearance = "appearance"
    // Advanced
    case refreshRate = "solstice.perf.hz"
    case codeCacheMB = "solstice.perf.codeCacheMB"
    case fastFlush = "solstice.perf.fastFlush"
    // Safe mode (SafeMode)
    case macLive = "solstice.macLive"             // a Mac is running with Solstice in the foreground
    case uncleanEnds = "solstice.uncleanEnds"     // launches in a row that ended that way
    case safeMode = "solstice.safeMode"
    case safeModeBuild = "solstice.safeModeBuild" // the build the two counts are for
    // Diagnostics
    case logStreamOn = "solstice.logstream.enabled"
    case logStreamHost = "solstice.logstream.host"
    case logStreamPort = "solstice.logstream.port"
    // The running Mac's panel, and hints shown once
    case screenBrightness = "solstice.display.brightness"
    case cursorScale = "solstice.cursor.scale"
    case controlsHintsShown = "solstice.controls.hintsShown"
    case stillWallpaperTipShown = "solstice.tips.stillWallpaperShown"
    /// Per Mac (forMac): its balloon handed over nothing (InstantResume).
    case balloonIdle = "solstice.balloonIdle."
    /// Read once, to give each Mac the app-wide CPU count of before (Machines.migrateCPUs).
    case legacyCPUs = "solstice.cpus"

    /// A per-Mac key: this one followed by the Mac's id.
    func forMac(_ id: UUID) -> String { rawValue + id.uuidString }
}

/// What a setting is until it is set, where that does not depend on the device: read by the views and the code alike.
enum SettingDefault {
    static let jitAtLaunch = true
    static let touchHold = 0.4
    static let touchTapDrag = 0.25
    static let scrollSpeed = 0.3
    static let mouseSpeed = 1.0
    static let keepAwake = true
    static let instantResume = true
    static let autoStartMac = true
    static let fastFlush = true
    static let logStreamPort = 7777
    static let screenBrightness = 1.0
}
