import Foundation
import UIKit

/// Instant resume: when Solstice has been away a while, the paused Mac is written to storage, so opening it again picks
/// up there in a few seconds, even if iOS closed Solstice in between. Coming straight back just lets it run on. The
/// engine keeps a saved Mac only for its disk exactly as it was (host/snapshot.c) and deletes the file once the Mac
/// writes its disk (henge_vm_drop_spent_save); this side decides when to save, and says which build and settings a
/// file belongs to.
enum InstantResume {
    /// On unless turned off in Settings.
    static var enabled: Bool { UserDefaults.standard.object(forKey: SettingKey.instantResume.rawValue) as? Bool ?? SettingDefault.instantResume }
    /// How long Solstice is away (and kept awake, KeepAlive) before the Mac is written out: a save is 1-2 GB of flash,
    /// so a quick look at a message costs none.
    static let saveAfter: TimeInterval = 20

    /// Saving and running on take turns on one queue, never on the main thread: a save takes a few seconds. Pausing
    /// for heat (PowerPolicy) and starting a Mac (SessionController) take their turn here too.
    static let queue = DispatchQueue(label: "henge.instant-resume", qos: .userInitiated)

    /// What runs on the queue, and since when: a pause that never returns blocks all behind it (LifecycleWatchdog).
    private static let busyLock = NSLock()
    nonisolated(unsafe) private static var busy: (what: String, since: Date)?
    static func busyFor(_ now: Date = Date()) -> (what: String, seconds: TimeInterval)? {
        busyLock.lock()
        defer { busyLock.unlock() }
        return busy.map { ($0.what, now.timeIntervalSince($0.since)) }
    }

    /// Work on the queue, marked for the watchdog.
    static func run(_ what: String, _ work: @escaping () -> Void) {
        queue.async {
            busyLock.lock(); busy = (what, Date()); busyLock.unlock()
            work()
            busyLock.lock(); busy = nil; busyLock.unlock()
        }
    }

    /// Running, or being started (on the queue: what is queued after the start sees it running).
    private static var upOrComingUp: Bool {
        let s = henge_vm_state()
        return s == HENGE_VM_RUNNING || s == HENGE_VM_STARTING_OR_STOPPING
    }

    static func file(for mac: VirtualMac) -> URL { mac.directory.appendingPathComponent("resume.hsnap") }

    /// What a saved Mac is for: this build of Solstice (a restored machine must meet the code that saved it), the Mac,
    /// and what it was started with. The engine adds the disk's own identity.
    static func ident(for mac: VirtualMac, ramMB: UInt64, cpus: Int) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = info["HengeBuildCommit"] as? String ?? "unstamped"
        let stamp = info["HengeBuildDate"] as? String ?? "?"
        return "Henge \(version) (\(build)) \(commit) \(stamp) mac \(mac.id.uuidString) ram \(ramMB) cpus \(cpus) "
            + "screen \(mac.screen.width)x\(mac.screen.height) retina \(mac.isRetina)"
    }

    /// A whole saved Mac for these settings, and when it was saved.
    static func saved(for mac: VirtualMac, ramMB: UInt64, cpus: Int) -> Date? {
        var at: Int64 = 0
        guard henge_vm_saved_ok(file(for: mac).path, ident(for: mac, ramMB: ramMB, cpus: cpus), nil, &at) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(at))
    }

    /// Whether a file is there at all (the Home screen's hint; the start checks it properly).
    static func hasSave(for mac: VirtualMac) -> Bool { FileManager.default.fileExists(atPath: file(for: mac).path) }

    /// The file, and a half-written one from a save iOS cut short (the engine writes beside it, then renames).
    static func discard(for mac: VirtualMac) {
        try? FileManager.default.removeItem(at: file(for: mac))
        try? FileManager.default.removeItem(at: mac.directory.appendingPathComponent("resume.hsnap.part"))
    }

    /// Solstice stopped being active (the app switcher, a call, Control Center, going home): stop the Mac where it is
    /// while the GPU is still Solstice's, so what only the GPU holds goes back into the Mac's memory. At once, so
    /// without rest()'s balloon first (the guest needs seconds for it, and Solstice may be in the background, its GPU
    /// gone, by then); suspend() saves it later, and a saved Mac loses nothing if iOS closes Solstice.
    static func pause() {
        guard enabled, upOrComingUp else { return }
        run("pause") {
            guard henge_vm_state() == HENGE_VM_RUNNING else { return } // a start ahead on the queue has finished by now
            var buffer = [CChar](repeating: 0, count: 256)
            if henge_vm_pause(&buffer, buffer.count) != 0 { HengeLog.log("resume", "not paused: \(String(cString: buffer))") }
        }
    }

    /// Per Mac: its balloon was asked and handed over nothing (no balloon driver in that macOS), so rest() does not
    /// wait the 3 s for it again; asked once more whenever the balloon shows it moved.
    private static func balloonIdleKey(_ mac: VirtualMac) -> String { SettingKey.balloonIdle.forMac(mac.id) }

    /// Solstice is in the background and stays awake there (KeepAlive): the Mac waits, paused, until Solstice is back,
    /// using no CPU and no GPU (which is not Solstice's in the background). With instant resume on, pause() and
    /// suspend() do this and save it too. First the Mac is asked for about 1 GB of its memory (MemoryRelief), for up to
    /// 3 s: its idle pages and file cache then do not sit in Solstice's memory while iOS weighs what to close.
    @MainActor static func rest(_ mac: VirtualMac) {
        guard !enabled, KeepAlive.enabled, upOrComingUp else { return }
        let idleKey = balloonIdleKey(mac)
        let neverMoved = UserDefaults.standard.bool(forKey: idleKey) && henge_vm_balloon(-1) <= 0
        let asked = neverMoved || henge_vm_state() != HENGE_VM_RUNNING ? nil : MemoryRelief.beforeBackgroundPause()
        if neverMoved { HengeLog.log("memory", "before the background pause: this Mac's balloon never moved, not waiting for it") }
        run("rest") {
            if let asked {
                let t0 = Date()
                var got = henge_vm_balloon(-1)
                while got >= 0, got + 64 < asked, Date().timeIntervalSince(t0) < 3, henge_vm_state() == HENGE_VM_RUNNING {
                    usleep(100_000)
                    got = henge_vm_balloon(-1)
                }
                HengeLog.log("memory", "before the background pause the Mac handed over \(max(got, 0)) of \(asked) MB in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
                UserDefaults.standard.set(got == 0, forKey: idleKey)
            }
            guard henge_vm_state() == HENGE_VM_RUNNING else { return }
            var buffer = [CChar](repeating: 0, count: 256)
            let rc = henge_vm_pause(&buffer, buffer.count)
            HengeLog.log("keepalive", rc == 0 ? "the Mac waits, paused, while Solstice is in the background" : "the Mac was not paused: \(String(cString: buffer))")
            if rc == 0 { trim() }
        }
    }

    /// Paused in the background: the translated code is dropped and the engine's tables go back to iOS (hv_vm_trim),
    /// so the waiting Mac costs only its own memory; it translates again once it runs on. On the queue.
    private static func trim() {
        let before = henge_available_memory(), t0 = Date()
        let rc = henge_vm_trim()
        let freed = Int64(henge_available_memory()) - Int64(before)
        HengeLog.log("memory", rc == 0 ? "paused: the engine gave back \(max(freed, 0) >> 20) MB in \(Int(Date().timeIntervalSince(t0) * 1000)) ms" : "paused, but the engine's tables were not given back")
    }

    /// The save waiting for Solstice to stay away (main thread).
    @MainActor private static var pending: DispatchWorkItem?

    /// Solstice is in the background: write the paused Mac out after saveAfter, in case iOS closes Solstice. At once
    /// when nothing keeps Solstice awake (iOS suspends it within seconds). It stays paused.
    @MainActor static func suspend(_ mac: VirtualMac, ramMB: UInt64, cpus: Int) {
        guard enabled, upOrComingUp || henge_vm_state() == HENGE_VM_PAUSED else { return }
        pending?.cancel()
        let delay = KeepAlive.awake ? saveAfter : 0
        let item = DispatchWorkItem { MainActor.assumeIsolated { save(mac, ramMB: ramMB, cpus: cpus) } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        if delay > 0 { HengeLog.log("resume", "the Mac is saved if Solstice stays away \(Int(delay)) s") }
    }

    /// iOS is short of memory while a save waits: it is written now, before iOS closes Solstice.
    @MainActor static func saveNowIfWaiting() {
        guard let item = pending, !item.isCancelled else { return }
        HengeLog.log("resume", "memory is short: saving the Mac now")
        item.perform()
        item.cancel()
    }

    @MainActor private static func save(_ mac: VirtualMac, ramMB: UInt64, cpus: Int) {
        pending = nil
        // Paused for want of storage: a save of its memory is what would fill the device.
        guard !StorageGuard.holding else {
            HengeLog.log("resume", "not saved: storage is almost full")
            return
        }
        let path = file(for: mac).path, id = ident(for: mac, ramMB: ramMB, cpus: cpus)
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "Solstice save") {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        run("save") {
            defer {
                DispatchQueue.main.async {
                    if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
                    task = .invalid
                }
            }
            let state = henge_vm_state()
            guard state == HENGE_VM_RUNNING || state == HENGE_VM_PAUSED else { return }
            // It has not run since its last save, which is still there: writing it again would only cost flash.
            if henge_vm_saved_unchanged() != 0 {
                HengeLog.log("resume", "not saved again: the Mac has not run since its last save")
                return
            }
            let t0 = Date()
            var buffer = [CChar](repeating: 0, count: 256)
            /* Paused already, unless Solstice went straight to the background. */
            var rc = state == HENGE_VM_PAUSED ? 0 : henge_vm_pause(&buffer, buffer.count)
            if rc == 0 { trim() } // before the save: its buffers then meet the memory the engine had
            if rc == 0 { rc = henge_vm_save(path, id, &buffer, buffer.count) }
            let took = String(format: "%.1f", Date().timeIntervalSince(t0))
            if rc == 0 {
                let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
                HengeLog.log("resume", "saved the Mac in \(took) s (\(ByteText.string(UInt64(max(bytes, 0)))))")
            } else {
                HengeLog.log("resume", "not saved after \(took) s: \(String(cString: buffer))")
            }
        }
    }

    /// Back in the foreground before iOS closed Solstice (or active again after a moment inactive): a save still
    /// waiting is not needed. The saved file, if any, stays until the Mac writes its disk (the engine deletes it then).
    /// The memory asked for only for the background goes back. A Mac paused for want of storage stays paused
    /// (StorageGuard): it runs on when the user says so. One paused for heat, or that would be (PowerPolicy), runs on
    /// by itself once the device has cooled.
    @MainActor static func cameBack(_ mac: VirtualMac) {
        pending?.cancel()
        pending = nil
        MemoryRelief.afterBackground()
        guard !StorageGuard.holding else { return }
        let hot = PowerPolicy.shared.keepsPaused()
        run("run on") {
            guard henge_vm_state() == HENGE_VM_PAUSED, PowerPolicy.inFront else { return } // away again before this ran: stays paused
            if hot {
                HengeLog.log("resume", "back: the Mac stays paused until the device cools")
                return
            }
            HengeLog.log("resume", henge_vm_continue() == 0 ? "back: the Mac runs on" : "back: the Mac could not run on")
        }
    }

    /// Storage ran short (StorageGuard): the Mac stops where it is, as when Solstice leaves the foreground. done(true)
    /// on the main thread if it is paused.
    static func holdForStorage(_ done: @escaping @MainActor (Bool) -> Void) {
        run("pause for storage") {
            var buffer = [CChar](repeating: 0, count: 256)
            let rc = henge_vm_state() == HENGE_VM_RUNNING ? henge_vm_pause(&buffer, buffer.count) : -1
            HengeLog.log("storage", rc == 0 ? "storage almost full: the Mac is paused" : "storage almost full, but the Mac was not paused: \(String(cString: buffer))")
            DispatchQueue.main.async { MainActor.assumeIsolated { done(rc == 0) } }
        }
    }

    /// The user resumes it, with room again.
    static func releaseStorageHold() {
        run("run on after storage") {
            guard henge_vm_state() == HENGE_VM_PAUSED else { return }
            HengeLog.log("storage", henge_vm_continue() == 0 ? "room again: the Mac runs on" : "room again, but the Mac could not run on")
        }
    }
}

/// A running Mac's disk image is sparse and grows as macOS writes; with no storage left iOS closes apps and writes
/// fail. Below 6 GB free the Mac is paused with a notice (SessionView), and runs on when the user asks once there is
/// room again (a little more than the floor, so it does not stop again at once). holding is used on the main thread;
/// freeBytes asks the file system, which can take a while: call it off the main thread.
enum StorageGuard {
    static let minimumFree: Int64 = 6 << 30
    static let resumeAt: Int64 = minimumFree + (512 << 20)
    /// The Mac is paused for this: instant resume does not save it, coming back does not run it on.
    static var holding = false

    /// Free storage as iOS counts it for important use (what it can free for the asking included), or nil if it
    /// cannot say: then nothing is done.
    static func freeBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
