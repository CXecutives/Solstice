import SwiftUI
import GameController

/// A running Mac. Upright, its screen sits above a trackpad; on its side the screen fills the device
/// and is its own trackpad. Zoomed in, the screen fills the device either way and follows the pointer.
/// A keyboard, trackpad or mouse attached to an iPad works throughout.
struct SessionView: View {
    let mac: VirtualMac
    let close: () -> Void

    @StateObject private var display = DisplayRouter()
    @State private var bootAttempt = 0
    @ObservedObject private var power = PowerPolicy.shared // heat: the Mac may be paused for it
    private var cpus: Int { mac.cpus }
    @AppStorage(SettingKey.screenBrightness.rawValue) private var screenBrightness = SettingDefault.screenBrightness
    @AppStorage(SettingKey.cursorScale.rawValue) private var cursorScale = Device.isPad ? 1 : 3

    @State private var typing = false
    @State private var zoomed = false
    @State private var showDetails = false
    @State private var controlsHidden = false
    @State private var showRevealHint = false
    @State private var pointerRefused = false
    @AppStorage(SettingKey.controlsHintsShown.rawValue) private var revealHintsShown = 0
    /// Once per install: macOS's moving wallpapers and aerial screen saver are video, decoded by the emulated
    /// CPUs (a phone ran about 30% faster with a still one).
    @AppStorage(SettingKey.stillWallpaperTipShown.rawValue) private var stillWallpaperTipShown = false
    @State private var showWallpaperTip = false
    @State private var confirmStop = false
    @State var zoomCentre = CGPoint(x: 0.5, y: 0.5) // where the zoomed view is, 0...1 of the Mac's screen
    @State var map: UIImage?
    @State private var zoomFollowing: Task<Void, Never>?
    @State var shown = CGSize(width: 0.5, height: 0.5) // how much of the Mac's screen the zoomed view shows
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    /// The Mac's lifecycle: starting it, the engine's state while it runs, storage, shutting down.
    @StateObject private var session: SessionController

    init(mac: VirtualMac, close: @escaping () -> Void) {
        self.mac = mac
        self.close = close
        _session = StateObject(wrappedValue: SessionController(mac: mac))
    }

    // What the view shows of the running Mac, from the session.
    private var error: String? { session.error }
    private var state: SolsticeVmState { session.state }
    private var cpusOn: Int32 { session.cpusOn }
    private var userCode: Bool { session.userCode }
    private var blocksPerSecond: Double { session.blocksPerSecond }
    private var framesOut: UInt64 { session.framesOut }
    private var framesIn: UInt64 { session.framesIn }
    private var log: [String] { session.log }
    private var started: Date { session.started }
    private var bootRAM: UInt64 { session.bootRAM }
    private var helperRunning: Bool { session.helperRunning }
    private var storagePaused: Bool { session.storagePaused }
    private var storageRoom: Bool { session.storageRoom }
    private var storageFree: Int64 { session.storageFree }

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            let landscape = full.width > full.height
            let layout = Layout(full: full, insets: insets, landscape: landscape, zoomed: zoomed, typing: typing, centre: zoomCentre,
                                pixels: CGSize(width: mac.screen.width, height: mac.screen.height), scale: displayScale)
            ZStack(alignment: .topLeading) {
                (landscape || zoomed ? Color.black : Desk.page)
                // One view in every layout: it holds the layer the engine draws into.
                // Upright, the 15 pt corner is the layer's own (no mask over the Mac's frames); filling the device, none.
                BootDisplay(display: display, role: .device, cornerRadius: layout.fillsPhone ? 0 : 15)
                    .opacity(display.isExternal ? 0 : 1)
                    .overlay {
                        if display.isExternal && state != SOLSTICE_VM_STOPPED {
                            VStack(spacing: 8) {
                                Image(systemName: "display").font(.largeTitle)
                                Text("Mac on external display").font(.headline)
                                Text("Use the trackpad, keyboard or a connected mouse.")
                                    .font(.subheadline)
                            }
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(width: layout.screen.width, height: layout.screen.height)
                    .overlay {
                        if !layout.fillsPhone {
                            RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                        }
                    }
                    .position(x: layout.screen.midX, y: layout.screen.midY)
                if state != SOLSTICE_VM_STOPPED {
                    Trackpad(overScreen: true)
                        .frame(width: layout.touch.width, height: layout.touch.height)
                        .position(x: layout.touch.midX, y: layout.touch.midY)
                    if !layout.fillsPhone {
                        uprightControls(layout)
                    } else {
                        floatingControls(layout)
                    }
                    if pointerRefused && !showRevealHint {
                        Label("Make Solstice full screen to use the trackpad or mouse as the Mac's", systemImage: "cursorarrow.rays")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: Capsule())
                            .position(x: full.width / 2, y: insets.top + 40)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                    if showRevealHint {
                        Label("Tap with four fingers to show the controls", systemImage: "hand.tap")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: Capsule())
                            .position(x: full.width / 2, y: insets.top + 40)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                    if showWallpaperTip && !showRevealHint && !pointerRefused {
                        Label("For more speed, give this Mac a still wallpaper and set its screen saver to Never in System Settings.", systemImage: "speedometer")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: min(full.width - 40, 520))
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .position(x: full.width / 2, y: insets.top + 56)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                if state == SOLSTICE_VM_STOPPED {
                    StoppedMacView(outcome: solstice_vm_exit_outcome(), reason: String(cString: solstice_vm_exit_reason()),
                                   start: { bootAttempt += 1 }, close: close)
                        .frame(width: min(layout.touch.width - 32, 360))
                        .position(x: layout.touch.midX, y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
                }
                if let error { errorCard(error, layout) }
                if storagePaused && state != SOLSTICE_VM_STOPPED { storageCard(layout) }
                if let stuck = session.stuck { LifecycleNotice(stuck: stuck, session: session, close: close).frame(width: min(layout.touch.width, 390) - 32).position(x: layout.fillsPhone ? layout.touch.midX : layout.pad.midX, y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY) }
                if power.holding && state != SOLSTICE_VM_STOPPED {
                    HeatNotice().frame(width: min(layout.touch.width, 390) - 32)
                        .position(x: layout.fillsPhone ? layout.touch.midX : layout.pad.midX, y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
                }
                KeyboardCatcher(active: $typing).frame(width: 0, height: 0)
            }
            .frame(width: full.width, height: full.height)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.25), value: zoomed)
            .animation(.easeInOut(duration: 0.25), value: typing)
            .animation(.easeInOut(duration: 0.25), value: controlsHidden)
            .animation(.easeInOut(duration: 0.25), value: showRevealHint)
            .animation(.easeInOut(duration: 0.25), value: showWallpaperTip)
            .onReceive(NotificationCenter.default.publisher(for: UIPointerLockState.didChangeNotification)) { _ in
                pointerRefused = PointerLock.refused
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidConnect)) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pointerRefused = PointerLock.refused }
            }
            .onReceive(NotificationCenter.default.publisher(for: Trackpad.revealTap)) { _ in
                controlsHidden = false
                showRevealHint = false
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let p) = phase { AbsolutePointer.move(to: p) }
            }
            .onAppear {
                shown = layout.shown
                AbsolutePointer.screen = display.isExternal ? nil : layout.screen
            }
            .onChange(of: layout.shown) { shown = $0 }
            .onChange(of: layout.screen) { AbsolutePointer.screen = display.isExternal ? nil : $0 }
            .onChange(of: full) { _ in PointerLock.set(!pointerNeeded) } // a window filling the screen, or no longer
            .onChange(of: display.isExternal) { AbsolutePointer.screen = $0 ? nil : layout.screen }
            .onDisappear { AbsolutePointer.screen = nil }
        }
        .statusBarHidden(zoomed || Device.isPad)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all) // a swipe from an edge is the Mac's first; a second one goes to iOS
        .sheet(isPresented: $showDetails) { details }
        .confirmationDialog("Shut down \(mac.name)?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Shut Down") { session.shutDown(off: close) } // macOS shuts down; the view closes once it is off
            Button("Force Off", role: .destructive) { session.forceOff(then: close) }
        } message: {
            Text("Shut Down asks macOS to close its apps and turn off. Force Off turns it off at once; anything not saved on it is lost.")
        }
        .onChange(of: zoomed) { on in
            zoomFollowing?.cancel()
            zoomFollowing = on ? Task { await followPointer() } : nil
        }
        .onChange(of: pointerNeeded) { PointerLock.set(!$0) }
        .onChange(of: scenePhase) { phase in
            guard phase != .active else {
                display.refresh()
                InstantResume.cameBack(mac)
                if bootRAM > 0 && solstice_vm_state() != SOLSTICE_VM_STOPPED { SafeMode.macLive(true) }
                return
            }
            // In the background the Mac waits, paused: Solstice ending there is iOS's doing, not a crash with a Mac up.
            if phase == .background { SafeMode.macLive(false) }
            HardwareKeys.releaseAll()
            HardwareMouse.shared.releaseButtons()
            if phase == .inactive { InstantResume.pause() }
            if phase == .background && bootRAM > 0 { InstantResume.suspend(mac) }
            if phase == .background { InstantResume.rest(mac) }
        }
        .onChange(of: showDetails) { showing in
            if showing {
                HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll()
                session.refreshDetails() // the loop fills them in only while they show
            }
        }
        .onChange(of: confirmStop) { showing in
            if showing { HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll() }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true // the physical mouse starts with each run (SessionController)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            SafeMode.macLive(false)
            StorageGuard.holding = false
            zoomFollowing?.cancel()
            StickyKeys.shared.releaseAll()
            HardwareKeys.releaseAll()
            HardwareMouse.shared.stop()
        }
        .modifier(ExternalMacDisplayModifier(presentation: MacPresentation(display: display, aspect: mac.aspect)))
        .task(id: bootAttempt) { await start() }
        .task { await Sharing.followMacClipboard() }
        .task { await session.watchStorage() }
    }

    /// When there is something of the app's to point at, iPadOS gets its own pointer back.
    private var pointerNeeded: Bool { state == SOLSTICE_VM_STOPPED || showDetails || confirmStop || error != nil || storagePaused }

    // MARK: Upright

    @ViewBuilder private func uprightControls(_ layout: Layout) -> some View {
        if !typing && !controlsHidden {
            HStack {
                tool("eye.slash", "Hide controls") { hideControls() }
                Spacer()
                tool("keyboard", "Keyboard") { typing = true }
                Spacer()
                pasteTool
                Spacer()
                tool("plus.magnifyingglass", "Zoom in") { zoomed = true }
                Spacer()
                tool("info.circle", "Details") { showDetails = true }
                Spacer()
                tool("power", "Shut down", tint: Desk.bad) { stopTapped() }.disabled(session.starting).opacity(session.starting ? 0.4 : 1)
            }
            .padding(.horizontal, 22)
            .frame(width: layout.pad.width, height: 54)
            .background(Desk.card, in: Capsule())
            .overlay(Capsule().stroke(Desk.hairline, lineWidth: 0.5))
            .position(x: layout.pad.midX, y: layout.toolsY + 27)
            .transition(.opacity)
        }
        trackpadPanel(layout)
    }

    /// A card (could not start, storage, stuck, heat, stopped) is over the trackpad.
    private var cardUp: Bool {
        error != nil || storagePaused || session.stuck != nil || power.holding || state == SOLSTICE_VM_STOPPED
    }

    private func trackpadPanel(_ layout: Layout) -> some View {
        let compact = layout.pad.height < 260
        return VStack(spacing: 0) {
            ZStack {
                Trackpad()
                if cardUp {
                    EmptyView() // a card sits over the pad: its hints would show around it
                } else if compact {
                    Text("Trackpad").font(.system(size: 14)).foregroundStyle(Desk.faint).allowsHitTesting(false)
                } else {
                    VStack(spacing: 6) {
                        hint("Drag", "to move")
                        hint("Tap", "to click")
                        hint("Hold, then drag", "to grab")
                        hint("Two fingers", "to scroll")
                    }
                    .allowsHitTesting(false)
                }
            }
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            HStack(spacing: 0) {
                MouseButton(title: "Click", button: 0)
                Rectangle().fill(Desk.hairline).frame(width: 0.5)
                MouseButton(title: "Right-click", button: 1)
            }
            .frame(height: compact ? 50 : 70)
        }
        .background(Desk.card)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Desk.hairline, lineWidth: 0.5))
        .frame(width: layout.pad.width, height: layout.pad.height)
        .position(x: layout.pad.midX, y: layout.pad.midY)
    }

    private func hint(_ strong: String, _ rest: String) -> some View {
        (Text(strong).foregroundColor(Desk.dim).fontWeight(.semibold) + Text(" \(rest)").foregroundColor(Desk.faint))
            .font(.system(size: 15))
    }

    /// The system's paste button: iOS asks no permission for it, as it would if the app read the clipboard itself.
    private var pasteTool: some View {
        PasteButton(payloadType: String.self) { texts in
            if let text = texts.first { Sharing.paste(text) }
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.circle)
        .tint(Desk.raised)
    }

    /// Hides the session's controls; four fingers on the screen bring them back. The first few times say so.
    private func hideControls() {
        controlsHidden = true
        typing = false
        guard revealHintsShown < 3 else { return }
        revealHintsShown += 1
        showRevealHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showRevealHint = false }
    }

    private func tool(_ symbol: String, _ label: String, tint: Color = Desk.text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    // MARK: Filling the phone

    @ViewBuilder private func floatingControls(_ layout: Layout) -> some View {
        let landscape = layout.touch.width > layout.touch.height
        let top = layout.insets.top + (landscape ? 8 : 6)
        // A phone on its side: the controls stand in the margin beside the Mac's screen (by the Dynamic
        // Island), not over the Mac's menu bar. Not while typing: the keyboard covers the margin's lower half.
        let margin = layout.screen.minX - layout.insets.leading
        let standing = landscape && !zoomed && !typing && layout.barY == nil && margin >= 50 // the pill is 50 wide
        let stack = standing ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        let pill = stack {
            tool("eye.slash", "Hide controls", tint: .white) { hideControls() }
            tool("keyboard", "Keyboard", tint: .white) { typing.toggle() }
            pasteTool
            tool(zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass", zoomed ? "Zoom out" : "Zoom in", tint: zoomed ? Desk.accentLight : .white) { zoomed.toggle() }
            tool("info.circle", "Details", tint: .white) { showDetails = true }
            Rectangle().fill(Color.white.opacity(0.3))
                .frame(width: standing ? 22 : 1, height: standing ? 1 : 22)
                .padding(standing ? .vertical : .horizontal, 4)
            tool("power", "Shut down", tint: Desk.bad) { stopTapped() }.disabled(session.starting).opacity(session.starting ? 0.4 : 1)
        }
        .padding(standing ? .vertical : .horizontal, 8)
        .frame(width: standing ? 50 : nil, height: standing ? nil : 50)
        .deskGlass(in: Capsule())
        if controlsHidden {
            EmptyView()
        } else if standing {
            pill.position(x: layout.insets.leading + margin / 2, y: layout.touch.midY)
        } else if let barY = layout.barY {
            pill.position(x: layout.touch.midX, y: barY)
        } else if landscape || typing {
            pill.position(x: layout.touch.midX, y: top + 25)
        } else {
            pill.position(x: layout.touch.midX, y: layout.touch.height - layout.insets.bottom - 34)
        }
        if zoomed { zoomMap(layout) }
    }

    // MARK: Status

    private func errorCard(_ text: String, _ layout: Layout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This Mac could not start").font(.system(size: 17, weight: .semibold))
            Text(text).font(.system(size: 14)).foregroundStyle(Desk.dim)
            Button("Close") { close() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
        }
        .padding(18)
        .frame(width: min(layout.touch.width, 390) - 32, alignment: .leading)
        .background(Desk.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .position(x: (layout.fillsPhone ? layout.touch.midX : layout.pad.midX), y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
    }

    /// Paused for want of storage: what to do, and the way back once there is room.
    private func storageCard(_ layout: Layout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Storage is almost full").font(.system(size: 17, weight: .semibold))
            Text("\(ByteText.string(UInt64(max(storageFree, 0)))) free. The Mac is paused so its disk cannot fill this \(Device.name); it needs \(ByteText.string(UInt64(StorageGuard.minimumFree))) free. Make room in Settings > General > \(Device.name) Storage, then resume it.")
                .font(.system(size: 14)).foregroundStyle(Desk.dim)
            Button(storageRoom ? "Resume the Mac" : "Waiting for free storage…") { session.resumeAfterStorage() }
            .disabled(!storageRoom)
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(storageRoom ? Desk.accentLight : Desk.dim)
        }
        .padding(18)
        .frame(width: min(layout.touch.width, 390) - 32, alignment: .leading)
        .background(Desk.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .position(x: (layout.fillsPhone ? layout.touch.midX : layout.pad.midX), y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
    }

    private var phase: String {
        switch state {
        case SOLSTICE_VM_IDLE: return error == nil ? "Starting…" : "Not started"
        case SOLSTICE_VM_RUNNING: return userCode ? "macOS is running" : "Booting"
        case SOLSTICE_VM_STARTING_OR_STOPPING: return "Finishing shutdown…"
        default: return "Stopped (\(String(cString: solstice_vm_exit_reason())))"
        }
    }

    private var details: some View {
        NavigationStack {
            List {
                Section(phase) {
                    LabeledContent("CPUs on", value: "\(cpusOn) of \(session.bootCPUs > 0 ? session.bootCPUs : cpus)")
                    LabeledContent("Temperature", value: PowerPolicy.label(power.thermal))
                    LabeledContent("Translated blocks", value: String(format: "%.1f M/s", blocksPerSecond / 1e6))
                    LabeledContent("Network frames", value: "\(framesOut) out, \(framesIn) in")
                    LabeledContent("Up", value: "\(Int(Date().timeIntervalSince(started))) s")
                }
                Section("Display") {
                    LabeledContent("Brightness", value: "\(Int(screenBrightness * 100))%")
                    Slider(value: $screenBrightness, in: 0.4...1)
                    Text("Brightness dims only the Mac's screen.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Pointer") {
                    Picker("Size", selection: $cursorScale) {
                        Text("1×").tag(1)
                        Text("2×").tag(2)
                        Text("3×").tag(3)
                    }
                    .pickerStyle(.segmented)
                    ScrollSpeedRow()
                    Text("The Mac supplies a small pointer image. Enlarging it can look blurry; 1× is the sharpest on an iPad.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Sharing") {
                    LabeledContent("Clipboard and folder", value: helperRunning ? "On" : "Not set up")
                    if !helperRunning {
                        Button("Type the Set Up Command") {
                            showDetails = false
                            Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                await Sharing.typeSetUpCommand()
                            }
                        }
                    }
                    Text(helperRunning
                         ? "Put files in Files > On My \(Device.name) > \(Brand.name) > Shared to see them in the \(Brand.shareName) folder in this Mac's home folder. What you copy on the Mac is copied here too, and the paste button pastes from here into the Mac."
                         : "Once for each Mac: open Terminal on the Mac, tap this, then press Return. When macOS asks about solstice-agent and local networks, choose Allow. It types \(Sharing.setUpCommand) for the Mac keyboard layout chosen in Settings (\(KeyLayout.current.title)).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Lighter macOS") {
                    Button("Type the Lighter macOS Command") {
                        showDetails = false
                        Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            await Keys.typeSlowly(Sharing.lightenCommand)
                        }
                    }
                    Button("Type the Undo Command") {
                        showDetails = false
                        Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            await Keys.typeSlowly(Sharing.unlightenCommand)
                        }
                    }
                    Text("Less drawing for the emulated CPUs: window and Dock animations, desktop widgets, the screen saver and a moving wallpaper go. Open Terminal on the Mac, tap the button and press Return, then log out and back in. Also turn on Reduce Motion and Reduce Transparency in the Mac's System Settings, Accessibility. Undo puts it back, apart from the wallpaper. It types for the Mac keyboard layout chosen in Settings (\(KeyLayout.current.title)).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Log") {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(log.suffix(30).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Running

    /// Starts the Mac (again): the view's own state first, then the session runs it.
    private func start() async {
        zoomed = false
        controlsHidden = false
        showRevealHint = false
        zoomCentre = CGPoint(x: 0.5, y: 0.5)
        map = nil
        showWallpaperTip = false
        await session.run(cpus: cpus, hooks: SessionController.Hooks(
            detailsShown: { showDetails },
            inBackground: { scenePhase == .background },
            stopped: {
                typing = false
                showDetails = false
                confirmStop = false
                zoomFollowing?.cancel()
            },
            restart: { bootAttempt += 1 },
            shutDown: close,
            minuteUp: {
                guard !stillWallpaperTipShown else { return } // about when the desktop is up after a login
                stillWallpaperTipShown = true
                showWallpaperTip = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { showWallpaperTip = false }
            }))
    }

    private func stopTapped() {
        if state == SOLSTICE_VM_RUNNING { confirmStop = true } else { close() }
    }
}

#if SOLSTICE_SCREENS
extension SessionView {
    /// The simulator app for screenshots (ios/Screens): the session with its controller, and typing, the details or the
    /// shut-down question already open.
    init(screens mac: VirtualMac, session: SessionController, typing: Bool, details: Bool, confirmStop: Bool) {
        self.init(mac: mac, close: {})
        _session = StateObject(wrappedValue: session)
        _typing = State(initialValue: typing)
        _showDetails = State(initialValue: details)
        _confirmStop = State(initialValue: confirmStop)
    }
}
#endif
