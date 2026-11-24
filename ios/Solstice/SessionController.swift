import SwiftUI

/// A running Mac's lifecycle, for the SessionView that owns it: starting or resuming the Mac, polling the engine
/// while it runs, watching storage, and shutting it down. What the view shows of the Mac comes from here. The slow
/// parts (sizing its memory, booting or resuming, asking for free storage) run off the main thread.
@MainActor
final class SessionController: ObservableObject {
    let mac: VirtualMac

    @Published private(set) var error: String?
    @Published private(set) var state = SOLSTICE_VM_IDLE
    @Published private(set) var cpusOn: Int32 = 0
    @Published private(set) var userCode = false
    @Published private(set) var blocksPerSecond: Double = 0
    @Published private(set) var framesOut: UInt64 = 0
    @Published private(set) var framesIn: UInt64 = 0
    @Published private(set) var log: [String] = []
    @Published private(set) var started = Date()
    @Published private(set) var bootRAM: UInt64 = 0 /* what the Mac was started (or resumed) with */
    @Published private(set) var bootCPUs = 0
    @Published private(set) var helperRunning = false
    /// Paused because storage ran short (StorageGuard), and whether there is room to run on again.
    @Published private(set) var storagePaused = false
    @Published private(set) var storageRoom = false
    @Published private(set) var storageFree: Int64 = 0
    /// Something that should have ended long ago has not (LifecycleWatchdog): the view offers a way out.
    @Published private(set) var stuck: LifecycleWatchdog.Stuck?
    /// Shut Down pressed the Mac's power button: macOS is shutting down (or asking first).
    @Published private(set) var shutdownAsked: Date?
    /// Being started off the main thread (sizing its memory, booting or resuming): there is no power to press yet.
    @Published private(set) var starting = false

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
        state = SOLSTICE_VM_IDLE
        userCode = false
        cpusOn = 0
        blocksPerSecond = 0
        framesOut = 0
        framesIn = 0
        // The last Mac may still be finishing its shutdown; one that never does gets a way out instead of a spinner.
        let waitSince = Date()
        while solstice_vm_state() == SOLSTICE_VM_STARTING_OR_STOPPING && !Task.isCancelled {
            let now = Date()
            if stuck == nil && now >= quietUntil && now.timeIntervalSince(waitSince) > LifecycleWatchdog.stopLimit {
                SolsticeLog.log("session", "watchdog: the last Mac has not finished shutting down in \(Int(LifecycleWatchdog.stopLimit)) s")
                stuck = .stopping
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        stuck = nil
        guard !Task.isCancelled else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        HardwareMouse.shared.start()
        let mac = self.mac
        starting = true
        // A saved Mac goes back into the RAM and CPUs it was saved with (its file's header says which); a fresh start
        // takes the settings within what fits now. Both read storage and the file: off the main thread.
        let (plan, resumeAt) = await offMain("size memory") { () -> (StartShape.Plan, Date?) in
            GuestMemory.useFile(for: mac)
            let saved = InstantResume.enabled ? InstantResume.saved(for: mac) : nil
            let plan = StartShape.plan(saved: saved?.shape, askedRAM: UInt64(mac.ramMB), askedCPUs: cpus,
                                       fits: { GuestMemory.fits(mac, cpus: $0) })
            return (plan, saved?.at)
        }
        SolsticeLog.log("session", "available memory \(solstice_available_memory() >> 20) MB, start: \(plan)")
        let shape: StartShape.Shape
        switch plan {
        case .resume(let s), .boot(let s):
            shape = s
        case .saveDoesNotFit(let saved, let fits):
            // Kept: only the owner gives up a saved Mac (Restart Now in its settings).
            starting = false
            if !Task.isCancelled { error = Self.saveDoesNotFit(saved: saved, fitsMB: fits) }
            return
        case .noRoom:
            starting = false
            if !Task.isCancelled { error = "There is not room for this Mac's memory: it needs a few GB of free storage." }
            return
        }
        guard !Task.isCancelled else {
            starting = false
            return
        }
        JITBootstrap.releaseLingeringDebugger()
        Sharing.prepare()
        EngineTuning.apply()
        let screen = mac.macScreen
        solstice_vm_set_display(UInt32(screen.pixels.width), UInt32(screen.pixels.height))
        solstice_vm_set_display_mm(UInt32(screen.mm?.width ?? 0), UInt32(screen.mm?.height ?? 0))
        SolsticeLog.log("session", "screen \(mac.preset.rawValue) \(screen.pixels.width)x\(screen.pixels.height) mm \(screen.mm.map { "\($0.width)x\($0.height)" } ?? "none") shown at \(String(format: "%.3f", screen.factor))x")
        solstice_vm_set_keyboard_iso(KeyLayout.current.isISO ? 1 : 0) // the Mac reads its keyboard's kind as it starts
        if mac.reportHostIdentity == true {
            let modelID = Device.snappedModelIdentifier(forOS: mac.osName)
            solstice_vm_set_identity(Device.chipName, Device.marketingName,
                                  mac.reportHostModelID == true ? modelID : nil)
            SolsticeLog.log("session", "About This Mac reports \(Device.marketingName) (model \(modelID))")
        } else {
            solstice_vm_set_identity(nil, nil, nil)
        }
        let file = InstantResume.file(for: mac).path, ident = InstantResume.ident(for: mac)
        // A resume decompresses gigabytes and a boot opens the disk: never on the main thread.
        let (rc, reason, booted) = await offMain("start") { () -> (Int32, String, StartShape.Shape) in
            var buffer = [CChar](repeating: 0, count: 256)
            var rc: Int32 = -1
            var shape = shape
            if case .resume = plan, let at = resumeAt {
                SolsticeLog.log("resume", "picking up the Mac saved \(Int(Date().timeIntervalSince(at))) s ago, \(shape.ramMB) MB and \(shape.cpus) CPUs")
                let t0 = Date()
                let resumed = solstice_vm_resume(mac.rom.path, mac.disk.path, mac.aux.path, mac.ecid, mac.seed, shape.ramMB, Int32(shape.cpus),
                                              file, ident, &buffer, buffer.count)
                if resumed == SOLSTICE_VM_RESUMED {
                    SolsticeLog.log("resume", String(format: "resumed in %.1f s", Date().timeIntervalSince(t0)))
                    rc = 0
                } else if resumed == SOLSTICE_VM_RESUME_REFUSED {
                    SolsticeLog.log("resume", "could not resume (\(String(cString: buffer))); starting it from cold")
                    buffer = [CChar](repeating: 0, count: 256)
                } else {
                    // Of the moment (memory, no JIT): the save is the only copy of the Mac's memory, so it stays for the next try.
                    SolsticeLog.log("resume", "could not resume (\(String(cString: buffer))); the save is kept")
                    return (-1, String(cString: buffer), shape)
                }
                // Refused: from cold, with the settings within what fits.
                guard case .boot(let fresh) = StartShape.plan(saved: nil, askedRAM: UInt64(mac.ramMB), askedCPUs: cpus,
                                                              fits: { GuestMemory.fits(mac, cpus: $0) }) else {
                    return (-1, "There is not room for this Mac's memory: it needs a few GB of free storage.", shape)
                }
                shape = fresh
            }
            if rc != 0 {
                // From cold the disk moves on: a save left over (another build, or turned off) is out of date.
                InstantResume.discard(for: mac)
                rc = solstice_vm_boot(mac.rom.path, mac.disk.path, mac.aux.path, mac.ecid, mac.seed, shape.ramMB, Int32(shape.cpus),
                                   &buffer, buffer.count)
            }
            return (rc, String(cString: buffer), shape)
        }
        starting = false
        if Task.isCancelled { // the view went away while the Mac started: none runs on with nothing showing it
            if rc == 0 {
                SolsticeLog.log("session", "closed while starting: the Mac is turned off")
                await offMain("stop") { solstice_vm_stop() }
            }
            return
        }
        if rc != 0 {
            error = reason
            return
        }
        bootRAM = booted.ramMB
        bootCPUs = booted.cpus
        started = Date()
        StorageGuard.holding = false
        storagePaused = false
        if !hooks.inBackground() { SafeMode.macLive(true) } // a crash or hang from here on counts (SafeMode)
        var used = mac
        used.lastUsed = started
        Machines.shared.update(used)
        _ = solstice_vm_blocks_per_second() // marks the start: each perf line then has the rate over its 10 s
        var rate: Double = 0
        var lastGPUFrames = solstice_vm_gpu_frames()
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
            let now_state = solstice_vm_state()
            if now_state != state { state = now_state }
            watch()
            if state == SOLSTICE_VM_STARTING_OR_STOPPING || state == SOLSTICE_VM_PAUSED { /* starting, stopping, or paused (Solstice in the background, heat, or storage) */
                // Paused nothing changes until someone runs it on, which is not this loop: once a second is plenty.
                try? await Task.sleep(nanoseconds: state == SOLSTICE_VM_PAUSED ? 1_000_000_000 : 100_000_000)
                continue
            }
            if !userCode && solstice_vm_guest_el0() != 0 { userCode = true }
            // What only Details shows is copied into the view's state only while it shows: each copy redraws the
            // session, once a second, for nothing otherwise (200 log lines among it).
            if hooks.detailsShown() {
                blocksPerSecond = rate
                refreshDetails()
            }
            if Sharing.helperRunning != helperRunning { helperRunning = Sharing.helperRunning }
            if state == SOLSTICE_VM_STOPPED {
                SafeMode.macLive(false)
                hooks.stopped()
                StickyKeys.shared.releaseAll()
                HardwareKeys.releaseAll()
                HardwareMouse.shared.stop()
                UIApplication.shared.isIdleTimerDisabled = false
                SolsticeLog.log("session", "showing stopped Mac: \(String(cString: solstice_vm_exit_reason()))")
                let outcome = solstice_vm_exit_outcome()
                if outcome == Int32(SOLSTICE_VM_OUTCOME_RESTART.rawValue) && solstice_vm_can_start() != 0 {
                    hooks.restart()
                } else if shutdownAsked != nil && outcome == Int32(SOLSTICE_VM_OUTCOME_SHUTDOWN.rawValue) {
                    InstantResume.discard(for: mac) /* shut down: nothing to pick up */
                    hooks.shutDown()
                }
                shutdownAsked = nil
                stuck = nil
                break
            }
            _ = solstice_vm_drop_spent_save() // the saved Mac goes once this one writes its disk
            tick += 1
            if tick % 10 == 0 {
                rate = solstice_vm_blocks_per_second()
                let gpuFrames = solstice_vm_gpu_frames()
                SolsticeLog.log("perf", "blocks/s \(String(format: "%.0f", rate)), GPU frames/10s \(gpuFrames &- lastGPUFrames), "
                             + "network tx \(solstice_vm_net_frames(1)), rx \(solstice_vm_net_frames(0)), dns \(solstice_vm_dns(0)) answered \(solstice_vm_dns(2)) unanswered, "
                             + "thermal \(PowerPolicy.label(PowerPolicy.shared.thermal))")
                lastGPUFrames = gpuFrames
                JITBootstrap.releaseLingeringDebugger()
            }
            if tick == 60 { hooks.minuteUp() }
            if tick % 30 == 0 { SolsticeLog.logFootprint("session") } // how close to the limit, for a memory kill leaves no crash report
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
        if state == SOLSTICE_VM_STARTING_OR_STOPPING { stoppingSince = stoppingSince ?? now } else { stoppingSince = nil }
        guard now >= quietUntil else { return }
        let found = LifecycleWatchdog.check(
            stoppingFor: stoppingSince.map { now.timeIntervalSince($0) },
            queue: InstantResume.busyFor(now),
            shutdownFor: state == SOLSTICE_VM_RUNNING ? shutdownAsked.map { now.timeIntervalSince($0) } : nil)
        guard found != stuck else { return }
        if let found { SolsticeLog.log("session", "watchdog: \(found.logLine)") }
        stuck = found
    }

    /// What Details shows of the running Mac, now.
    func refreshDetails() {
        cpusOn = solstice_vm_cpus_on()
        framesOut = solstice_vm_net_frames(1)
        framesIn = solstice_vm_net_frames(0)
        log = Array(SolsticeLog.recentLines(200))
    }

    /// Every 10 s (2 s while paused for it): free storage against StorageGuard's floor. Asked off the main thread.
    func watchStorage() async {
        while !Task.isCancelled {
            let reading: Int64? = await withCheckedContinuation { (done: CheckedContinuation<Int64?, Never>) in
                DispatchQueue.global(qos: .utility).async { done.resume(returning: StorageGuard.freeBytes()) }
            }
            if let free = reading {
                if storagePaused || free < StorageGuard.minimumFree { storageFree = free } // only shown then
                if !storagePaused && !StorageGuard.holding && free < StorageGuard.minimumFree && solstice_vm_state() == SOLSTICE_VM_RUNNING {
                    storagePaused = true
                    storageRoom = false
                    StorageGuard.holding = true
                    SolsticeLog.log("storage", "\(free >> 20) MB free, under \(StorageGuard.minimumFree >> 20) MB: pausing the Mac")
                    InstantResume.holdForStorage { [weak self] paused in
                        guard !paused else { return }
                        // It was not running after all (stopping, or paused by Solstice): nothing to hold.
                        StorageGuard.holding = false
                        self?.storagePaused = false
                    }
                }
                if storagePaused { storageRoom = free >= StorageGuard.resumeAt }
            }
            if storagePaused && solstice_vm_state() == SOLSTICE_VM_STOPPED { // shut down meanwhile
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
    /// Turned off at once, `off` runs when it is.
    func shutDown(off: @escaping @MainActor () -> Void) {
        guard state == SOLSTICE_VM_RUNNING, solstice_vm_power_button() == 0 else {
            forceOff(then: off)
            return
        }
        shutdownAsked = Date()
        SolsticeLog.log("session", "Shut Down: the Mac's power button is pressed")
    }

    /// Turns the Mac off at once, then runs `done` (the view closes). The stop takes its turn on InstantResume's
    /// queue: a save running there holds the engine for seconds, and the main thread must not wait for it.
    func forceOff(then done: @escaping @MainActor () -> Void) {
        SafeMode.macLive(false)
        StorageGuard.holding = false
        shutdownAsked = nil
        stuck = nil
        let mac = self.mac, up = state == SOLSTICE_VM_RUNNING || state == SOLSTICE_VM_PAUSED
        InstantResume.run("force off") {
            if up || solstice_vm_state() == SOLSTICE_VM_PAUSED {
                MacPreview.saveNow(for: mac)
                solstice_vm_stop()
            }
            InstantResume.discard(for: mac) /* turned off: nothing to pick up */
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }

    /// The owner chose to wait (or to keep the Mac running after macOS did not shut down).
    func dismissStuck() {
        if stuck == .shutdownIgnored { shutdownAsked = nil } // it runs on: no longer waiting for it to turn off
        stuck = nil
        quietUntil = Date().addingTimeInterval(LifecycleWatchdog.stopLimit)
    }

    /// The saved Mac needs more memory than fits right now: it is kept, and what the owner can do.
    static func saveDoesNotFit(saved: StartShape.Shape, fitsMB: UInt64) -> String {
        "This Mac was saved with \(ByteText.string(saved.ramMB << 20)) of memory, and only \(ByteText.string(fitsMB << 20)) fits "
            + "on this \(Device.name) right now: storage or memory is short. The saved Mac is kept. Free some storage or close "
            + "other apps, then open it again. To start it afresh instead (what was open on it is lost), lower its Memory "
            + "in its settings and tap Restart Now."
    }
}

#if SOLSTICE_SCREENS
extension SessionController {
    /// The simulator app for screenshots (ios/Screens): macOS was asked to shut down this long ago (the watchdog's card).
    func screens(shutdownAskedAgo: TimeInterval) { shutdownAsked = Date().addingTimeInterval(-shutdownAskedAgo) }
    /// The same: paused for want of storage, with this much free.
    func screens(storageFree free: Int64) {
        storagePaused = true
        storageRoom = false
        storageFree = free
    }
}
#endif
