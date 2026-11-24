import SwiftUI

/// Settings › When You Leave: staying awake in the background, picking up where the Mac was, and starting the last Mac
/// at launch.
struct LifecycleSettings: View {
    @AppStorage(SettingKey.keepAwake.rawValue) private var keepAlive = SettingDefault.keepAwake
    @AppStorage(SettingKey.instantResume.rawValue) private var instantResume = SettingDefault.instantResume
    @AppStorage(SettingKey.autoStartMac.rawValue) private var autoStart = SettingDefault.autoStartMac

    var body: some View {
        Section {
            Toggle("Keep Solstice awake", isOn: $keepAlive)
            Toggle("Resume where you left off", isOn: $instantResume)
            Toggle("Start the last Mac when Solstice opens", isOn: $autoStart)
        } header: {
            Text("Instant Resume")
        } footer: {
            Text("When you leave Solstice, the Mac pauses, so its sound stops. After \(Int(InstantResume.saveAfter)) seconds it is saved to storage, and opening it again picks up where it was in a few seconds, even after iOS closes Solstice. Keeping Solstice awake makes it much less likely that iOS closes it.")
        }
    }
}
