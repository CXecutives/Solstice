import SwiftUI

struct SettingsView: View {
    @ObservedObject private var jit = JITCoordinator.shared
    @AppStorage(JITCoordinator.autoEnableKey) private var jitAtLaunch = true
    @AppStorage(HardwareMouse.speedKey) private var mouseSpeed = 1.0
    @AppStorage(HardwareMouse.reverseKey) private var reverseScrolling = false
    @AppStorage(HardwareMouse.scrollSpeedKey) private var scrollSpeed = 0.3
    @AppStorage(PhysicalMouseButtons.swapKey) private var swapMouseButtons = false
    @AppStorage(EngineTuning.refreshKey) private var refreshRate = 60
    @AppStorage(EngineTuning.fastFlushKey) private var fastFlush = true
    @AppStorage(EngineTuning.wfiSpinKey) private var wfiSpin = false
    @AppStorage(EngineTuning.superblocksKey) private var superblocks = false
    @State private var safeMode = SafeMode.active
    @AppStorage(JITBootstrap.codeCacheKey) private var codeCacheMB = Device.profile.codeCacheMB
    @ObservedObject private var stream = LogStream.shared
    @AppStorage(LogStream.enabledKey) private var streamOn = false
    @AppStorage(LogStream.hostKey) private var streamHost = ""
    @AppStorage(LogStream.portKey) private var streamPort = LogStream.defaultPort
    /// Typing an address should not reconnect on every key: the change is applied once it settles.
    @State private var applyStream: Task<Void, Never>?

    /// Applies the stream's address and port once typing pauses, rather than on every key.
    private func applyStreamSoon() {
        applyStream?.cancel()
        applyStream = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            LogStream.shared.applySettings()
        }
    }
    @AppStorage(DeskAppearance.key) private var appearance = DeskAppearance.system
    @AppStorage(InstantResume.key) private var instantResume = false
    @AppStorage(KeepAlive.key) private var keepAlive = true

    var body: some View {
        NavigationStack {
            Form {
                Section("JIT") {
                    LabeledContent("Status", value: JITBootstrap.ready ? "On" : "Off")
                    Button("Set up JIT") { jit.showSetup = true }
                    Toggle("Turn on JIT when Henge opens", isOn: $jitAtLaunch)
                    if jitAtLaunch {
                        Text("Henge connects LocalDevVPN first when it is off, and comes back.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("Code region", value: "\(JITBootstrap.jitBytes >> 20) MB, claimed once per launch")
                }
                .listRowBackground(Desk.card)
                Section("Memory") {
                    LabeledContent("Extra memory", value: Entitlements.increasedMemory ? "On" : "Off")
                    LabeledContent("Henge's limit", value: ByteText.string(UInt64(Entitlements.memoryLimitAtLaunch)))
                    LabeledContent("Free for Henge", value: ByteText.string(UInt64(henge_available_memory())))
                    Text(Entitlements.increasedMemory
                         ? "A Mac's memory is kept out of this limit once JIT is on. If iOS refuses that, it uses free storage instead."
                         : "This install isn't signed with the increased memory limit entitlement. Reinstall Henge with a certificate that has it. Export your Mac first if the reinstall replaces the app's data.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                if Device.isPad {
                    Section("Mouse and Trackpad") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pointer speed")
                            Slider(value: $mouseSpeed, in: 0.5...3)
                        }
                        Toggle("Reverse scrolling", isOn: $reverseScrolling)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Scroll speed")
                            Slider(value: $scrollSpeed, in: 0.1...1.5)
                        }
                        Toggle("Swap physical right and middle buttons", isOn: $swapMouseButtons)
                        Text("Only enable this if your physical mouse's right and middle buttons are reversed in the Mac. Touch controls stay unchanged. Restart the Mac session to apply.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("A Magic Keyboard or a Bluetooth mouse moves the Mac's pointer. Pointer speed changes apply the next time a Mac starts; scroll speed changes apply immediately.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Desk.card)
                }
                if !Device.isPad {
                    Section("Trackpad") {
                        Text("Henge is able to emulate a Magic Trackpad, allowing you to perform native macOS gestures using your device's touchscreen.\n\nTap to click once. Tap then hold to begin dragging. Quickly tap with two fingers to right-click.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Desk.card)
                }
                Section("Performance") {
                    if safeMode {
                        LabeledContent("Safe mode", value: "On")
                        Button("Use Solstice's Engine Settings") { SafeMode.turnOff(); safeMode = false }
                        Text("The last two times, Solstice ended while a Mac was running, so Macs start with Henge's standard engine settings until the next update.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Picker("Mac refresh rate", selection: $refreshRate) {
                        Text("30 Hz").tag(30)
                        Text("60 Hz").tag(60)
                        Text("120 Hz").tag(120)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Faster disk writes", isOn: $fastFlush)
                    Toggle("Quicker wake from idle", isOn: $wfiSpin)
                    Toggle("Superblocks (experimental)", isOn: $superblocks)
                    Picker("Code cache", selection: $codeCacheMB) {
                        ForEach(DeviceProfile.codeCacheChoices, id: \.self) { mb in
                            Text(mb < 1024 ? "\(mb) MB" : String(format: "%g GB", Double(mb) / 1024)).tag(mb)
                        }
                    }
                    Text("A bigger code cache empties less often and takes more memory (its records add about half to two thirds of its size again); Henge picks one by the device's memory and its limit. 1.5 GB also needs extended-virtual-addressing in the signing (a paid team): without it 1 GB is the most that fits. Applies the next time Henge opens. If JIT stops turning on, or a Mac closes Henge during setup, choose a smaller one.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("macOS draws a frame for every refresh: 30 Hz leaves the most of the emulated CPU to apps, at the cost of choppier animation; 60 Hz is smoother. Faster disk writes order them without waiting for a full sync; a sudden power loss could lose the last ones. Quicker wake keeps an idle CPU watching for work for 50 µs, at some battery cost. Superblocks let translated code run past conditional branches. Changes apply the next time a Mac starts.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("In the Background") {
                    Toggle("Keep Henge awake", isOn: $keepAlive)
                    Text("While a Mac is open or macOS is installing, Henge stays awake when you leave it or the screen locks, so iOS is much less likely to close it and an install goes on. A running Mac waits, paused, until you are back. Henge plays silence to do this; other apps' audio is not interrupted.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Instant Resume") {
                    Toggle("Resume where you left off", isOn: $instantResume)
                    Text("When you leave Henge, the running Mac is saved to storage, and opening it again picks up where it was in a few seconds, even after iOS closes Henge. The save is about the size of the Mac's memory in use, compressed. The Mac pauses while Henge is in the background, so its sound stops. Experimental.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(DeskAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("System follows the \(Device.name)'s Light or Dark setting. Henge stays dark while a Mac is running.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Log") {
                    ShareLink(item: HengeLog.logFileURL) { Label("Share henge.log", systemImage: "square.and.arrow.up") }
                }
                .listRowBackground(Desk.card)
                Section("Log stream") {
                    Toggle("Send the log to a computer", isOn: $streamOn)
                    TextField("Computer's address", text: $streamHost)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("Port", value: $streamPort, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                    }
                    LabeledContent("State", value: stream.statusText)
                    if stream.dropped > 0 {
                        LabeledContent("Lines dropped", value: "\(stream.dropped)")
                    }
                    Text("Every line the app writes goes to the computer as it happens (tools/henge-log-listen.py there prints the address to type above). iOS asks for local network access the first time.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
            }
            .scrollContentBackground(.hidden)
            .background(Desk.page)
            .navigationTitle("Settings")
            .onChange(of: streamOn) { _ in LogStream.shared.applySettings() }
            .onChange(of: streamHost) { _ in applyStreamSoon() }
            .onChange(of: streamPort) { _ in applyStreamSoon() }
        }
    }
}
