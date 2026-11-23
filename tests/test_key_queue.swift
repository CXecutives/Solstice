import Foundation

/// KeyQueue: keys sent after a step that waits (a paste waiting for the helper) go out after it, never before.
@main @MainActor
struct KeyQueueTests {
    static func settle(_ q: KeyQueue) async {
        let until = Date().addingTimeInterval(5)
        while !q.idle && Date() < until { try? await Task.sleep(nanoseconds: 5_000_000) }
        precondition(q.idle, "the queue never finished")
    }

    static func main() async {
        var got: [String] = []
        let q = KeyQueue { code, down in got.append("\(code)\(down ? "+" : "-")") }

        // Nothing waiting: keys go out at once.
        q.send([(30, true), (30, false)])
        precondition(got == ["30+", "30-"], "idle: at once, got \(got)")

        // A paste: the clipboard is handed over and acknowledged after a while, then ⌘V. "a" typed meanwhile waits.
        got = []
        q.wait { _ in
            try? await Task.sleep(nanoseconds: 50_000_000)
            got.append("clipboard")
        }
        q.send([(125, true), (47, true), (47, false), (125, false)]) // ⌘V
        q.send([(30, true), (30, false)])                              // "a", typed right after
        precondition(got.isEmpty, "keys went out before the paste: \(got)")
        await settle(q)
        precondition(got == ["clipboard", "125+", "47+", "47-", "125-", "30+", "30-"], "paste then type: \(got)")

        // A step sends its own keys straight out, between its waits; what comes after waits for all of it.
        got = []
        q.wait { send in
            send([(16, true), (16, false)])
            try? await Task.sleep(nanoseconds: 10_000_000)
            send([(17, true), (17, false)])
        }
        q.send([(18, true), (18, false)])
        await settle(q)
        precondition(got == ["16+", "16-", "17+", "17-", "18+", "18-"], "slow typing then a key: \(got)")

        // Two waiting steps in a row keep their order.
        got = []
        q.wait { _ in try? await Task.sleep(nanoseconds: 20_000_000); got.append("first") }
        q.wait { _ in got.append("second") }
        q.send([(1, true)])
        await settle(q)
        precondition(got == ["first", "second", "1+"], "two steps: \(got)")

        // Idle again: at once.
        got = []
        q.send([(2, true)])
        precondition(got == ["2+"], "idle again: \(got)")
        print("key queue ok")
    }
}
