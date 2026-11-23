import SwiftUI

/// A Mac's screen: one preset (MacScreen), each with what it looks like on this device and what it costs the Mac.
struct ScreenSettings: View {
    @Binding var mac: VirtualMac
    let save: () -> Void

    var body: some View {
        let offered = MacScreen.offered(Device.screenFacts)
        let recommended = offered.first { $0.preset == .recommended }?.screen ?? MacScreen.size(.recommended, Device.screenFacts)
        let chosen: ScreenPreset = (offered.contains { $0.preset == mac.preset }) ? mac.preset : .recommended
        Section {
            ForEach(offered) { item in
                Button {
                    mac.screenPreset = item.preset
                    save()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.preset.title).foregroundStyle(Desk.text)
                            Text(MacScreen.line(item.screen, against: recommended))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if item.preset == chosen {
                            Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Desk.accentLight)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item.preset == chosen ? .isSelected : [])
            }
        } header: {
            Text("Screen")
        } footer: {
            Text("\(mac.screen.width) × \(mac.screen.height) pixels. Crisp shows every pixel exactly.")
        }
    }
}
