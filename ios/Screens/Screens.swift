import SwiftUI
import UIKit

/// The screens the Screens job photographs (ios/scripts/screens.sh): launched with `-solsticePreview <name>`, the app
/// opens on that screen with the sample world (SampleData.swift) and the engine stub (henge-vm-stub.c), then writes a
/// ready marker. `-solsticePreview list` writes the list instead. Only in the simulator app (ios/screens.yml).
struct Screen {
    enum Root {
        case tab(RootView.Tab)
        case jit([JITSetupFlow.Step])
        case macSettings
        case session(typing: Bool = false, details: Bool = false, confirmStop: Bool = false)
    }

    let name: String
    let root: Root
    /// The two sample Macs are there.
    var macs = true
    /// JIT is on (the stub says so).
    var jit = true
    /// A long form scrolled this many screens down.
    var page = 0
    var landscape = false
    /// What else the screen needs before the app reads anything.
    var setUp: @MainActor () -> Void = {}
    /// What else it needs once it shows (and, for a session, once the Mac is up).
    var whenUp: @MainActor (SessionController) async -> Void = { _ in }

    /// A session is always dark (RootView shows it so): one appearance is enough.
    var darkOnly: Bool { if case .session = root { return true } else { return false } }

    static let all: [Screen] = [
        Screen(name: "home", root: .tab(.macs)),
        Screen(name: "home-empty", root: .tab(.macs), whenUp: { _ in
            // Listed at launch, so the app stays on Macs instead of opening Install, then gone.
            try? await Task.sleep(nanoseconds: 300_000_000)
            for mac in Machines.shared.all { Machines.shared.delete(mac.id) }
        }),
        Screen(name: "home-jit-off", root: .tab(.macs), jit: false),
        Screen(name: "home-landscape", root: .tab(.macs), landscape: true),
        Screen(name: "install", root: .tab(.install), macs: false, jit: false),
        Screen(name: "install-download", root: .tab(.install), macs: false, jit: false, setUp: {
            Installer.shared.screens(.downloading, received: Sample.downloaded, expected: Sample.release.bytes, machineName: "Mac")
        }),
        Screen(name: "install-waiting-jit", root: .tab(.install), macs: false, jit: false, setUp: {
            Installer.shared.screens(.waitingForJIT, machineName: "Mac")
        }),
        Screen(name: "install-writing", root: .tab(.install), macs: false, setUp: {
            Installer.shared.screens(.installing, step: 2, stepProgress: 0.63, machineName: "Mac")
        }),
        Screen(name: "install-failed", root: .tab(.install), macs: false, setUp: {
            Installer.shared.screens(.failed(Sample.failure), machineName: "Mac")
        }),
        Screen(name: "install-done", root: .tab(.install), setUp: {
            Installer.shared.screens(.done(Sample.installed), machineName: Sample.hero.name)
        }),
        Screen(name: "jit-choose", root: .jit([]), jit: false),
        Screen(name: "jit-pair", root: .jit([.pairOnDevice]), jit: false),
        Screen(name: "jit-file", root: .jit([.importFile]), jit: false),
        Screen(name: "jit-connect", root: .jit([.connect]), jit: false),
        Screen(name: "jit-enable", root: .jit([.enable]), jit: false),
        Screen(name: "settings", root: .tab(.settings)),
        Screen(name: "settings-2", root: .tab(.settings), page: 1),
        Screen(name: "settings-3", root: .tab(.settings), page: 2),
        Screen(name: "settings-4", root: .tab(.settings), page: 3),
        Screen(name: "settings-5", root: .tab(.settings), page: 4),
        Screen(name: "settings-6", root: .tab(.settings), page: 5),
        Screen(name: "mac-settings", root: .macSettings),
        Screen(name: "mac-settings-2", root: .macSettings, page: 1),
        Screen(name: "mac-settings-3", root: .macSettings, page: 2),
        Screen(name: "safe-mode", root: .tab(.macs), setUp: {
            // Two launches in a row that ended with a Mac up: this one (HengeApp's noteLaunch) turns safe mode on.
            SafeMode.noteLaunch()
            UserDefaults.standard.set(1, forKey: SettingKey.uncleanEnds.rawValue)
            UserDefaults.standard.set(true, forKey: SettingKey.macLive.rawValue)
        }),
        Screen(name: "session", root: .session()),
        Screen(name: "session-keys", root: .session(typing: true)),
        Screen(name: "session-details", root: .session(details: true)),
        Screen(name: "session-shut-down", root: .session(confirmStop: true)),
        Screen(name: "session-stuck", root: .session(), whenUp: { session in
            session.screens(shutdownAskedAgo: LifecycleWatchdog.shutdownLimit + 5)
            for _ in 0..<30 where session.stuck == nil { try? await Task.sleep(nanoseconds: 100_000_000) } // the run loop's next turn
        }),
        Screen(name: "session-storage", root: .session(), whenUp: { session in
            // Storage's own reading runs every 2 s while paused: the sample's figure is put back until the picture is taken.
            Task { @MainActor in
                while true {
                    session.screens(storageFree: Sample.storageFree)
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }),
        Screen(name: "session-stopped", root: .session(), setUp: { setenv("SOLSTICE_STUB_STOP", "1", 1) }),
        Screen(name: "session-error", root: .session(), setUp: { setenv("SOLSTICE_STUB_BOOT_ERROR", Sample.bootError, 1) }),
        Screen(name: "session-landscape", root: .session(), landscape: true),
        Screen(name: "session-landscape-keys", root: .session(typing: true), landscape: true),
    ]
}

@MainActor
enum Screens {
    static let requested: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-solsticePreview"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()
    static let current = Screen.all.first { $0.name == requested }

    /// What the job waits for: the screen's name once it can be photographed, "skip" for a page past the end.
    static let readyFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("solstice-preview-ready")
    /// `-solsticePreview list`: one screen a line, its name and flags (dark-only, landscape).
    static let listFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("solstice-preview-list")

    static func mark(_ text: String) { try? Data(text.utf8).write(to: readyFile, options: .atomic) }

    /// Before HengeApp reads anything: a clean container, then this screen's sample world.
    static func prepare() {
        guard let requested else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: readyFile)
        if requested == "list" {
            let lines = Screen.all.map { s in
                ([s.name] + (s.darkOnly ? ["dark-only"] : []) + (s.landscape ? ["landscape"] : [])).joined(separator: " ")
            }
            try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: listFile, options: .atomic)
            mark("list")
            return
        }
        guard let screen = current else { return }
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for item in (try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: item) }
        try? fm.removeItem(at: Machines.root)
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        setenv("SOLSTICE_STUB_JIT", screen.jit ? "1" : "0", 1)
        let d = UserDefaults.standard
        if screen.macs {
            Sample.writeMacs()
            // The screen, not a Mac started over it by itself. Settings shows the switch for that: there it stays as
            // it comes, and the start holds off as after two that did not get going (its notice is on Home only).
            if case .tab(.settings) = screen.root {
                d.set(AutoStart.failureLimit, forKey: SettingKey.autoStartFailures.rawValue)
            } else {
                d.set(false, forKey: SettingKey.autoStartMac.rawValue)
            }
        }
        if !screen.jit { d.set(false, forKey: SettingKey.jitAtLaunch.rawValue) } // no attempt to turn it on
        Sample.writePairing()
        screen.setUp()
    }

    /// Once the screen shows: turn, wait for the session, scroll, then say it is ready.
    static func settle(_ screen: Screen, session: SessionController) async {
        if screen.landscape { rotate() }
        if case .session = screen.root {
            for _ in 0..<100 where session.error == nil && session.state != HENGE_VM_RUNNING && session.state != HENGE_VM_STOPPED {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        await screen.whenUp(session)
        try? await Task.sleep(nanoseconds: 1_000_000_000) // animations, sheets and the first engine poll
        if case .session = screen.root {
            HengeLog.log("screens", "\(screen.name): state \(session.state.rawValue), error \(session.error ?? "none"), "
                         + "stuck \(session.stuck.map { "\($0)" } ?? "no"), storage paused \(session.storagePaused)")
        }
        if screen.page > 0 {
            guard scroll(to: screen.page) else { return mark("skip") }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        mark(screen.name)
    }

    private static func rotate() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
            HengeLog.log("screens", "landscape refused: \(error.localizedDescription)")
        }
    }

    /// The tallest scroll view on screen, a page further down for each page (a little of the last one stays).
    /// false when the page before already reached the end.
    private static func scroll(to page: Int) -> Bool {
        var tallest: UIScrollView?
        func walk(_ view: UIView) {
            if let s = view as? UIScrollView, !s.isHidden, s.bounds.width > 200,
               s.contentSize.height > (tallest?.contentSize.height ?? 0) { tallest = s }
            view.subviews.forEach(walk)
        }
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).forEach(walk)
        guard let view = tallest else { return false }
        let inset = view.adjustedContentInset
        let step = max(view.bounds.height - inset.top - inset.bottom - 80, 100)
        let top = -inset.top, bottom = max(top, view.contentSize.height + inset.bottom - view.bounds.height)
        guard top + CGFloat(page - 1) * step < bottom - 1 else { return false }
        view.setContentOffset(CGPoint(x: view.contentOffset.x, y: min(top + CGFloat(page) * step, bottom)), animated: false)
        return true
    }
}

/// The app's root in the simulator app: the requested screen, or the app as it is.
struct ScreensRoot: View {
    private let screen = Screens.current
    @StateObject private var session = SessionController(mac: Sample.hero)

    var body: some View {
        content.task {
            guard let screen else { return }
            await Screens.settle(screen, session: session)
        }
    }

    @ViewBuilder private var content: some View {
        switch screen?.root {
        case .tab(let tab):
            RootView(screensTab: tab)
        case .jit(let path):
            RootView(screensTab: .macs).sheet(isPresented: .constant(true)) { JITSetupFlow(screensPath: path) }
        case .macSettings:
            NavigationStack { MacSettingsView(mac: Sample.hero) { _ in } }.tint(Desk.accentLight)
        case .session(let typing, let details, let confirmStop):
            SessionView(screens: Sample.hero, session: session, typing: typing, details: details, confirmStop: confirmStop)
                .environment(\.colorScheme, .dark)
                .background(WindowStyle(style: .dark))
        case nil:
            RootView()
        }
    }
}
