import SwiftUI

/// A running Mac's lifecycle, for the SessionView that owns it: starting or resuming the Mac, polling the engine
/// while it runs, watching storage, and shutting it down. What the view shows of the Mac comes from here. The slow
/// parts (sizing its memory, booting or resuming, asking for free storage) run off the main thread.
@MainActor
final class SessionController: ObservableObject {
    let mac: VirtualMac

    @Published private(set) var error: String?
    @Published private(set) var state = HENGE_VM_IDLE
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
    /// Something that should have ended long ago has not (LifecycleWatchdog): the view offers a way out.
    @Published private(set) var stuck: LifecycleWatchdog.Stuck?
    /// Shut Down pressed the Mac's power button: macOS is shutting down (or asking first).
    @Published private(set) var shutdownAsked: Date?

    /// What the run loop asks of the view, and tells it.
    struct Hooks {
        /// Details are on screen: what only they show is kept up to date.
        var detailsShown: () -> Bool
        var inBackground: () -> Bool
        /// The Mac stopped: the view lets go of what it shows over it.
        var stopped: () -> Void
        /// It stopped to restart: start it again.
        var restart: () -> Void
        /// It shut down because Shut Down asked it to: the view closes.
        var shutDown: () -> Void
        /// It has been up about a minute.
        var minuteUp: () -> Void
    }

    init(mac: VirtualMac) { self.mac = mac }

    /// Runs work on InstantResume's queue (in turn with pausing and saving) and waits for it without holding the main thread.
    private func offMain<T>(_ what: String, _ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { done in InstantResume.run(what) { done.resume(returning: work()) } }
    }

    func run(cpus: Int, hooks: Hooks) async {
        error = nil
        stuck = nil
        shutdownAsked = nil
        state = HENGE_VM_IDLE
        userCode = false
        cpusOn = 0
        blocksPerSecond = 0
        framesOut = 0
        framesIn = 0
        // The last Mac may still be finishing its shutdown; one that never does gets a way out instead of a spinner.
        let waitSince = Date()
        while henge_vm_state() == HENGE_VM_STARTING_OR_STOPPING && !Task.isCancelled {
            let now = Date()
            if stuck == nil && now >= quietUntil && now.timeIntervalSince(waitSince) > LifecycleWatchdog.stopLimit {
                HengeLog.log("session", "watchdog: the last Mac has not finished shutting down in \(Int(LifecycleWatchdog.stopLimit)) s")
                stuck = .stopping
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        stuck = nil
        guard !Task.isCancelled else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        HardwareMouse.shared.start()
        let mac = self.mac
        let ram = await offMain("size memory") { GuestMemory.prepare(mac, cpus: cpus) }
        HengeLog.log("session", "available memory \(henge_available_memory() >> 20) MB")
        guard ram >= 1024 else {
            error = "There is not room for this Mac's memory: it needs a few GB of free storage."
            return
        }
        JITBootstrap.releaseLingeringDebugger()
        Sharing.prepare()
        EngineTuning.apply()
        let screen = mac.macScreen
        henge_vm_set_display(UInt32(screen.pixels.width), UInt32(screen.pixels.height))
        henge_vm_set_display_mm(UInt32(screen.mm?.width ?? 0), UInt32(screen.mm?.height ?? 0))
        HengeLog.log("session", "screen \(mac.preset.rawValue) \(screen.pixels.width)x\(screen.pixels.height) mm \(screen.mm.map { "\($0.width)x\($0.height)" } ?? "none") shown at \(String(format: "%.3f", screen.factor))x")
        henge_vm_set_keyboard_iso(KeyLayout.current.isISO ? 1 : 0) // the Mac reads its keyboard's kind as it starts
        if mac.reportHostIdentity == true {
            let modelID = Device.snappedModelIdentifier(forOS: mac.osName)
            henge_vm_set_identity(Device.chipName, Device.marketingName,
                                  mac.reportHostModelID == true ? modelID : nil)
            HengeLog.log("session", "About This Mac reports \(Device.marketingName) (model \(modelID))")
        } else {
            henge_vm_set_identity(nil, nil, nil)
        }
        let resumeAt = InstantResume.enabled ? InstantResume.saved(for: mac, ramMB: ram, cpus: cpus) : nil
        let file = InstantResume.file(for: mac).path, ident = InstantResume.ident(for: mac, ramMB: ram, cpus: cpus)
        // A resume decompresses gigabytes and a boot opens the disk: never on the main thread.
        let (rc, reason) = await offMain("start") { () -> (Int32, String) in
            var buffer = [CChar](repeating: 0, count: 256)
            var rc: Int32 = -1
            if let at = resumeAt {
                HengeLog.log("resume", "picking up the Mac saved \(Int(Date().timeIntervalSince(at))) s ago")
                let t0 = Date()
                let resumed = henge_vm_resume(mac.rom.path, mac.disk.path, mac.aux.path, mac.ecid, mac.seed, ram, Int32(cpus),
                                              file, ident, &buffer, buffer.count)
                if resumed == HENGE_VM_RESUMED {
                    HengeLog.log("resume", String(format: "resumed in %.1f s", Date().timeIntervalSince(t0)))
                    rc = 0
                } else if resumed == HENGE_VM_RESUME_REFUSED {
                    HengeLog.log("resume", "could not resume (\(String(cString: buffer))); starting it from cold")
                    buffer = [CChar](repeating: 0, count: 256)
                } else {
                    // Of the moment (memory, no JIT): the save is the only copy of the Mac's memory, so it stays for the next try.
                    HengeLog.log("resume", "could not resume (\(String(cString: buffer))); the save is kept")
                    return (-1, String(cString: buffer))
                }
            }
            if rc != 0 {
                // From cold the disk moves on: a save left over (another build or settings, or turned off) is out of date.
                InstantResume.discard(for: mac)
                rc = henge_vm_boot(mac.rom.path, mac.disk.path, mac.aux.path, mac.ecid, mac.seed, ram, Int32(cpus), &buffer, buffer.count)
            }
            return (rc, String(cString: buffer))
        }
        if rc != 0 {
            error = reason
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
        var inFront: TimeInterval = 0, lastLoop = Date(), counted = false
        while !Task.isCancelled {
            let loopTime = Date()
            if !hooks.inBackground() { inFront += loopTime.timeIntervalSince(lastLoop) } // wall time the Mac was up in front
            lastLoop = loopTime
            if !counted && inFront >= AutoStart.upFor { // up a while in front: the auto-start guard counts afresh
                counted = true
                AutoStart.succeeded()
            }
            let now_state = henge_vm_state()
            if now_state != state { state = now_state }
            watch()
            if state == HENGE_VM_STARTING_OR_STOPPING || state == HENGE_VM_PAUSED { /* starting, stopping, or paused (Solstice in the background, heat, or storage) */
                // Paused nothing changes until someone runs it on, which is not this loop: once a second is plenty.
                try? await Task.sleep(nanoseconds: state == HENGE_VM_PAUSED ? 1_000_000_000 : 100_000_000)
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
            if state == HENGE_VM_STOPPED {
                SafeMode.macLive(false)
                hooks.stopped()
                StickyKeys.shared.releaseAll()
                HardwareKeys.releaseAll()
                HardwareMouse.shared.stop()
                UIApplication.shared.isIdleTimerDisabled = false
                HengeLog.log("session", "showing stopped Mac: \(String(cString: henge_vm_exit_reason()))")
                let outcome = henge_vm_exit_outcome()
                if outcome == Int32(HENGE_VM_OUTCOME_RESTART.rawValue) && henge_vm_can_start() != 0 {
                    hooks.restart()
                } else if shutdownAsked != nil && outcome == Int32(HENGE_VM_OUTCOME_SHUTDOWN.rawValue) {
                    InstantResume.discard(for: mac) /* shut down: nothing to pick up */
                    hooks.shutDown()
                }
                shutdownAsked = nil
                stuck = nil
                break
            }
            _ = henge_vm_drop_spent_save() // the saved Mac goes once this one writes its disk
            tick += 1
            if tick % 10 == 0 {
                let gpuFrames = henge_vm_gpu_frames()
                HengeLog.log("perf", "blocks/s \(String(format: "%.0f", rate)), GPU frames/10s \(gpuFrames &- lastGPUFrames), "
                             + "network tx \(henge_vm_net_frames(1)), rx \(henge_vm_net_frames(0)), dns \(henge_vm_dns(0)) answered \(henge_vm_dns(2)) unanswered, "
                             + "thermal \(PowerPolicy.label(PowerPolicy.shared.thermal))")
                lastGPUFrames = gpuFrames
                JITBootstrap.releaseLingeringDebugger()
            }
            if tick == 60 { hooks.minuteUp() }
            if tick % 30 == 0 { HengeLog.logFootprint("session") } // how close to the limit, for a memory kill leaves no crash report
            if tick % 60 == 0 { MacPreview.save(for: mac) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Since when the Mac has been stopping, and until when the owner said to wait (LifecycleWatchdog).
    private var stoppingSince: Date?
    private var quietUntil = Date.distantPast

    /// Each turn of the run loop: what should have ended by now and has not.
    private func watch() {
        let now = Date()
        if state == HENGE_VM_STARTING_OR_STOPPING { stoppingSince = stoppingSince ?? now } else { stoppingSince = nil }
        guard now >= quietUntil else { return }
        let found = LifecycleWatchdog.check(
            stoppingFor: stoppingSince.map { now.timeIntervalSince($0) },
            queue: InstantResume.busyFor(now),
            shutdownFor: state == HENGE_VM_RUNNING ? shutdownAsked.map { now.timeIntervalSince($0) } : nil)
        guard found != stuck else { return }
        if let found { HengeLog.log("session", "watchdog: \(found.logLine)") }
        stuck = found
    }

    /// What Details shows of the running Mac, now.
    func refreshDetails() {
        cpusOn = henge_vm_cpus_on()
        framesOut = henge_vm_net_frames(1)
        framesIn = henge_vm_net_frames(0)
        log = Array(HengeLog.recentLines(200))
    }

    /// Every 10 s (2 s while paused for it): free storage against StorageGuard's floor. Asked off the main thread.
    func watchStorage() async {
        while !Task.isCancelled {
            let reading: Int64? = await withCheckedContinuation { (done: CheckedContinuation<Int64?, Never>) in
                DispatchQueue.global(qos: .utility).async { done.resume(returning: StorageGuard.freeBytes()) }
            }
            if let free = reading {
                if storagePaused || free < StorageGuard.minimumFree { storageFree = free } // only shown then
                if !storagePaused && !StorageGuard.holding && free < StorageGuard.minimumFree && henge_vm_state() == HENGE_VM_RUNNING {
                    storagePaused = true
                    storageRoom = false
                    StorageGuard.holding = true
                    HengeLog.log("storage", "\(free >> 20) MB free, under \(StorageGuard.minimumFree >> 20) MB: pausing the Mac")
                    InstantResume.holdForStorage { [weak self] paused in
                        guard !paused else { return }
                        // It was not running after all (stopping, or paused by Solstice): nothing to hold.
                        StorageGuard.holding = false
                        self?.storagePaused = false
                    }
                }
                if storagePaused { storageRoom = free >= StorageGuard.resumeAt }
            }
            if storagePaused && henge_vm_state() == HENGE_VM_STOPPED { // shut down meanwhile
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

    /// Shuts the Mac down as a Mac does: its power button is pressed, macOS closes its apps and turns off (or asks
    /// first, on its own screen). The view closes once it is off. Not running (paused, or no power button): off at once.
    /// true if macOS was asked, false if it was turned off.
    @discardableResult
    func shutDown() -> Bool {
        guard state == HENGE_VM_RUNNING, henge_vm_power_button() == 0 else {
            forceOff()
            return false
        }
        shutdownAsked = Date()
        HengeLog.log("session", "Shut Down: the Mac's power button is pressed")
        return true
    }

    /// Turns the Mac off at once (the view closes after).
    func forceOff() {
        SafeMode.macLive(false)
        StorageGuard.holding = false
        shutdownAsked = nil
        stuck = nil
        if state == HENGE_VM_RUNNING || state == HENGE_VM_PAUSED || henge_vm_state() == HENGE_VM_PAUSED {
            MacPreview.saveNow(for: mac)
            henge_vm_stop()
        }
        InstantResume.discard(for: mac) /* turned off: nothing to pick up */
    }

    /// The owner chose to wait (or to keep the Mac running after macOS did not shut down).
    func dismissStuck() {
        if stuck == .shutdownIgnored { shutdownAsked = nil } // it runs on: no longer waiting for it to turn off
        stuck = nil
        quietUntil = Date().addingTimeInterval(LifecycleWatchdog.stopLimit)
    }
}
