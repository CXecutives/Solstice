import UIKit

/// What this device is, for what the app says and suggests.
enum Device {
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    static let name = isPad ? "iPad" : "iPhone"

    /// The panel, its density and its landscape insets, as MacScreen sizes a Mac's screen for them.
    static var screenFacts: ScreenFacts {
        let screen = UIScreen.main, n = screen.nativeBounds.size
        return ScreenFacts(panel: PixelSize(width: Int(max(n.width, n.height)), height: Int(min(n.width, n.height))),
                           scale: Double(screen.nativeScale), sideInset: landscapeSideInset,
                           ppi: DeviceProfile.ppi(isPad: isPad, scale: Double(screen.scale), mini: marketingName.contains("mini")),
                           kind: profile.screenClass)
    }

    /// What a Mac keeps clear of at each side on its side (the Dynamic Island or notch), the same at both so a turn by
    /// 180 degrees moves nothing. Upright the island is at the top, and the top inset is the same distance; the bottom
    /// one is only the home indicator. iPads have none.
    /// Read once a window is there and kept: a running Mac's screen must not change when the device turns.
    static var landscapeSideInset: Double {
        if let sideInset { return sideInset }
        guard !isPad else { return 0 }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return 0 }
        let i = window.safeAreaInsets, upright = window.bounds.height > window.bounds.width
        let inset = Double(max(i.left, i.right, upright ? i.top : 0))
        sideInset = inset
        return inset
    }
    private static var sideInset: Double?

    /// The size a Mac's screen preset gives here.
    static func macScreen(_ preset: ScreenPreset) -> MacScreen { MacScreen.resolve(preset, screenFacts) }

    /// The refresh rates macOS can be told on this panel (Settings > Advanced), and the one without a choice.
    static var refreshChoices: [Int] { DeviceProfile.refreshChoices(panelMax: UIScreen.main.maximumFramesPerSecond) }
    static let defaultRefresh = DeviceProfile.defaultRefresh

    /// This device's starting values (DeviceProfile's table), from its memory, performance cores and signing.
    static let profile = DeviceProfile(
        physicalMB: Int(ProcessInfo.processInfo.physicalMemory >> 20),
        performanceCores: sysctlInt("hw.perflevel0.physicalcpu") ?? 2,
        memoryLimitMB: Entitlements.memoryLimitAtLaunch >> 20,
        extendedAddressing: Entitlements.extendedAddressing,
        isPad: isPad)

    /// How much memory to suggest for a new Mac.
    static var suggestedRAMGB: Int { profile.suggestedGB }

    /// The screen a Mac made before presets got here by default (MacScreen.migrate keeps it Recommended).
    static var legacyScreen: (width: Int, height: Int, uiScale: Double?) {
        let b = UIScreen.main.bounds.size
        return MacScreen.legacyDefault(pointsLong: Double(max(b.width, b.height)), pointsShort: Double(min(b.width, b.height)),
                                       isPad: isPad, lean: profile.row.lean, ramGB: profile.ramGB)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    /// The choices for a Mac's memory, in GB: only what boots on this device (DeviceProfile).
    static var memoryChoices: ClosedRange<Int> { profile.memoryChoicesGB }

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
