import SwiftUI

/// The app's settings, one section per subject; the sections that have their own file are placed here.
struct SettingsView: View {
    @ObservedObject private var jit = JITCoordinator.shared
    @AppStorage(JITCoordinator.autoEnableKey) private var jitAtLaunch = true
    @AppStorage(DeskAppearance.key) private var appearance = DeskAppearance.system

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        LabeledContent("Status", value: JITBootstrap.ready ? "On" : "Off")
                        Button("Set Up JIT…") { jit.showSetup = true }
                        Toggle("Turn On at Launch", isOn: $jitAtLaunch)
                    } header: {
                        Text("JIT")
                    } footer: {
                        if jitAtLaunch { Text("Solstice connects LocalDevVPN first when it is off, and comes back.") }
                    }
                    PointerSettings()
                    KeyboardSettings()
                    LifecycleSettings()
                    Section("Appearance") {
                        Picker("Appearance", selection: $appearance) {
                            ForEach(DeskAppearance.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    AdvancedSettings()
                    DiagnosticsSettings()
                    AboutSection()
                }
                .listRowBackground(Desk.card)
            }
            .deskForm()
            .navigationTitle("Settings")
        }
    }
}

/// Settings › Advanced: what the engine starts a Mac with. Each choice has an Automatic that follows this device.
private struct AdvancedSettings: View {
    @AppStorage(EngineTuning.refreshKey) private var refreshRate: Int?
    @AppStorage(JITBootstrap.codeCacheKey) private var codeCacheMB: Int?
    @AppStorage(EngineTuning.fastFlushKey) private var fastFlush = true
    @State private var safeMode = SafeMode.active

    /// Only the sizes the signing allows (DeviceProfile.jitMB takes a larger one as 1 GB).
    private var cacheChoices: [Int] {
        DeviceProfile.codeCacheChoices.filter { $0 == Device.profile.jitMB(chosen: $0) }
    }

    private static func size(_ mb: Int) -> String { mb < 1024 ? "\(mb) MB" : String(format: "%g GB", Double(mb) / 1024) }

    var body: some View {
        Section {
            if safeMode {
                LabeledContent("Safe Mode", value: "On")
                Button("Use Solstice's Engine Settings") { SafeMode.turnOff(); safeMode = false }
            }
            Picker("Refresh Rate", selection: Binding(
                get: { refreshRate.flatMap { Device.refreshChoices.contains($0) ? $0 : nil } },
                set: { refreshRate = $0 })) {
                Text("Automatic (\(Device.defaultRefresh) Hz)").tag(Int?.none)
                ForEach(Device.refreshChoices, id: \.self) { Text("\($0) Hz").tag(Int?.some($0)) }
            }
            Picker("Code Cache", selection: Binding(
                get: { codeCacheMB.flatMap { cacheChoices.contains($0) ? $0 : nil } },
                set: { codeCacheMB = $0 })) {
                Text("Automatic (\(Self.size(Device.profile.codeCacheMB)))").tag(Int?.none)
                ForEach(cacheChoices, id: \.self) { Text(Self.size($0)).tag(Int?.some($0)) }
            }
            Toggle("Faster Disk Writes", isOn: $fastFlush)
        } header: {
            Text("Advanced")
        } footer: {
            Text((safeMode ? "Solstice ended twice while a Mac was running, so Macs start with the standard engine settings until the next update. " : "")
                 + "Lower refresh rates leave more of the Mac's CPUs to apps. A larger code cache takes more memory; if JIT stops turning on, choose a smaller one. Faster disk writes skip a full sync, so a sudden power loss can lose the last ones. The code cache applies the next time Solstice opens, the rest the next time a Mac starts.")
        }
    }
}

/// Settings › Diagnostics: the memory iOS gives Solstice, the log, and the log sent live to a computer.
private struct DiagnosticsSettings: View {
    @ObservedObject private var stream = LogStream.shared
    @AppStorage(LogStream.enabledKey) private var streamOn = false
    @AppStorage(LogStream.hostKey) private var streamHost = ""
    @AppStorage(LogStream.portKey) private var streamPort = LogStream.defaultPort
    /// Typing an address should not reconnect on every key: the change is applied once it settles.
    @State private var applyStream: Task<Void, Never>?

    var body: some View {
        Section {
            LabeledContent("Increased Memory Limit", value: Entitlements.increasedMemory ? "On" : "Off")
            LabeledContent("Memory Limit", value: ByteText.string(UInt64(Entitlements.memoryLimitAtLaunch)))
            LabeledContent("Available Now", value: ByteText.string(UInt64(henge_available_memory())))
            LabeledContent("Code Region", value: "\(JITBootstrap.jitBytes >> 20) MB")
            ShareLink(item: HengeLog.logFileURL) { Label("Share Log", systemImage: "square.and.arrow.up") }
            Toggle("Stream Log to a Computer", isOn: $streamOn)
            if streamOn {
                TextField("Computer's Address", text: $streamHost)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                LabeledContent("Port") {
                    TextField("Port", value: $streamPort, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("State", value: stream.statusText)
                if stream.dropped > 0 { LabeledContent("Lines Dropped", value: "\(stream.dropped)") }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            let note = (Entitlements.increasedMemory ? "" : "This install is signed without the increased memory limit: reinstall Solstice with a certificate that has it, after exporting your Macs. ")
                + (streamOn ? "tools/henge-log-listen.py on the computer shows the address to type here. iOS asks for local network access the first time." : "")
            if !note.isEmpty { Text(note) }
        }
        .onChange(of: streamOn) { _ in LogStream.shared.applySettings() }
        .onChange(of: streamHost) { _ in applyStreamSoon() }
        .onChange(of: streamPort) { _ in applyStreamSoon() }
    }

    /// Applies the stream's address and port once typing pauses, rather than on every key.
    private func applyStreamSoon() {
        applyStream?.cancel()
        applyStream = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            LogStream.shared.applySettings()
        }
    }
}

extension View {
    /// A settings form on the app's page colour (rows on Desk.card).
    func deskForm() -> some View { scrollContentBackground(.hidden).background(Desk.page) }
}
