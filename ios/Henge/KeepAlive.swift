import AVFAudio
import Foundation
import UIKit

/// Keeps iOS from suspending Solstice while a Mac is open or macOS is installing, from the moment it stops being active
/// until it is active again: in front nothing needs it, and the silence would only cost battery.
///
/// A suspended app is the first thing iOS closes when it wants memory, and Henge holds a lot of it: leaving for a
/// message used to cost the running Mac, and the screen locking used to end an install. An app that is playing
/// audio is not suspended and is closed after every suspended app, so while there is something to lose Henge plays
/// silence (the audio background mode and the playback session were there already, for the Mac's sound). It mixes
/// with other apps' audio and stops as soon as no Mac is open and nothing installs.
///
/// A running Mac does not run on in the background: it waits, paused (InstantResume.rest), so a phone in a pocket
/// stays cool and the GPU, which is not Henge's there, is left alone. An install cannot be paused and goes on.
@MainActor
enum KeepAlive {
    static let key = "henge.keepAlive"
    /// On unless turned off in Settings.
    nonisolated static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    private static var engine: AVAudioEngine?
    private static var player: AVAudioPlayerNode?
    private static var timer: Timer?
    private static var pressure: DispatchSourceMemoryPressure?
    private static var playing = false
    /// Not active (willResignActive until didBecomeActive): the silence must be playing before iOS suspends the app.
    private static var away = false
    /// Solstice stays awake in the background now (InstantResume waits before saving only then).
    static var awake: Bool { playing }

    /// Something iOS closing Solstice would lose while it is away: a Mac running, starting, stopping or paused, or an install.
    private static var needed: Bool {
        let s = henge_vm_state()
        return enabled && away && (s == HENGE_VM_RUNNING || s == HENGE_VM_STARTING_OR_STOPPING || s == HENGE_VM_PAUSED || Installer.shared.busy)
    }

    /// Once, at launch: follow what Henge is doing, say in the log what iOS tells it about memory, and follow the heat.
    static func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { update(); MemoryRelief.sample(); PowerPolicy.shared.tick() }
        }
        PowerPolicy.shared.start()
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
            MainActor.assumeIsolated {
                // A call or an alarm took the session: the silence stopped with it. Start again when it is over
                // (and try at once too: update() runs every 2 s until it works).
                HengeLog.log("keepalive", "audio interruption \(ended ? "ended" : "began")")
                playing = false
                if ended { update() }
                // The Mac's sound stopped with it: its stream runs on by the clock until the session is back.
                henge_vm_audio_interrupted(ended ? 0 : 1)
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
            henge_vm_audio_interrupted(3) // the Mac's sound plays on the new route if it stopped
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                HengeLog.log("keepalive", "audio services were reset")
                teardown()
                update()
                henge_vm_audio_interrupted(2)
            }
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { // headphones in or out: the engine stopped
                playing = false
                update()
            }
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                away = true
                update()
            }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                away = false
                update()
            }
        }
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            HengeLog.log("memory", "iOS sent a memory warning; \(henge_available_memory() >> 20) MB left before Henge's limit")
            HengeLog.logFootprint("memory-warning")
            MainActor.assumeIsolated {
                MemoryRelief.warning()
                InstantResume.saveNowIfWaiting()
            }
        }
        center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            HengeLog.log("app", "iOS is ending Henge (willTerminate)")
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                update()
                HengeLog.log("keepalive", "in the background: \(playing ? "staying awake (silent audio)" : needed ? "could not stay awake" : "nothing to keep, iOS may suspend Henge"); \(henge_available_memory() >> 20) MB left before the limit")
            }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            HengeLog.log("keepalive", "back in the foreground")
        }
        // The system running short, whoever is using it: the lines before a kill say why, and the Mac is asked
        // to hand memory back (MemoryRelief) before iOS takes all of Henge's.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler {
            let data = source.data
            let level = data.contains(.critical) ? 2 : data.contains(.warning) ? 1 : 0
            HengeLog.log("memory", "system memory pressure: \(["normal", "warning", "critical"][level]); \(henge_available_memory() >> 20) MB left before Henge's limit")
            HengeLog.logFootprint("pressure")
            MainActor.assumeIsolated {
                MemoryRelief.pressure(level)
                if level > 0 { InstantResume.saveNowIfWaiting() }
            }
        }
        source.resume()
        pressure = source
        update()
    }

    /// Every second (the one timer), and when what Henge is doing changes.
    private static func update() {
        let want = needed
        if want && !playing { play() }
        if !want && playing { stop() }
    }

    private static func play() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            if engine == nil {
                let e = AVAudioEngine(), p = AVAudioPlayerNode()
                e.attach(p)
                let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
                e.connect(p, to: e.mainMixerNode, format: format)
                engine = e
                player = p
            }
            guard let engine, let player else { return }
            if !engine.isRunning { try engine.start() }
            let format = player.outputFormat(forBus: 0)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100) else { return }
            buffer.frameLength = buffer.frameCapacity // zeroed: a second of silence, over and over
            player.stop()
            player.scheduleBuffer(buffer, at: nil, options: [.loops])
            player.play()
            if !playing { HengeLog.log("keepalive", "on: Solstice stays awake in the background while this goes on") }
            playing = true
        } catch {
            // Another app holds the session exclusively (a call): tried again in 2 s.
            if playing { HengeLog.log("keepalive", "lost: \(error.localizedDescription)") }
            playing = false
        }
    }

    private static func stop() {
        player?.stop()
        engine?.stop()
        playing = false
        HengeLog.log("keepalive", away ? "off: nothing left to keep" : "off: Solstice is active")
    }

    private static func teardown() {
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        playing = false
    }
}

/// When iOS runs short of memory, the Mac is asked to hand some of its own back (its memory balloon: macOS gives
/// up file cache and idle pages first, and Henge returns them to iOS), instead of iOS closing Henge with the Mac
/// in it. What a hypervisor does for a host under pressure. Watched every second against the device's marks
/// (Device.profile.headroomMB), so it starts before iOS warns; iOS's own warnings stay the backstop. Given back
/// slowly once the system has room again.
@MainActor
enum MemoryRelief {
    private static var targetMB = 0
    private static var lastGrow = Date.distantPast // the last time the Mac was asked for more, for whatever reason
    private static var lastEase = Date.distantPast
    private static var level = 0

    /// The system's memory pressure changed (KeepAlive's source): 512 MB more on a warning, 1 GB on critical.
    static func pressure(_ now: Int) {
        level = now
        if now > 0 { grow(now == 2 ? 1024 : 512, "system memory pressure \(now == 2 ? "critical" : "warning")") }
    }

    /// iOS sent Henge a memory warning: as much as for a pressure warning (it says nothing when it is over).
    static func warning() { grow(512, "memory warning") }

    /// Half the Mac's memory at most: macOS itself needs the rest to stay up. Said once for each change.
    private static func grow(_ mb: Int, _ why: String) {
        guard henge_vm_state() == HENGE_VM_RUNNING else { return }
        let held = henge_vm_balloon(-1)
        guard held >= 0 else { return } // no balloon in this Mac
        lastGrow = Date()
        let ram = Int(henge_vm_ram_mb()), most = max(ram / 2, 0)
        let want = min(max(targetMB, Int(held)) + mb, most)
        guard want > targetMB else { return }
        targetMB = want
        _ = henge_vm_balloon(want)
        HengeLog.log("memory", "\(why): asking the Mac for \(want) MB of its \(ram) MB back (it had given \(held) MB)")
    }

    /// Henge goes into the background with a Mac that is to wait there paused (InstantResume.rest): it is asked for
    /// about 1 GB more first, within the same half of its memory. The MB asked for, or nil (no balloon, nothing more
    /// to ask for).
    private static var askedForBackground = false
    static func beforeBackgroundPause() -> Int? {
        guard henge_vm_state() == HENGE_VM_RUNNING else { return nil }
        let held = henge_vm_balloon(-1)
        guard held >= 0 else { return nil }
        let ram = Int(henge_vm_ram_mb()), most = max(ram / 2, 0)
        let want = min(max(targetMB, Int(held)) + 1024, most)
        guard want > Int(held) else { return nil }
        askedForBackground = true
        _ = henge_vm_balloon(want)
        HengeLog.log("memory", "into the background: asking the Mac for \(want) MB of its \(ram) MB before it pauses")
        return want
    }

    /// Back in the foreground: what was asked for only for the background goes back; what pressure asked for stays.
    static func afterBackground() {
        guard askedForBackground else { return }
        askedForBackground = false
        guard henge_vm_state() == HENGE_VM_RUNNING || henge_vm_state() == HENGE_VM_PAUSED else { return }
        _ = henge_vm_balloon(targetMB)
        HengeLog.log("memory", "back in the foreground: the Mac keeps \(targetMB) MB handed over")
    }

    /// Every second while a Mac runs: the system's headroom (henge_system_headroom_mb) against the device's marks.
    /// Under the low mark, 256 MB more once the last step has arrived (macOS frees pages over a few seconds) and at
    /// most every 2 s. With two minutes of no asking, no pressure from iOS and headroom over the high mark (or no
    /// way to tell), 256 MB goes back to the Mac each minute. A timer tick's worth of work: one host_statistics64.
    static func sample() {
        let state = henge_vm_state()
        guard state == HENGE_VM_RUNNING || state == HENGE_VM_PAUSED else { targetMB = 0; return } // that Mac is gone
        guard state == HENGE_VM_RUNNING, !askedForBackground else { return }
        // A Mac brought back by Instant Resume keeps what its balloon held when saved: take that over, or it would
        // never get it back (easing only gives back what was asked for in this launch).
        if targetMB == 0 {
            let held = Int(henge_vm_balloon(-1))
            if held > 0 { targetMB = held }
        }
        let room = henge_system_headroom_mb(), marks = Device.profile.headroomMB, now = Date()
        if room >= 0 && room < marks.lowerBound {
            guard now.timeIntervalSince(lastGrow) >= 2, henge_vm_balloon(-1) + 64 >= targetMB else { return }
            grow(256, "\(room) MB available to iOS, under \(marks.lowerBound) MB")
            return
        }
        guard targetMB > 0, level == 0, room < 0 || room > marks.upperBound,
              now.timeIntervalSince(lastGrow) > 120, now.timeIntervalSince(lastEase) > 60 else { return }
        lastEase = now
        targetMB = max(targetMB - 256, 0)
        _ = henge_vm_balloon(targetMB)
        HengeLog.log("memory", (room < 0 ? "no pressure for a while" : "\(room) MB available to iOS, over \(marks.upperBound) MB")
                     + ": the Mac keeps \(targetMB) MB handed over")
    }
}
