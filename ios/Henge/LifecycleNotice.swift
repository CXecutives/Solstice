import SwiftUI

/// The session's card when something in the Mac's lifecycle has not ended in time (LifecycleWatchdog): what is
/// going on and a way out, instead of a spinner for ever.
struct LifecycleNotice: View {
    let stuck: LifecycleWatchdog.Stuck
    @ObservedObject var session: SessionController
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(stuck.title).font(.system(size: 17, weight: .semibold))
            Text(stuck.text).font(.system(size: 14)).foregroundStyle(Desk.dim)
            HStack(spacing: 18) {
                if stuck == .shutdownIgnored {
                    Button("Force Off") {
                        session.forceOff()
                        close()
                    }
                    .foregroundStyle(Desk.bad)
                    Button("Keep Running") { session.dismissStuck() }
                        .foregroundStyle(Desk.accentLight)
                } else {
                    Button("Quit Solstice") {
                        HengeLog.log("session", "quit by the owner: the Mac did not finish (\(stuck.logLine))")
                        HengeLog.flushNow()
                        exit(0)
                    }
                    .foregroundStyle(Desk.bad)
                    Button("Wait") { session.dismissStuck() }
                        .foregroundStyle(Desk.accentLight)
                }
            }
            .font(.system(size: 15, weight: .semibold))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Desk.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
