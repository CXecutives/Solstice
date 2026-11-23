import SwiftUI
import AVFAudio

@main
struct HengeApp: App {
    /// Answers for external display scenes before iOS 27 (LegacyExternalDisplay.swift).
    @UIApplicationDelegateAdaptor(HengeAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Order matters: HengeLog takes over stderr, so the engine's and the JIT
        // allocator's first lines land in Documents/henge.log too.
        HengeLog.start()
        HengeLog.log("boot", "address space: \(henge_largest_reservation_gb()) GB can be reserved in one piece")
        SafeMode.noteLaunch() // before the engine's settings: two launches in a row that ended with a Mac up start it safe
        EngineTuning.apply()
        // Settings > Log stream: send the log to a computer on this network, if that is on.
        LogStream.shared.applySettings()
        HengeLog.logFootprint("app-launch")
        HengeLog.log("app", "increased memory limit: \(Entitlements.increasedMemory ? "yes" : "no"); extended addressing: \(Entitlements.extendedAddressing ? "yes" : "no"); limit \(Entitlements.memoryLimitAtLaunch >> 20) MB")
        // Without the guard, a brk no debugger answers kills the app instead of failing.
        JITBootstrap.installTrapGuard()
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        Machines.shared.collectImports()
        DispatchQueue.main.async { KeepAlive.start() } // once the app is up: it watches the Mac and the installer
        // The display question: does this iOS have Apple's paravirtualized graphics at all?
        for path in ["/System/Library/Frameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics",
                     "/System/Library/PrivateFrameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics"] {
            HengeLog.log("app", "\(path): \(dlopen(path, RTLD_LAZY) != nil ? "present" : "absent")")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in HengeLog.log("app", "opened with \(url.absoluteString)") } // henge:// back from LocalDevVPN
        }
    }
}

struct RootView: View {
    enum Tab: Hashable { case macs, install, settings }

    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var running: VirtualMac?
    @State private var tab = Tab.macs
    @ObservedObject private var installer = Installer.shared
    /// Once per launch: the JIT walkthrough for a device not set up yet, and starting the last Mac.
    @State private var firstSetupOffered = false
    @State private var autoStarted = false
    /// Said once, when safe mode comes on.
    @State private var safeModeNotice = SafeMode.justCameOn
    @AppStorage(DeskAppearance.key) private var appearance = DeskAppearance.system

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                HomeView(running: $running, tab: $tab)
                    .tabItem { Label("Macs", systemImage: "macwindow") }
                    .tag(Tab.macs)
                InstallView(sessionUp: running != nil)
                    .tabItem { Label("Install", systemImage: "arrow.down.circle") }
                    .tag(Tab.install)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(Tab.settings)
            }
            .tint(Desk.accentLight)
            if let running {
                SessionView(mac: running) { self.running = nil }
                    .environment(\.colorScheme, .dark) // still dark while it fades out over a light page
                    .transition(.opacity)
            }
        }
        .background(WindowStyle(style: running != nil ? .dark : appearance.style))
        .alert("Safe mode", isPresented: $safeModeNotice) {
            Button("OK", role: .cancel) {}
            Button("Use Solstice's Settings") { SafeMode.turnOff() }
        } message: {
            Text("The last two times, Solstice ended while a Mac was running. Until the next update it starts Macs with Henge's standard engine settings. Settings, Performance turns this off.")
        }
        .sheet(isPresented: $jit.showSetup) { JITSetupFlow() }
        // Swiped away in the app switcher while a Mac ran: a quit, not a crash, for SafeMode.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            SafeMode.macLive(false)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            machines.collectImports()
            jit.enableAtLaunchIfAsked()
            // The helper can attach a moment after Henge is active. A task also runs
            // on the first appearance, when there may be no phase change.
            for _ in 0..<100 {
                guard !Task.isCancelled else { return }
                if JITBootstrap.prewarmed || JITBootstrap.isLive {
                    jit.objectWillChange.send()
                    return
                }
                if JITBootstrap.debuggedFlag {
                    JITBootstrap.prewarm()
                    // Readiness lives outside the observable coordinator.
                    jit.objectWillChange.send()
                    return
                }
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return } // going into the background cancels this wait
            }
        }
        .onChange(of: jit.attachGeneration) { _ in JITBootstrap.prewarm() } // the built-in helper attached
        .task {
            // First launch, nothing paired: straight to pairing (the walkthrough opens on it on iOS 27), and to the
            // Install tab while there is no Mac yet.
            if machines.all.isEmpty { tab = .install }
            guard !firstSetupOffered else { return }
            firstSetupOffered = true
            jit.refreshPairingStatus()
            if !jit.hasPairing && !JITBootstrap.ready { jit.showSetup = true }
        }
        .task(id: jit.attachGeneration) { await autoStartLastMac() }
        .onChange(of: installer.justInstalled) { mac in
            guard let mac else { return }
            installer.justInstalled = nil
            Task { await startWhenFree(mac) }
        }
    }
}

extension RootView {
    /// Starts the Mac an install just made, once the installer's machine is released (#183).
    func startWhenFree(_ mac: VirtualMac) async {
        for _ in 0..<60 where henge_vm_can_start() == 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
        guard henge_vm_can_start() != 0, running == nil else { return }
        tab = .macs
        running = mac
    }

    /// Settings › Start the last Mac when JIT is on: once per launch, when nothing else is going on. A Mac that
    /// failed to come up twice in a row turns this off until one starts by hand.
    func autoStartLastMac() async {
        guard !autoStarted, AutoStart.enabled, running == nil, !installer.busy else { return }
        for _ in 0..<150 where !JITBootstrap.ready { try? await Task.sleep(nanoseconds: 200_000_000) }
        guard JITBootstrap.ready, !autoStarted, running == nil, !installer.busy, henge_vm_can_start() != 0,
              let mac = machines.all.max(by: { ($0.lastUsed ?? $0.added) < ($1.lastUsed ?? $1.added) }) else { return }
        autoStarted = true
        guard AutoStart.attempt() else {
            HengeLog.log("app", "auto-start skipped: the last two did not get going")
            return
        }
        HengeLog.log("app", "auto-start: \(mac.name)")
        running = mac
    }
}
