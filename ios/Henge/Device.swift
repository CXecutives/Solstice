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

    /// This device's starting values (DeviceProfile's table), from its memory, performance cores and signing.
    static let profile = DeviceProfile(
        physicalMB: Int(ProcessInfo.processInfo.physicalMemory >> 20),
        performanceCores: sysctlInt("hw.perflevel0.physicalcpu") ?? 2,
        memoryLimitMB: Entitlements.memoryLimitAtLaunch >> 20,
        extendedAddressing: Entitlements.extendedAddressing,
        isPad: isPad)

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
