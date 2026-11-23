import Foundation

/// Every UserDefaults key the app uses. The strings are what is stored and stay as they are (a renamed key would lose
/// what people set); the "henge." ones date from before Solstice.
enum SettingKey: String, CaseIterable {
    // JIT
    case jitAtLaunch = "henge.jit.autoEnable"
    case jitPairingSource = "henge.jitPairingSource"
    // Pointer & Trackpad
    case touchMode = "henge.touch.mode"
    case touchHold = "henge.touch.hold"
    case touchTapDrag = "henge.touch.tapDrag"
    case scrollSpeed = "henge.mouse.scrollSpeed"
    case mouseSpeed = "henge.mouse.speed"
    case reverseScrolling = "henge.mouse.reverse"
    case swapMouseButtons = "henge.mouse.swapRightAndMiddle"
    // Mac's Keyboard
    case keyLayout = "henge.keyboard.layout"
    case syncClipboard = "henge.sharing.syncClipboard"
    // When You Leave
    case keepAwake = "henge.keepAlive"
    case instantResume = "henge.instantResume"
    case autoStartMac = "solstice.autoStartMac"
    case autoStartFailures = "solstice.autoStartFailures"
    // Appearance
    case appearance = "appearance"
    // Advanced
    case refreshRate = "henge.perf.hz"
    case codeCacheMB = "henge.perf.codeCacheMB"
    case fastFlush = "henge.perf.fastFlush"
    // Safe mode (SafeMode)
    case macLive = "solstice.macLive"             // a Mac is running with Solstice in the foreground
    case uncleanEnds = "solstice.uncleanEnds"     // launches in a row that ended that way
    case safeMode = "solstice.safeMode"
    case safeModeBuild = "solstice.safeModeBuild" // the build the two counts are for
    // Diagnostics
    case logStreamOn = "henge.logstream.enabled"
    case logStreamHost = "henge.logstream.host"
    case logStreamPort = "henge.logstream.port"
    // The running Mac's panel, and hints shown once
    case screenBrightness = "henge.display.brightness"
    case cursorScale = "henge.cursor.scale"
    case controlsHintsShown = "henge.controls.hintsShown"
    case stillWallpaperTipShown = "henge.tips.stillWallpaperShown"
    /// Per Mac (forMac): its balloon handed over nothing (InstantResume).
    case balloonIdle = "solstice.balloonIdle."
    /// Read once, to give each Mac the app-wide CPU count of before (Machines.migrateCPUs).
    case legacyCPUs = "henge.cpus"

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
