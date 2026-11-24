import Foundation
import SwiftUI
import UIKit

/// Heat and Low Power Mode, with nothing to set (solstice_vm_set_power_profile): in Low Power Mode an idle CPU sleeps at
/// once (no WFI spin) but every frame still goes to the screen, as iOS itself keeps 60 Hz there; hot (thermal state
/// serious) the screen also goes to HV_SAVING_HZ, so the Mac runs on steadily instead of iOS throttling it in bursts;
/// critical, the Mac pauses with a notice and runs on by itself once the device has cooled to serious. iOS's thermal states change slowly and with their own hysteresis, so they are followed as they come.
/// Each change is logged. Used on the main thread.
@MainActor
final class PowerPolicy: ObservableObject {
    static let shared = PowerPolicy()

    @Published private(set) var thermal = ProcessInfo.processInfo.thermalState
    /// The Mac is paused for heat (SessionView shows HeatNotice).
    @Published private(set) var holding = false
    private var level = 0 // 0 normal, 1 Low Power Mode, 2 hot, 3 too hot to run
    private var started = false, logged = false // the state at launch is logged too
    /// Solstice is in front (active). Read on InstantResume.queue: a Mac paused for heat, or paused while away, runs on
    /// only in front (in the background the GPU is not Solstice's and the Mac would heat the device up again).
    nonisolated(unsafe) static var inFront = true

    /// What the levels do, for the log.
    private static let meaning = ["normal", "saving power (no WFI spin)",
                                  "hot: saving power (no WFI spin, the screen at HV_SAVING_HZ)",
                                  "too hot: the Mac pauses until the device cools"]

    static func label(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot, performance reduced"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    /// Once, at launch (KeepAlive.start).
    func start() {
        guard !started else { return }
        started = true
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PowerPolicy.shared.update() }
            }
        }
        Self.inFront = UIApplication.shared.applicationState == .active
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            PowerPolicy.inFront = true
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            PowerPolicy.inFront = false
        }
        update()
    }

    private func update() {
        let info = ProcessInfo.processInfo
        let heat = info.thermalState, lowPower = info.isLowPowerModeEnabled
        let now = heat == .critical ? 3 : heat == .serious ? 2 : lowPower ? 1 : 0
        guard heat != thermal || now != level || !logged else { return }
        logged = true
        thermal = heat
        SolsticeLog.log("power", "thermal state \(Self.label(heat))\(lowPower ? ", Low Power Mode" : ""): \(Self.meaning[now])")
        guard now != level else { return }
        level = now
        solstice_vm_set_power_profile(Int32(now))
        tick()
    }

    /// Every second (KeepAlive's timer) and at each change: too hot, a running Mac in front pauses (an install
    /// cannot); cooler again, the Mac it paused runs on, unless storage holds it too (StorageGuard).
    func tick() {
        let state = solstice_vm_state()
        if holding && state != SOLSTICE_VM_RUNNING && state != SOLSTICE_VM_PAUSED { holding = false } // stopped meanwhile
        if holding && level < 3 {
            // Cooler while away: it stays paused (and its save stays good) until Solstice is in front again.
            guard UIApplication.shared.applicationState == .active else { return }
            holding = false
            guard !StorageGuard.holding else { return }
            InstantResume.queue.async {
                guard solstice_vm_state() == SOLSTICE_VM_PAUSED, PowerPolicy.inFront else { return }
                SolsticeLog.log("power", solstice_vm_continue() == 0 ? "cooler: the Mac runs on" : "cooler, but the Mac could not run on")
            }
            return
        }
        guard level == 3, state == SOLSTICE_VM_RUNNING, UIApplication.shared.applicationState == .active, !Installer.shared.busy else { return }
        holding = true // also when something ran it on meanwhile: it pauses again
        InstantResume.queue.async {
            guard solstice_vm_state() == SOLSTICE_VM_RUNNING else { return }
            var buffer = [CChar](repeating: 0, count: 256)
            let rc = solstice_vm_pause(&buffer, buffer.count)
            SolsticeLog.log("power", rc == 0 ? "too hot: the Mac is paused" : "too hot, but the Mac was not paused: \(String(cString: buffer))")
        }
    }

    /// Back to a paused Mac (InstantResume.cameBack): whether it stays paused for heat (it runs on by itself later).
    func keepsPaused() -> Bool {
        if level == 3 { holding = true }
        return holding
    }
}

/// The session's notice while the Mac is paused for heat: no button, it goes away by itself.
struct HeatNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This \(Device.name) is too hot").font(.system(size: 17, weight: .semibold))
            Text("The Mac is paused so the \(Device.name) can cool down. It runs on by itself once it has.")
                .font(.system(size: 14)).foregroundStyle(Desk.dim)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Desk.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
