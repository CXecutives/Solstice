import SwiftUI

/// Settings for a Mac's lifecycle, one small section each, for SettingsView to place: picking up where the Mac was,
/// staying awake in the background, and starting the last Mac at launch.

struct ResumeSettingsSection: View {
    @AppStorage(InstantResume.key) private var instantResume = true

    var body: some View {
        Section("Instant Resume") {
            Toggle("Resume where you left off", isOn: $instantResume)
            Text("When you have been away from Solstice for \(Int(InstantResume.saveAfter)) seconds, the paused Mac is saved to storage, and opening it again picks up where it was in a few seconds, even after iOS closes Solstice. The save is about the size of the Mac's memory in use, compressed. The Mac pauses while Solstice is in the background, so its sound stops.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .listRowBackground(Desk.card)
    }
}

struct KeepAwakeSettingsSection: View {
    @AppStorage(KeepAlive.key) private var keepAlive = true

    var body: some View {
        Section("In the Background") {
            Toggle("Keep Solstice awake", isOn: $keepAlive)
            Text("While a Mac is open or macOS is installing, Solstice stays awake when you leave it or the screen locks, so iOS is much less likely to close it and an install goes on. A running Mac waits, paused, until you are back. Solstice plays silence while it is away to do this; other apps' audio is not interrupted.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .listRowBackground(Desk.card)
    }
}

struct AutoStartSettingsSection: View {
    @AppStorage(AutoStart.key) private var autoStart = true

    var body: some View {
        Section("At Launch") {
            Toggle("Start the last Mac", isOn: $autoStart)
            Text("Once JIT is on, Solstice starts the Mac you used last. If it does not get going twice in a row, Solstice says so and waits until you start one yourself.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .listRowBackground(Desk.card)
    }
}
