import Foundation

/// Engine settings, without a rebuild. The engine's own defaults are in core/knobs.def (KNOBS.md); the app ships these
/// over them, then the Advanced settings, then Documents/solstice-env.txt (HV_ variables only, EnvOverrides) overrides
/// them all. Applied at launch and again before each Mac starts, so changes need no relaunch.
enum EngineTuning {

    /// What the upstream engine starts with. Safe mode (SafeMode, HV_SAFE) runs with exactly these.
    /// Each is set every time, also where it equals the engine's default: it replaces what an earlier apply set
    /// (a refresh rate or disk flush from the Advanced settings).
    static let upstream: [EngineKnob: String] = [
        // 60, not 120: every frame macOS draws is emulated and replayed, so 120 Hz
        // halves the CPU left for apps for animation few will notice. Settings offers 120 only on a 120 Hz panel.
        .hz: "60",             // the refresh rate macOS is told its display has (DeviceProfile.defaultRefresh)
        .wfiSpin: "0",         // microseconds an idle CPU watches for work before sleeping
        .flush: "2",           // disk flush: F_BARRIERFSYNC, ordered but without a full fsync
        // The memory balloon, asking for nothing: there for MemoryRelief when iOS runs short (KeepAlive.swift; #214).
        .balloon: "0",
        .stats: "10",          // seconds between engine stats lines in the log; 0 = off
    ]

    /// Solstice's own engine defaults, over upstream's: every one of them in this table and nowhere else.
    static let solstice: [EngineKnob: String] = [
        .stats: "30",          // (HV_STATS_DEEP=1: costly diagnostics too)
        // A CPU waiting for others' TLB acknowledgements sleeps after 64 spins instead of spinning on (#218:
        // 76% of a core down to 4-9% on an iPhone); TLB range invalidations of up to 256 pages in one pass.
        .syncWait: "1",
        .rangeDrop: "256",
        // Grouped memory accesses (v2: plain copies in the cold part, so the hot code grows by the checks only).
        .groups: "1",
        // Hot or in Low Power Mode (PowerPolicy): at most this many frames a second go to the screen. macOS still
        // draws at HV_HZ (its clock follows that rate); the screen, its compositing and the panel do half the work.
        .savingHz: "30",
    ]

    static var defaults: [String: String] { named(upstream.merging(solstice) { $1 }) }

    private static func named(_ table: [EngineKnob: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: table.map { ($0.key.rawValue, $0.value) })
    }

    static func apply() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var overrides: [String: String] = [:]
        let url = docs.appendingPathComponent(Brand.envFile)
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let parsed = EnvOverrides.parse(text, documents: docs.path)
            overrides = parsed.accepted
            if !parsed.refused.isEmpty {
                SolsticeLog.log("engine", "solstice-env.txt: ignored \(parsed.refused.joined(separator: ", ")) (only HV_ variables are taken)")
            }
        }
        // HV_SAFE=1 or 0 in solstice-env.txt decides it by hand.
        let safe = overrides[EngineKnob.safe.rawValue].map { $0 != "0" } ?? SafeMode.active
        var env = safe ? named(upstream) : defaults
        let d = UserDefaults.standard
        // A rate the panel cannot show (120 chosen before, or on another device) stays at the default.
        let hz = d.integer(forKey: SettingKey.refreshRate.rawValue)
        if hz != Device.defaultRefresh, Device.refreshChoices.contains(hz) { env[EngineKnob.hz.rawValue] = String(hz) }
        if d.object(forKey: SettingKey.fastFlush.rawValue) as? Bool == false { env[EngineKnob.flush.rawValue] = "0" }
        // GPU command trace: on while Documents/trace-on exists (it is checked every frame, so it can be toggled live).
        env[EngineKnob.pvgTraceFile.rawValue] = docs.appendingPathComponent("trace-on").path
        let safeKey = EngineKnob.safe.rawValue
        env[safeKey] = safe ? "1" : nil
        env.merge(overrides) { $1 }
        // A value of Solstice's from an earlier apply goes when safe mode leaves it out.
        for k in solstice.keys where env[k.rawValue] == nil { unsetenv(k.rawValue) }
        if env[safeKey] == nil { unsetenv(safeKey) }
        for (k, v) in env.sorted(by: { $0.key < $1.key }) {
            setenv(k, v, 1)
            SolsticeLog.log("tuning", "\(k)=\(v)")
        }
        solstice_vm_knobs_load() // the engine parses them now: anything wrong is in the log at once
        if safe { SolsticeLog.log("tuning", "safe mode: the upstream engine defaults, none of Solstice's") }
    }
}

/// Safe mode: after two launches in a row that ended while a Mac was running in the foreground (a crash, a hang
/// iOS's watchdog ended, a memory kill), the engine starts with upstream's defaults (EngineTuning.upstream)
/// until a new build is installed or it is turned off in Settings. Said once, when it comes on.
enum SafeMode {
    private(set) static var active = false
    /// It came on at this launch: the app says so once.
    private(set) static var justCameOn = false

    private static var build: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleVersion"] as? String ?? "?") \(info["SolsticeBuildCommit"] as? String ?? "unstamped")"
    }

    /// Once, at launch, before EngineTuning.apply.
    static func noteLaunch() {
        let d = UserDefaults.standard
        if d.string(forKey: SettingKey.safeModeBuild.rawValue) != build { // a new build starts afresh: it may be the fix
            d.set(build, forKey: SettingKey.safeModeBuild.rawValue)
            d.set(0, forKey: SettingKey.uncleanEnds.rawValue)
            d.set(false, forKey: SettingKey.safeMode.rawValue)
            d.set(false, forKey: SettingKey.macLive.rawValue)
        }
        let streak = d.bool(forKey: SettingKey.macLive.rawValue) ? d.integer(forKey: SettingKey.uncleanEnds.rawValue) + 1 : 0
        d.set(streak, forKey: SettingKey.uncleanEnds.rawValue)
        d.set(false, forKey: SettingKey.macLive.rawValue)
        if streak >= 2 && !d.bool(forKey: SettingKey.safeMode.rawValue) {
            d.set(true, forKey: SettingKey.safeMode.rawValue)
            justCameOn = true
        }
        active = d.bool(forKey: SettingKey.safeMode.rawValue)
        if streak > 0 { SolsticeLog.log("app", "the last \(streak) launch(es) ended while a Mac was running") }
        if active { SolsticeLog.log("app", "safe mode is on: the engine runs with the upstream engine defaults") }
    }

    /// A Mac runs and Solstice is in front: ending now would count.
    static func macLive(_ live: Bool) {
        UserDefaults.standard.set(live, forKey: SettingKey.macLive.rawValue)
    }

    static func turnOff() {
        UserDefaults.standard.set(false, forKey: SettingKey.safeMode.rawValue)
        UserDefaults.standard.set(0, forKey: SettingKey.uncleanEnds.rawValue)
        active = false
        SolsticeLog.log("app", "safe mode turned off: Solstice's engine defaults from the next Mac start")
    }
}
