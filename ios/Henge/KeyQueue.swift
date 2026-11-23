import Foundation

/// What goes to the Mac's keyboard, in the order it was asked for. Keys go out at once unless a step before them
/// is still waiting (a paste waits for the helper to take the clipboard, slow typing waits between characters):
/// then they wait behind it, so nothing typed later overtakes it. Main thread only.
final class KeyQueue {
    typealias Key = (code: UInt16, down: Bool)
    /// A step that waits: it sends its own keys through `send`, which goes straight out.
    typealias Step = @MainActor (_ send: ([Key]) -> Void) async -> Void

    private enum Item {
        case keys([Key])
        case step(Step)
    }

    private let sink: (UInt16, Bool) -> Void
    private var waiting: [Item] = []
    private var busy = false

    init(sink: @escaping (UInt16, Bool) -> Void) { self.sink = sink }

    /// Nothing is waiting: keys go out as they are sent.
    var idle: Bool { !busy }

    /// Keys, now, or after what waits before them.
    func send(_ keys: [Key]) {
        if busy { waiting.append(.keys(keys)) } else { out(keys) }
    }

    /// A step that waits; what is sent after it goes out once it has finished.
    func wait(_ step: @escaping Step) {
        waiting.append(.step(step))
        guard !busy else { return }
        busy = true
        Task { @MainActor in await self.drain() }
    }

    private func out(_ keys: [Key]) {
        for key in keys { sink(key.code, key.down) }
    }

    @MainActor private func drain() async {
        while !waiting.isEmpty {
            switch waiting.removeFirst() {
            case .keys(let keys): out(keys)
            case .step(let step): await step { self.out($0) }
            }
        }
        busy = false
    }
}
