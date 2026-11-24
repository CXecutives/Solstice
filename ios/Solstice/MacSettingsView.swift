import SwiftUI

/// One Mac: what it has, and what can be done with it. What it starts with applies at its next start; a Mac saved by
/// Instant Resume (to the person still running) can be restarted from here to take it at once.
struct MacSettingsView: View {
    @ObservedObject private var machines = Machines.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mac: VirtualMac
    /// What it starts with, as this screen opened: a change offers Restart Now.
    private let startedWith: VirtualMac
    let start: (VirtualMac) -> Void
    @State private var confirmDelete = false
    @State private var confirmRestart = false
    @State private var movingExport = false

    init(mac: VirtualMac, start: @escaping (VirtualMac) -> Void) {
        _mac = State(initialValue: mac)
        startedWith = mac
        self.start = start
    }

    /// When what a Mac starts with takes effect: a Mac Instant Resume saved goes back into what it had (Restart Now
    /// starts it afresh at once).
    private static let appliesAt = "Changes apply the next time this Mac starts from cold, not when it picks up where it left off."

    /// Settings the Mac only takes when it starts.
    private var startChanged: Bool {
        mac.ramMB != startedWith.ramMB || mac.cpus != startedWith.cpus || mac.preset != startedWith.preset
            || mac.reportHostIdentity != startedWith.reportHostIdentity || mac.reportHostModelID != startedWith.reportHostModelID
    }

    /// A saved Mac to restart, and JIT on to start it.
    private var canRestart: Bool { startChanged && JITBootstrap.ready && InstantResume.hasSave(for: mac) }

    var body: some View {
        Form {
            Group {
                Section("Name") {
                    TextField("Name", text: $mac.name)
                        .submitLabel(.done)
                        .onSubmit(save)
                }
                ScreenSettings(mac: $mac, save: save)
                memory
                Section {
                    Stepper(value: Binding(get: { mac.cpus }, set: { mac.cpuCount = $0; save() }), in: DeviceProfile.cpuChoices) {
                        LabeledContent("CPUs", value: "\(mac.cpus)")
                    }
                } header: {
                    Text("Processors")
                } footer: {
                    Text(Self.appliesAt)
                }
                about
                if canRestart {
                    Section {
                        Button("Restart Now") { confirmRestart = true }
                    }
                }
                storage
                manage
            }
            .listRowBackground(Desk.card)
        }
        .deskForm()
        .navigationTitle(mac.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: save)
        .fileMover(isPresented: $movingExport, file: machines.lastExport) { result in
            switch result {
            case .success: machines.lastExport = nil
            case .failure(let error): machines.lastError = error.localizedDescription
            }
        }
        .confirmationDialog("Delete \(mac.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                machines.delete(mac.id)
                dismiss()
            }
        } message: {
            Text("Its disk is removed from this \(Device.name).")
        }
        .confirmationDialog("Restart \(mac.name)?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart", role: .destructive) {
                save()
                InstantResume.discard(for: mac)
                dismiss()
                start(mac)
            }
        } message: {
            Text("The Mac starts from cold. Anything not saved on it is lost.")
        }
    }

    private var memory: some View {
        let choices = Device.memoryChoices
        let gb = min(max(mac.ramMB / 1024, choices.lowerBound), choices.upperBound)
        let cap = Device.profile.guestCapMB == nil ? nil : "A Mac starts with up to \(choices.upperBound) GB on this \(Device.name)."
        let note = [cap, Device.memoryNote(gb), Self.appliesAt].compactMap { $0 }.joined(separator: " ")
        return Section {
            Stepper(value: Binding(get: { gb }, set: { mac.ramMB = $0 * 1024; save() }), in: choices) {
                LabeledContent("Memory", value: "\(gb) GB")
            }
        } header: {
            Text("Memory")
        } footer: {
            if !note.isEmpty { Text(note) }
        }
    }

    private var about: some View {
        Section {
            Toggle("Report this \(Device.name)", isOn: Binding(get: { mac.reportHostIdentity ?? false }, set: {
                mac.reportHostIdentity = $0
                if !$0 { mac.reportHostModelID = false }
                save()
            }))
            if mac.reportHostIdentity == true {
                Toggle("Also report a model identifier", isOn: Binding(get: { mac.reportHostModelID ?? false }, set: { mac.reportHostModelID = $0; save() }))
            }
        } header: {
            Text("About This Mac")
        } footer: {
            Text((mac.reportHostIdentity == true
                  ? "The Mac says it is \(Device.marketingName)\(Device.chipName.map { " with the \($0) chip" } ?? "")."
                    + (mac.reportHostModelID == true ? " Reports \(Device.snappedModelIdentifier(forOS: mac.osName)) so this Mac shows a matching icon. Experimental: macOS keys some hardware decisions off the model." : "")
                    + "\n\n"
                  : "")
                 + Self.appliesAt)
        }
    }

    private var storage: some View {
        Section("Storage") {
            VStack(spacing: 8) {
                LabeledContent("\(ByteText.string(UInt64(max(mac.bytesUsed, 0)))) used",
                               value: "of \(ByteText.string(UInt64(max(mac.diskBytes, 0))))")
                DeskBar(fraction: Double(max(mac.bytesUsed, 0)) / Double(max(mac.diskBytes, 1)))
            }
            .padding(.vertical, 4)
        }
    }

    private var manage: some View {
        Section {
            if let name = machines.exporting {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Exporting \(name)… keep Solstice open")
                    DeskBar(fraction: machines.exported)
                }
            } else {
                Button { machines.export(mac) } label: { Label("Export", systemImage: "square.and.arrow.up") }
            }
            if let folder = machines.lastExport {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved in Files, On My \(Device.name), Solstice, Exports, \(folder.lastPathComponent). Deleting Solstice deletes it too, so move it somewhere else first.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Move Out of Solstice…") { movingExport = true }
                }
            }
            Button("Delete this Mac", role: .destructive) { confirmDelete = true }
        } header: {
            Text("Manage")
        }
    }

    private func save() {
        if mac.name.trimmingCharacters(in: .whitespaces).isEmpty { mac.name = "Mac" }
        machines.update(mac)
    }
}
