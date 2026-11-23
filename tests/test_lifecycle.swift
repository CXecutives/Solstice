import Foundation

/// The lifecycle watchdog's limits, the log stream's redaction and local-address check, and the env file's HV_ filter.
@main
struct LifecycleTests {
    static func main() {
        // Watchdog: nothing within the limits; each limit on its own; a stop hanging comes first.
        let W = LifecycleWatchdog.self
        precondition(W.check(stoppingFor: nil, queue: nil, shutdownFor: nil) == nil)
        precondition(W.check(stoppingFor: W.stopLimit - 1, queue: ("save", W.queueLimit - 1), shutdownFor: W.shutdownLimit - 1) == nil)
        precondition(W.check(stoppingFor: W.stopLimit + 1, queue: nil, shutdownFor: nil) == .stopping)
        precondition(W.check(stoppingFor: nil, queue: ("pause", W.queueLimit + 1), shutdownFor: nil) == .busy("pause"))
        precondition(W.check(stoppingFor: nil, queue: nil, shutdownFor: W.shutdownLimit + 1) == .shutdownIgnored)
        precondition(W.check(stoppingFor: W.stopLimit + 1, queue: ("save", W.queueLimit + 1), shutdownFor: W.shutdownLimit + 1) == .stopping)
        for stuck in [LifecycleWatchdog.Stuck.stopping, .busy("save"), .shutdownIgnored] {
            precondition(!stuck.title.isEmpty && !stuck.text.isEmpty && !stuck.text.contains("Henge"))
        }

        // Redaction: the container path (also as /private/var/...) and host names go; the rest stays.
        let home = "/private/var/mobile/Containers/Data/Application/0A1B2C3D"
        let line = "[  12.00ms][app] log file    : \(home)/Documents/henge.log and /var/mobile/Containers/Data/Application/0A1B2C3D/x"
        let red = LogPrivacy.redact(line, home: home)
        precondition(!red.contains("0A1B2C3D") && red.contains("~/Documents/henge.log") && red.contains("~/x"), red)
        let dns = LogPrivacy.redact("dns: updates.cdn-apple.com answered; Johns-iPhone.local up; blocks/s 12.5", home: home)
        precondition(!dns.contains("cdn-apple") && !dns.contains("Johns") && dns.contains("<host>") && dns.contains("blocks/s 12.5"), dns)
        precondition(LogPrivacy.redact("plain line, no names", home: home) == "plain line, no names")

        // Local addresses: private, link-local, loopback and .local; not public ones or other names.
        for local in ["10.0.0.5", "172.16.1.1", "172.31.255.1", "192.168.178.20", "169.254.3.4", "127.0.0.1", "::1",
                      "fe80::1", "[fd12:3456::1]", "my-mac.local", "localhost"] {
            precondition(LogPrivacy.isLocal(local), local)
        }
        for outside in ["8.8.8.8", "172.32.0.1", "192.169.0.1", "example.com", "2001:db8::1", "", "300.1.1.1"] {
            precondition(!LogPrivacy.isLocal(outside), outside)
        }

        // henge-env.txt: HV_ names only; comments, blanks and {Documents} as before.
        let text = """
        # a comment
        HV_HZ=30
        HV_TRACE = {Documents}/trace   # where it goes
        DYLD_INSERT_LIBRARIES=/tmp/x.dylib
        MallocStackLogging=1
        HV_=1
        hv_lower=1
        =nothing
        """
        let parsed = EnvOverrides.parse(text, documents: "/docs")
        precondition(parsed.accepted == ["HV_HZ": "30", "HV_TRACE": "/docs/trace"], "\(parsed.accepted)")
        precondition(parsed.refused == ["DYLD_INSERT_LIBRARIES", "MallocStackLogging", "HV_", "hv_lower"], "\(parsed.refused)")

        print("lifecycle: watchdog, log privacy and env overrides ok")
    }
}
