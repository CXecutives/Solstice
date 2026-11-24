import SwiftUI

/// Settings › When You Leave: staying awake in the background, picking up where the Mac was, and starting the last Mac
/// at launch.
struct LifecycleSettings: View {
    @AppStorage(SettingKey.keepAwake.rawValue) private var keepAlive = SettingDefault.keepAwake
    @AppStorage(SettingKey.instantResume.rawValue) private var instantResume = SettingDefault.instantResume
    @AppStorage(SettingKey.autoStartMac.rawValue) private var autoStart = SettingDefault.autoStartMac

    var body: some View {
        Section {
            Toggle("Keep Solstice Awake", isOn: $keepAlive)
            Toggle("Resume Where You Left Off", isOn: $instantResume)
            Toggle("Start the Last Mac at Launch", isOn: $autoStart)
        } header: {
            Text("When You Leave")
        } footer: {
            Text("The Mac pauses while you are away. Kept awake, Solstice is far less likely to be closed by iOS. After \(Int(InstantResume.saveAfter)) seconds the paused Mac is saved, so it picks up where it was even if iOS closes Solstice.")
        }
    }
}
