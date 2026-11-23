// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import UIKit

/// `csops(2)`. Reading CS_DEBUGGED is how we ask "is a debugger attached right
/// now" without executing anything — unlike the brk probe, which costs a trap.
@_silgen_name("csops")
private func csops(_ pid: Int32, _ ops: Int32,
                   _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

private let CS_OPS_STATUS = Int32(0)
private let CS_DEBUGGED = UInt32(0x10000000)

/// Gets Henge from "launched normally, no executable memory" to "JIT is live".
///
/// On iOS 26 and later every supported device enforces TXM, so the app cannot grant itself
/// executable memory — only an attached debugger can: Henge's own built-in StikJIT helper
/// (JITSetup.swift), which runs the JIT script from an app extension.
enum JITBootstrap {
    /// Install the trap guard. Must run before anything can execute a `brk`.
    ///
    /// Without this, a `brk` that no debugger is there to service is a fatal
    /// SIGTRAP rather than a failed call — the process simply dies.
    static func installTrapGuard() {
        HengeLog.log("jit", "installing brk trap guard")
        henge_ios_jit_install_trap_handler()
        HengeLog.log("jit", "trap guard installed -- an unserviced brk will now "
                         + "return 0 instead of killing the process")
    }

    /// The one region HengeVM's translator gets for the whole session (it flushes and starts over when full,
    /// never asks for more). 1 GB takes about 1.5 s to prepare, and a first boot through Setup makes that much code; a full flush drops all of it.
    static let codeCacheKey = "henge.perf.codeCacheMB"
    /// What Settings > Performance > Code cache offers, in MB. Without a choice there, the device's within what the
    /// signing allows (DeviceProfile). A bigger cache fills and empties less often (macOS 27 filled 1 GB about once a
    /// minute) and costs more memory: its blocks' records come to about 0.5-0.7 times its size on top. Fixed for the
    /// launch: the region is claimed once (the hold in henge-ios-jit.c covers the largest choice).
    /// 1.5 GB needs all of: more than 8 GB of memory (an 8 GB iPad's Mac, cache and records left iOS too little and it
    /// closed Henge), the memory limit, and extended-virtual-addressing (a free team cannot sign it); without it, 1 GB.
    static let jitBytes: Int = Device.profile.jitMB(chosen: UserDefaults.standard.object(forKey: codeCacheKey) as? Int) << 20

    /// True once the region is held. The memory budget needs this: after a
    /// prewarm the JIT is already counted in the footprint, so subtracting it
    /// again charges for it twice and cost the guest 256 MiB.
    nonisolated(unsafe) static var prewarmed = false

    /// Take the JIT region now, while the helper is definitely still attached.
    ///
    /// The debugger lets go after a while, and without a debugger there is no
    /// executable memory at all; asking again later is precisely what does
    /// not work. So claim it first and hold it.
    @discardableResult
    static func prewarm() -> Bool {
        if prewarmed { return true }
        guard isDebuggerAttached else {
            HengeLog.log("jit", "no debugger attached yet; not prewarming")
            return false
        }
        HengeLog.log("jit", "claiming \(jitBytes / (1024 * 1024)) MiB of JIT memory now -- the debugger does not stay attached")
        let ok = henge_ios_jit_prewarm(jitBytes)
        if ok {
            prewarmed = true
            lastFailure = nil
            detachIfDone()
            NotificationCenter.default.post(name: readyNotification, object: nil)
        } else {
            lastFailure = "The debugger is attached but is not answering trap "
                        + "requests, so no executable memory could be claimed. "
                        + "Open Henge from the Home Screen and tap Turn On JIT."
        }
        HengeLog.log("jit", ok ? "JIT region secured" : "JIT prewarm FAILED -- the debugger is not servicing traps")
        return ok
    }

    /// KeepAlive's 1 s tick, until the region is held: a debugger that attached since (an external tool a moment
    /// after Solstice became active, which bumps no attachGeneration) is noticed and the region claimed. Cheap (one
    /// csops); a failed claim is not retried here (lastFailure), the setup flow does that.
    static func claimIfAttached() {
        guard !ready, lastFailure == nil, debuggedFlag else { return }
        prewarm()
    }

    /// Whether Henge has JIT now: the region is held. CS_DEBUGGED alone is not enough: the debugger must also answer
    /// the brk that claims the region, or an install stops at "Henge has no JIT region" (#23). Cheap, and logs nothing.
    static var ready: Bool { prewarmed || isLive }

    /// Posted on the main thread once the region is held (prewarm).
    static let readyNotification = Notification.Name("solstice.jitReady")

    /// Waits until JIT is ready (readyNotification), at most timeout seconds; whether it is.
    @MainActor static func waitUntilReady(timeout: TimeInterval) async -> Bool {
        if ready { return true }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var observer: NSObjectProtocol?
            var finished = false
            let finish = {
                guard !finished else { return }
                finished = true
                if let observer { NotificationCenter.default.removeObserver(observer) }
                done.resume()
            }
            observer = NotificationCenter.default.addObserver(forName: readyNotification, object: nil, queue: .main) { _ in finish() }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish() }
        }
        return ready
    }

    /// True once this process has told the debugger to let go.
    nonisolated(unsafe) static private(set) var detached = false

    /// Henge's built-in helper (StikJIT's script, which answers the detach brk) was started this launch.
    nonisolated(unsafe) static var helperMayBeAttached = false
    nonisolated(unsafe) static private var lingeringTries = 0

    /// A debugger still on after the one that gave the region was let go: another helper that attached once the first
    /// detached. With one attached every trap stops Henge until it answers (a phone run went 1.5-2x slower). Told to let
    /// go too, if it is the built-in helper's (StikJIT's script answers the detach brk; a debugger that does not, Xcode's
    /// say, would stop at it). Cheap: one sysctl. Called before a Mac starts and every 10 s while one runs; three tries.
    static func releaseLingeringDebugger() {
        guard detached, helperMayBeAttached, lingeringTries < 3, isTraced else { return }
        lingeringTries += 1
        HengeLog.log("jit", "a debugger is still attached after the JIT region was held (a second helper?); detaching it")
        henge_ios_jit_detach()
        HengeLog.log("jit", isTraced ? "still traced after the detach request" : "debugger detached")
    }

    /// Whether a debugger traces this process right now (P_TRACED; CS_DEBUGGED stays set after a detach).
    static var isTraced: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// Release the debugger once the JIT region is held. While a debugger is attached, every stop event (a `brk`, a
    /// signal, a Mach exception) halts the whole process until it answers, and iOS suspends it soon after it hands the
    /// foreground back. The RX pages stay valid after detach, so detaching once the region is held removes it.
    private static func detachIfDone() {
        guard prewarmed, !detached else { return }
        HengeLog.log("jit", "JIT region held; detaching the debugger so a suspended "
                         + "debugger cannot stall the process later (traced: \(isTraced ? "yes" : "no"))")
        henge_ios_jit_detach()
        detached = true
        HengeLog.log("jit", "after the detach request, traced: \(isTraced ? "yes" : "no")")
    }

    /// Why the last prewarm failed, for the UI to show.
    ///
    /// CS_DEBUGGED being set is not the same as the debugger servicing traps:
    /// a debugger without Henge's script reports the process debugged, answers
    /// no brk, and gives no executable memory.
    nonisolated(unsafe) static var lastFailure: String?

    /// True only after a JIT region has been allocated AND passed the execute self-test.
    static var isLive: Bool { henge_ios_jit_is_available() }

    /// The actual precondition for claiming the region: a debugger has attached.
    ///
    /// Checked with csops/CS_DEBUGGED rather than the `brk #0x69` probe, because
    /// this costs nothing and is safe to call repeatedly — the brk probe traps
    /// every time, and every trap is a chance to hit a moment when the debugger is
    /// not listening. The brk probe still runs once, inside the allocator, where
    /// its answer is immediately acted on.
    static var isDebuggerAttached: Bool {
        guard let flags = csStatus() else {
            HengeLog.log("jit", "csops failed (errno \(errno)); assuming no debugger")
            return false
        }
        let attached = (flags & CS_DEBUGGED) != 0
        HengeLog.log("jit", String(format: "csops status = 0x%08x, CS_DEBUGGED = %@",
                                  flags, attached ? "set" : "clear"))
        return attached
    }

    /// `isDebuggerAttached` without the log line, for polling while the
    /// built-in helper attaches.
    static var debuggedFlag: Bool {
        (csStatus() ?? 0) & CS_DEBUGGED != 0
    }

    private static func csStatus() -> UInt32? {
        var flags: UInt32 = 0
        let rc = withUnsafeMutableBytes(of: &flags) { buf in
            csops(getpid(), CS_OPS_STATUS, buf.baseAddress, buf.count)
        }
        return rc == 0 ? flags : nil
    }

    /// henge-jit.js as standard base64, which Built-in StikJIT's custom script takes.
    static var scriptBase64: String? {
        loadScript()?.data(using: .utf8)?.base64EncodedString()
    }

    private static func loadScript() -> String? {
        // Accept either bundle layout: the build copies henge-jit.js to the bundle
        // root, but a folder-reference build phase would put it under Resources/.
        let candidates = [
            Bundle.main.path(forResource: "henge-jit", ofType: "js"),
            Bundle.main.path(forResource: "henge-jit", ofType: "js", inDirectory: "Resources"),
        ]
        for case let path? in candidates {
            if let s = try? String(contentsOfFile: path, encoding: .utf8) { return s }
        }
        return nil
    }
}
