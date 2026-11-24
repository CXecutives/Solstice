import SwiftUI
import AVFAudio

@main
struct SolsticeApp: App {
    /// Answers for external display scenes before iOS 27 (LegacyExternalDisplay.swift).
    @UIApplicationDelegateAdaptor(SolsticeAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if SOLSTICE_SCREENS
        Screens.prepare() // the simulator app for screenshots (ios/screens.yml): its sample world, before anything reads it
        #endif
        // Order matters: SolsticeLog takes over stderr, so the engine's and the JIT
        // allocator's first lines land in Documents/solstice.log too.
        SolsticeLog.start()
        SolsticeLog.log("boot", "address space: \(solstice_largest_reservation_gb()) GB can be reserved in one piece")
        SafeMode.noteLaunch() // before the engine's settings: two launches in a row that ended with a Mac up start it safe
        EngineTuning.apply()
        // Settings > Log stream: send the log to a computer on this network, if that is on.
        LogStream.shared.applySettings()
        SolsticeLog.logFootprint("app-launch")
        SolsticeLog.log("app", "increased memory limit: \(Entitlements.increasedMemory ? "yes" : "no"); extended addressing: \(Entitlements.extendedAddressing ? "yes" : "no"); limit \(Entitlements.memoryLimitAtLaunch >> 20) MB")
        // Without the guard, a brk no debugger answers kills the app instead of failing.
        JITBootstrap.installTrapGuard()
        // The Mac's sound plays in this category; setting it can take a while, and nothing before the first frame needs it.
        DispatchQueue.global(qos: .utility).async {
            try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        }
        Machines.shared.collectImports()
        DispatchQueue.main.async { KeepAlive.start() } // once the app is up: it watches the Mac and the installer
    }

    var body: some Scene {
        WindowGroup {
            #if SOLSTICE_SCREENS
            ScreensRoot()
            #else
            RootView()
                .onOpenURL { url in SolsticeLog.log("app", "opened with \(url.absoluteString)") } // solstice:// back from LocalDevVPN
            #endif
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
    @AppStorage(SettingKey.appearance.rawValue) private var appearance = DeskAppearance.system

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
            Button("Turn Off Safe Mode") { SafeMode.turnOff() }
        } message: {
            Text("The last two times, Solstice ended while a Mac was running. Until the next update it starts Macs with the original engine settings. You can turn this off under Settings > Performance.")
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
            // Attached already (a task also runs on the first appearance, when there may be no phase change): claim the
            // region now. The helper attaching later bumps attachGeneration, which claims it below.
            if !JITBootstrap.ready && JITBootstrap.debuggedFlag { JITBootstrap.prewarm() }
            jit.objectWillChange.send() // readiness lives outside the observable coordinator
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
        for _ in 0..<60 where solstice_vm_can_start() == 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
        guard solstice_vm_can_start() != 0 else {
            SolsticeLog.log("app", "the installed Mac was not started: the installer's machine was not released in 30 s")
            machines.lastError = "\(mac.name) is installed. Quit Solstice and open it again to start it."
            return
        }
        guard running == nil else { return }
        tab = .macs
        running = mac
    }

    /// Settings › Start the last Mac when JIT is on: once per launch, when nothing else is going on. A Mac that
    /// failed to come up twice in a row turns this off until one starts by hand.
    func autoStartLastMac() async {
        guard !autoStarted, AutoStart.enabled, running == nil, !installer.busy else { return }
        guard await JITBootstrap.waitUntilReady(timeout: 30), !autoStarted, running == nil, !installer.busy, solstice_vm_can_start() != 0,
              let mac = machines.all.max(by: { ($0.lastUsed ?? $0.added) < ($1.lastUsed ?? $1.added) }) else { return }
        autoStarted = true
        guard AutoStart.attempt() else {
            SolsticeLog.log("app", "auto-start skipped: the last two did not get going")
            machines.lastError = AutoStart.heldOffNotice(mac.name)
            return
        }
        SolsticeLog.log("app", "auto-start: \(mac.name)")
        running = mac
    }
}

#if SOLSTICE_SCREENS
extension RootView {
    /// The simulator app for screenshots (ios/Screens): opens on this tab, with this Mac started.
    init(screensTab: Tab, running: VirtualMac? = nil) {
        self.init()
        _tab = State(initialValue: screensTab)
        _running = State(initialValue: running)
    }
}
#endif
