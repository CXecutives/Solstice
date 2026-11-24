import SwiftUI

/// Settings › About: the app's version, where it comes from, and its source.
struct AboutSection: View {
    static let source = URL(string: "https://github.com/CXecutives/Solstice")!
    static let origin = "Based on Henge by Leviidev, GPL-2.0-or-later"

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Section {
            LabeledContent("Version", value: version)
            Link(destination: Self.source) {
                LabeledContent("Source Code") { Image(systemName: "arrow.up.right").foregroundStyle(.secondary) }
            }
            .foregroundStyle(Desk.text)
        } header: {
            Text("About")
        } footer: {
            Text(Self.origin)
        }
    }
}
