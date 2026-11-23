import SwiftUI

/// A running Mac's lifecycle, for the SessionView that owns it: starting or resuming the Mac, polling the engine
/// while it runs, watching storage, and shutting it down. What the view shows of the Mac comes from here.
@MainActor
final class SessionController: ObservableObject {
    let mac: VirtualMac

    @Published private(set) var error: String?
    @Published private(set) var state: Int32 = 0
    @Published private(set) var cpusOn: Int32 = 0
    @Published private(set) var userCode = false
    @Published private(set) var blocksPerSecond: Double = 0
    @Published private(set) var framesOut: UInt64 = 0
    @Published private(set) var framesIn: UInt64 = 0
    @Published private(set) var log: [String] = []
    @Published private(set) var started = Date()
    @Published private(set) var bootRAM: UInt64 = 0 /* what the Mac was started with, which a save is for */
    @Published private(set) var helperRunning = false
    /// Paused because storage ran short (StorageGuard), and whether there is room to run on again.
    @Published private(set) var storagePaused = false
    @Published private(set) var storageRoom = false
    @Published private(set) var storageFree: Int64 = 0

    /// What the run loop asks of the view, and tells it.
    struct Hooks {
        /// Details are on screen: what only they show is kept up to date.
        var detailsShown: () -> Bool
        var inBackground: () -> Bool
        /// The Mac stopped: the view lets go of what it shows over it.
        var stopped: () -> Void
        /// It stopped to restart: start it again.
        var restart: () -> Void
        /// It has been up about a minute.
        var minuteUp: () -> Void
    }

    init(mac: VirtualMac) { self.mac = mac }

    func run(cpus: Int, hooks: Hooks) async {
        error = nil
        state = 0
        userCode = false
        cpusOn = 0
        blocksPerSecond = 0
        framesOut = 0
        framesIn = 0
        while henge_vm_state() == 3 && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !Task.isCancelled else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        HardwareMouse.shared.start()
        let ram = GuestMemory.prepare(mac, cpus: cpus)
        HengeLog.log("session", "available memory \(henge_available_memory() >> 20) MB")
        guard ram >= 1024 else {
            error = "There is not room for this Mac's memory: it needs a few GB of free storage."
            return
        }
        var buffer = [CChar](repeating: 0, count: 256)
        JITBootstrap.releaseLingeringDebugger()
        Sharing.prepare()
        EngineTuning.apply()
        henge_vm_set_display(UInt32(mac.screen.width), UInt32(mac.screen.height))
        if mac.isRetina {
            henge_vm_set_display_mm(UInt32(mac.retinaMM.width), UInt32(mac.retinaMM.height))
        } else {
            henge_vm_set_display_mm(0, 0)
        }
        HengeLog.log("session", "screen \(mac.screen.width)x\(mac.screen.height) retina \(mac.isRetina)")
        if mac.reportHostIdentity == true {
            let modelID = Device.snappedModelIdentifier(forOS: mac.osName)
            henge_vm_set_identity(Device.chipName, Device.marketingName,
                                  mac.reportHostModelID == true ? modelID : nil)
            HengeLog.log("session", "About This Mac reports \(Device.marketingName) (model \(modelID))")
        } else {
            henge_vm_set_identity(nil, nil, nil)
        }
        var rc: Int32 = -1
        if InstantResume.enabled, let at = InstantResume.saved(for: mac, ramMB: ram, cpus: cpus) {
            HengeLog.log("resume", "picking up the Mac saved \(Int(Date().timeIntervalSince(at))) s ago")
            let t0 = Date()
            rc = henge_vm_resume(mac.rom.path, mac.disk.path, mac.aux.path, mac.ecid, mac.seed, ram, Int32(cpus),
                                 InstantResume.file(for: mac).path, InstantResume.ident(for: mac, ramMB: ram, cpus: cpus), &buffer, buffer.count)
            if rc == 0 {
                HengeLog.log("resume", String(format: "resumed in %.1f s", Date().timeIntervalSince(t0)))
            } else {
                HengeLog.log("resume", "could not resume (\(String(cString: buffer))); starting it from cold")
                buffer = [CChar](repeating: 0, count: 256)
            }
        }
        InstantResume.discard(for: mac) /* used or out of date: the disk moves on from here */
        if rc != 0 {
            rc = henge_vm_boot(mac.rom.path, mac.disk.path, mac.aux.path, mac.ecid, mac.seed, ram, Int32(cpus), &buffer, buffer.count)
        }
        if rc != 0 {
            error = String(cString: buffer)
            return
        }
        bootRAM = ram
        started = Date()
        StorageGuard.holding = false
        storagePaused = false
        if !hooks.inBackground() { SafeMode.macLive(true) } // a crash or hang from here on counts (SafeMode)
        var used = mac
        used.lastUsed = started
        Machines.shared.update(used)
        var lastBlocks = henge_vm_blocks()
        var lastTime = Date()
        var lastGPUFrames = henge_vm_gpu_frames()
        var tick = 0
        while !Task.isCancelled {
            let now_state = henge_vm_state()
            if now_state != state { state = now_state }
            if state == 3 || state == 4 { /* starting, stopping, or paused (Henge in the background, or storage short) */
                try? await Task.sleep(nanoseconds: storagePaused ? 1_000_000_000 : 100_000_000)
                continue
            }
            if !userCode && henge_vm_guest_el0() != 0 { userCode = true }
            let now = Date(), blocks = henge_vm_blocks()
            let rate = Double(blocks &- lastBlocks) / max(now.timeIntervalSince(lastTime), 0.001)
            lastBlocks = blocks
            lastTime = now
            // What only Details shows is copied into the view's state only while it shows: each copy redraws the
            // session, once a second, for nothing otherwise (200 log lines among it).
            if hooks.detailsShown() {
                blocksPerSecond = rate
                refreshDetails()
            }
            if Sharing.helperRunning != helperRunning { helperRunning = Sharing.helperRunning }
            if state == 2 {
                SafeMode.macLive(false)
                hooks.stopped()
                StickyKeys.shared.releaseAll()
                HardwareKeys.releaseAll()
                HardwareMouse.shared.stop()
                UIApplication.shared.isIdleTimerDisabled = false
                HengeLog.log("session", "showing stopped Mac: \(String(cString: henge_vm_exit_reason()))")
                if henge_vm_exit_outcome() == Int32(HENGE_VM_OUTCOME_RESTART.rawValue) && henge_vm_can_start() != 0 {
                    hooks.restart()
                }
                break
            }
            tick += 1
            if tick % 10 == 0 {
                let gpuFrames = henge_vm_gpu_frames()
                HengeLog.log("perf", "blocks/s \(String(format: "%.0f", rate)), GPU frames/10s \(gpuFrames &- lastGPUFrames), "
                             + "network tx \(henge_vm_net_frames(1)), rx \(henge_vm_net_frames(0)), dns \(henge_vm_dns(0)) answered \(henge_vm_dns(2)) unanswered, "
                             + "thermal \(PowerPolicy.label(PowerPolicy.shared.thermal))")
                lastGPUFrames = gpuFrames
                JITBootstrap.releaseLingeringDebugger()
            }
            if tick == 60 { AutoStart.succeeded() } // a minute up: the auto-start guard counts afresh
            if tick == 60 { hooks.minuteUp() }
            if tick % 30 == 0 { HengeLog.logFootprint("session") } // how close to the limit, for a memory kill leaves no crash report
            if tick % 60 == 0 { MacPreview.save(for: mac) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// What Details shows of the running Mac, now.
    func refreshDetails() {
        cpusOn = henge_vm_cpus_on()
        framesOut = henge_vm_net_frames(1)
        framesIn = henge_vm_net_frames(0)
        log = Array(HengeLog.recentLines(200))
    }

    /// Every 10 s (2 s while paused for it): free storage against StorageGuard's floor.
    func watchStorage() async {
        while !Task.isCancelled {
            if let free = StorageGuard.freeBytes() {
                if storagePaused || free < StorageGuard.minimumFree { storageFree = free } // only shown then
                if !storagePaused && !StorageGuard.holding && free < StorageGuard.minimumFree && henge_vm_state() == 1 {
                    storagePaused = true
                    storageRoom = false
                    StorageGuard.holding = true
                    HengeLog.log("storage", "\(free >> 20) MB free, under \(StorageGuard.minimumFree >> 20) MB: pausing the Mac")
                    InstantResume.holdForStorage { [weak self] paused in
                        guard !paused else { return }
                        // It was not running after all (stopping, or paused by Henge): nothing to hold.
                        StorageGuard.holding = false
                        self?.storagePaused = false
                    }
                }
                if storagePaused { storageRoom = free >= StorageGuard.resumeAt }
            }
            if storagePaused && henge_vm_state() == 2 { // shut down meanwhile
                StorageGuard.holding = false
                storagePaused = false
            }
            try? await Task.sleep(nanoseconds: storagePaused ? 2_000_000_000 : 10_000_000_000)
        }
    }

    /// There is room again: the Mac runs on.
    func resumeAfterStorage() {
        StorageGuard.holding = false
        storagePaused = false
        InstantResume.releaseStorageHold()
    }

    /// Turns the Mac off at once (the view closes after).
    func shutDown() {
        SafeMode.macLive(false)
        StorageGuard.holding = false
        if state == 1 || state == 4 {
            MacPreview.saveNow(for: mac)
            henge_vm_stop()
        }
        InstantResume.discard(for: mac) /* turned off: nothing to pick up */
    }
}
