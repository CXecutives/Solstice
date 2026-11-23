import Foundation

/// This device's starting values: the one table for what its memory allows, computed from values passed in (Device.profile
/// passes this device's), so it can be tested without one. Pure Foundation: tests/test_device_profile.swift compiles it.
struct DeviceProfile: Equatable {
    /// One memory class of devices, by physical memory.
    struct Row: Equatable {
        let belowMB: Int     // physical memory under this, in MB
        let ramGB: Int       // what leaves iOS room (GuestMemory.prepare caps it again at boot)
        let maxCPUs: Int     // the guest takes CPUs as equals: more than the P cores + 1 only queue on E cores
        let codeCacheMB: Int // with the increased memory limit; the signing may allow less (codeCacheMB below)
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
        /// The most guest RAM that boots beside the engine and iOS, in MB (nil: any).
        let guestCapMB: UInt64?
        /// The least memory: smaller Mac screens (screenRow) on any device.
        let lean: Bool
    }

    /// 4 GB (iPad Air 4, A14): the least that runs; a 2 GB Mac, and as little else as possible: a 384 MB code cache (its
    /// records come to another 200-270 MB).
    /// 6-8 GB: a 4 GB Mac, its code cache and records left iOS so little that it closed Henge (#214), so 3 GB suggested;
    /// a 6 GB device installed a 3 GB Mac too (#70). At boot an 8 GB device cannot hold a 4 GB Mac beside the engine
    /// (its code cache and records come to 2.5 GB or more) and iOS: an iPad Pro M4 compressed 7 GB and then closed Henge
    /// four minutes in. 3 GB there, 2 GB on 6 GB; macOS makes up the difference with its own swap, on the Mac's disk,
    /// which iOS has none of. 1 GB of code cache beside a 3 GB Mac: with 768 MB the first device run re-translated 85%
    /// of its blocks (evicted code wanted again) while 3.7 GB of the app's 6.1 GB limit stayed free.
    /// 12-16 GB: 1.5 GB of code cache where the signing allows it; 16 GB: room for a 6 GB Mac.
    static let rows: [Row] = [
        Row(belowMB: 5_000, ramGB: 2, maxCPUs: 2, codeCacheMB: 384, headroomMB: 340...700, guestCapMB: 2048, lean: true),
        Row(belowMB: 6_701, ramGB: 3, maxCPUs: 4, codeCacheMB: 1024, headroomMB: 600...1100, guestCapMB: 2048, lean: false),
        Row(belowMB: 8_701, ramGB: 3, maxCPUs: 4, codeCacheMB: 1024, headroomMB: 600...1100, guestCapMB: 3072, lean: false),
        // No device has this much: kept so the table gives what the earlier thresholds gave.
        Row(belowMB: 9_000, ramGB: 3, maxCPUs: 4, codeCacheMB: 1024, headroomMB: 600...1100, guestCapMB: nil, lean: false),
        Row(belowMB: 14_000, ramGB: 3, maxCPUs: 4, codeCacheMB: 1536, headroomMB: 1100...2100, guestCapMB: nil, lean: false),
        Row(belowMB: .max, ramGB: 6, maxCPUs: 5, codeCacheMB: 1536, headroomMB: 1100...2100, guestCapMB: nil, lean: false),
    ]

    /// What Settings > Performance > Code cache offers, in MB.
    static let codeCacheChoices = [384, 512, 768, 1024, 1536]
    /// The code cache the signing allows: above 1 GB only with a memory limit of 5.5 GB and extended-virtual-addressing
    /// (generated code only runs below 0x7000000000, and without that entitlement the largest hole there is about
    /// 1080 MiB); at most 512 MB under a 3.5 GB limit (4-6 GB devices without the increased limit, where 1 GB and its
    /// records left a 2 GB Mac too little room in Setup, #70).
    static let largeCacheLimitMB = 5_500
    static let smallCacheLimitMB = 3_500

    let row: Row
    var ramGB: Int { row.ramGB }
    let cpus: Int
    /// How this device sizes a Mac's screen (screenRow).
    let screenClass: ScreenClass
    var headroomMB: ClosedRange<Int> { row.headroomMB }
    var guestCapMB: UInt64? { row.guestCapMB }
    /// The code cache without a choice in Settings, as the signing allows.
    let codeCacheMB: Int
    let extendedAddressing: Bool

    init(physicalMB: Int, performanceCores: Int, memoryLimitMB: Int, extendedAddressing: Bool, isPad: Bool) {
        row = Self.rows.first { physicalMB < $0.belowMB } ?? Self.rows[Self.rows.count - 1]
        // iPhone 16 Pro (2 P + 4 E): 3. M-series iPads: 4, or one past the P cores with 16 GB.
        cpus = min(max(performanceCores + 1, 3), row.maxCPUs)
        // 8 GB and more: an iPad Pro (or an Air or mini with an M chip) draws its own panel at Retina density.
        let big = physicalMB >= Self.rows[1].belowMB
        screenClass = isPad ? (row.lean ? .leanPad : big ? .bigPad : .pad) : (row.lean ? .leanPhone : .phone)
        let device = row.codeCacheMB
        if device > 1024 {
            codeCacheMB = memoryLimitMB >= Self.largeCacheLimitMB && extendedAddressing ? device : 1024
        } else {
            codeCacheMB = memoryLimitMB >= Self.smallCacheLimitMB ? device : min(device, 512)
        }
        self.extendedAddressing = extendedAddressing
    }

    /// The JIT region for the launch, in MB: the choice in Settings (or the default) where the signing allows it.
    func jitMB(chosen: Int?) -> Int {
        let mb = chosen ?? codeCacheMB
        if mb > 1024 && !extendedAddressing { return 1024 }
        return Self.codeCacheChoices.contains(mb) ? mb : 1024
    }

    // MARK: Screens (MacScreen.swift sizes them)

    enum ScreenClass: Equatable { case phone, leanPhone, pad, leanPad, bigPad }

    /// What a preset aims for: a 1x Mac screen this many pixels tall (as wide as the device's shape), a factor
    /// (device pixels per Mac pixel), or the panel itself at Retina density (macOS draws 2x, nothing is scaled).
    enum ScreenTarget: Equatable { case height(Int), factor(Double), native }

    struct ScreenRow: Equatable {
        let larger: ScreenTarget      // a smaller desktop: bigger text, less for the Mac to draw
        let recommended: ScreenTarget
        let moreSpace: ScreenTarget   // the next larger desktop
        let retina: Bool              // Retina offered (a full-panel 2x Mac is heavy: not with a 2 GB Mac)
    }

    /// Phones keep their desktop 864 tall (1x, filling the landscape safe area: 1608 × 864 on an iPhone 16 Pro (62-point insets) shown at
    /// about 1.4x), so it is not cramped; iPads with a 2 GB Mac show half the panel at exactly 2x (1176 × 816 on an Air 4,
    /// crisp with nearest scaling); 8 GB iPads draw their own panel at Retina density.
    static func screenRow(_ kind: ScreenClass) -> ScreenRow {
        switch kind {
        case .phone: return ScreenRow(larger: .height(720), recommended: .height(864), moreSpace: .height(1080), retina: true)
        case .leanPhone: return ScreenRow(larger: .height(640), recommended: .height(720), moreSpace: .height(864), retina: false)
        case .leanPad: return ScreenRow(larger: .factor(2.5), recommended: .factor(2), moreSpace: .factor(1.7), retina: false)
        case .pad: return ScreenRow(larger: .factor(2.5), recommended: .factor(2), moreSpace: .factor(1.5), retina: true)
        case .bigPad: return ScreenRow(larger: .factor(2), recommended: .native, moreSpace: .factor(1.5), retina: true)
        }
    }

    /// The panel's real pixel density: 460 on 3x iPhones (all OLED models, 458-460), 326 on 2x iPhones and the iPad mini,
    /// 264 on other iPads; otherwise an estimate from the scale.
    static func ppi(isPad: Bool, scale: Double, mini: Bool) -> Double {
        switch (isPad, scale) {
        case (true, 2): return mini ? 326 : 264
        case (false, 3): return 460
        case (false, 2): return 326
        default: return isPad ? 132 * scale : 153 * scale
        }
    }

    /// The refresh rates macOS can be told, as far as the panel shows them (a 60 Hz panel never shows 120: macOS would
    /// draw frames nobody sees). 60 without a choice.
    static let refreshRates = [30, 60, 120]
    static let defaultRefresh = 60
    static func refreshChoices(panelMax: Int) -> [Int] { refreshRates.filter { $0 <= max(panelMax, defaultRefresh) } }
}
