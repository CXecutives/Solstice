import UIKit

/// What this device is, for what the app says and suggests.
enum Device {
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    static let name = isPad ? "iPad" : "iPhone"

    /// A Mac's screen that fills this device on its side: 1920 wide, as tall as the shape asks. iPads and
    /// squarer phones (iPhone Duo, about 1.46:1) would get bars above and below at 16:9. Phones wider
    /// than 16:9 come out at 1920×1080, as before.
    static var fittingScreen: (width: Int, height: Int) {
        let size = UIScreen.main.bounds.size
        let shape = max(size.width, size.height) / max(min(size.width, size.height), 1)
        return (1920, min(max(Int((1920 / shape / 8).rounded()) * 8, 1080), 1440))
    }

    /// Preserve the iPad's shape while reducing the virtual GPU's pixel work.
    static var performanceScreen: (width: Int, height: Int) {
        let fit = fittingScreen
        return (1600, Int((Double(fit.height) * 5 / 6 / 8).rounded()) * 8)
    }

    /// The panel itself, on its side: every physical pixel, and its real size in mm so that macOS
    /// sees a Retina density and draws at 2x (looks like half the pixels, sharp as the iPad's own UI).
    /// Every iPad with an M chip is 264 ppi.
    static var retinaScreen: (width: Int, height: Int) {
        let n = UIScreen.main.nativeBounds.size
        return (Int(max(n.width, n.height)) / 8 * 8, Int(min(n.width, n.height)) / 8 * 8)
    }
    static var retinaMM: (width: Int, height: Int) {
        let s = retinaScreen
        return (Int((Double(s.width) / 264 * 25.4).rounded()), Int((Double(s.height) / 264 * 25.4).rounded()))
    }

    /// This device's starting values: the one table for them, from its memory and its performance cores.
    struct MacProfile {
        let ramGB: Int      // what leaves iOS room (GuestMemory.prepare caps it again at boot)
        let cpus: Int       // the guest takes CPUs as equals: more than the P cores + 1 only queue on E cores
        let uiScale: Double? // Size of Things (#215): less for the Mac to draw where the screen is small
        let performanceScreen: Bool
        /// The code cache with the increased memory limit (JITBootstrap.defaultCodeCacheMB applies the signing).
        let codeCacheMB: Int
        /// The system's available memory as jetsam counts it (free and file-backed pages, henge_system_headroom_mb)
        /// that MemoryRelief keeps the Mac between: under the low mark the Mac hands memory over in 256 MB steps,
        /// over the high mark it gets it back slowly. From XNU's jetsam levels (bsd/kern/kern_memorystatus.c, the
        /// fallback table: at most 6 GB idle apps are closed under 9% available and apps warned under 15%, above
        /// 6 GB under 8% and 12%; 4% is critical; a device's own values may differ, and the log shows each step's
        /// headroom). The low mark is about where iOS starts closing suspended apps:
        /// they go before the Mac shrinks, and the Mac is still asked well before critical, where the pressure
        /// path's 1 GB used to come too late. The high mark sits just over the warning level, which a calm device
        /// gets back to (so memory handed over does not stay away for good), and more than one step above the low
        /// mark, so a step either way cannot cross the other mark (no seesaw).
        let headroomMB: ClosedRange<Int>
    }

    static let profile: MacProfile = {
        let mb = Int(ProcessInfo.processInfo.physicalMemory >> 20)
        let pCores = sysctlInt("hw.perflevel0.physicalcpu") ?? 2
        // 4 GB (iPad Air 4, A14): the least that runs; a 2 GB Mac, and as little else as possible: a 384 MB code
        // cache (its records come to another 200-270 MB).
        if mb < 5_000 {
            return MacProfile(ramGB: 2, cpus: 2, uiScale: 2.0 / 3, performanceScreen: true, codeCacheMB: 384,
                              headroomMB: 340...700)
        }
        // 8 GB: a 4 GB Mac, its code cache and records left iOS so little that it closed Henge (#214), so 3 GB.
        // A 6 GB device installed a 3 GB Mac too (#70). 16 GB: room for 6.
        let ram = mb >= 14_000 ? 6 : 3
        // iPhone 16 Pro (2 P + 4 E): 3. M-series iPads: 4, or one past the P cores with 16 GB.
        let cpus = pCores <= 2 ? 3 : mb >= 14_000 ? min(pCores + 1, 5) : 4
        // 6-8 GB (iPhone 16 Pro): 1 GB of code cache beside a 3 GB Mac. With 768 MB the first device run re-translated
        // 85% of its blocks (evicted code wanted again) while 3.7 GB of the app's 6.1 GB limit stayed free.
        // 12-16 GB: 1.5 GB where the signing allows it, else 1 GB (JITBootstrap).
        let big = mb >= 9_000
        return MacProfile(ramGB: ram, cpus: cpus, uiScale: isPad ? nil : 0.8, performanceScreen: isPad,
                          codeCacheMB: big ? 1536 : 1024, headroomMB: big ? 1100...2100 : 600...1100)
    }()

    /// How much memory to suggest for a new Mac.
    static var suggestedRAMGB: Int { profile.ramGB }

    /// A new Mac's screen before Size of Things.
    static var newMacScreen: (width: Int, height: Int) {
        profile.performanceScreen && profile.ramGB > 2 ? performanceScreen : fittingScreen
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    /// The choices for a Mac's memory, in GB.
    static let memoryChoices = 1...16

    /// What a choice risks on this device, if anything. An install always gets at least 2 GB (Installer.install).
    static func memoryNote(_ gb: Int) -> String? {
        if gb < suggestedRAMGB { return "macOS has little room under \(suggestedRAMGB) GB here, so it can be very slow." }
        if gb > suggestedRAMGB { return "More than \(suggestedRAMGB) GB is a lot for this \(name): iOS may close Henge when macOS gets busy." }
        return nil
    }

    /// The virtual CPU offers Armv8.5 instructions (core/sysreg.c), and macOS uses them. They run as
    /// they are, so the chip needs them too: A14, M1 and later, which is iPhone13,x and iPad13,x up.
    static let chipTooOld: Bool = {
        let model = HengeLog.deviceModel
        guard model.hasPrefix("iPhone") || model.hasPrefix("iPad"),
              let major = Int(model.drop { !$0.isNumber }.prefix { $0.isNumber }) else { return false }
        return major < 13
    }()

    static let chipTooOldText = "macOS won't run on this \(name). Henge needs an A14 or M1 chip or newer."

    /// What this device is called and the chip it has, for a Mac that reports its host
    /// (MacSettingsView → About This Mac). The table and the icon-snapping live in
    /// DeviceIdentity.swift (pure Foundation, so the Mac tests can compile it).
    static var modelIdentifier: String { HengeLog.deviceModel }
    static var marketingName: String { DeviceIdentity.name(modelIdentifier) }
    static var chipName: String? { DeviceIdentity.chip(modelIdentifier) }

    /// The model identifier to report for a matching icon: the real one when the guest
    /// macOS knows it, else the newest equivalent it recognises (see DeviceIdentity).
    static func snappedModelIdentifier(forOS osName: String?) -> String {
        DeviceIdentity.snappedIdentifier(modelIdentifier, forOS: osName)
    }
}
