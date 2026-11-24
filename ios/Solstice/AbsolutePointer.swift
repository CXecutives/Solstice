import UIKit

/// In a window (Stage Manager, or iPadOS's windowed apps) iPadOS won't lock the pointer, so the iPad's pointer
/// stays on screen and the Mac's has to follow it: over the Mac's screen, the pointer's place goes to the Mac's
/// absolute pointer (a USB tablet), and the iPad's own is hidden there (Trackpad's pointer style). Clicks and
/// scrolling still come from GameController.
enum AbsolutePointer {
    /// Where the Mac's screen is, in the session's coordinates (the window's); nil when it isn't on this
    /// screen (an external display) or there is no session.
    static var screen: CGRect? { didSet { refresh() } }
    private static var lastInUse: Bool?
    private static let lock = NSLock()
    private static var inUseNow = false

    /// Main thread: whether the Mac's pointer follows the iPad's.
    static var inUse: Bool {
        let now = Device.isPad && screen != nil && !PointerLock.isLocked
        if now != lastInUse {
            lastInUse = now
            SolsticeLog.log("input", "absolute pointer: \(now ? "on (the pointer isn't locked)" : "off")")
        }
        lock.withLock { inUseNow = now }
        return now
    }

    /// Any thread: the same, as last worked out on the main thread (at `refresh`).
    static var inUseLately: Bool { lock.withLock { inUseNow } }

    /// Main thread: work out `inUse` again (the screen moved, or the pointer lock changed).
    static func refresh() { _ = inUse }

    /// The iPad's pointer is at p: put the Mac's there too, if p is over the Mac's screen.
    static func move(to p: CGPoint) {
        guard inUse, let screen, screen.width > 0, screen.height > 0, screen.contains(p) else { return }
        solstice_vm_pointer_at(Double((p.x - screen.minX) / screen.width), Double((p.y - screen.minY) / screen.height))
    }
}

/// Direct touch: a finger is the pointer, on the Mac's absolute pointer, wherever it touches the Mac's screen
/// (AbsolutePointer.screen, which follows the session's layout, zoomed or not).
enum DirectTouch {
    /// The Mac's screen is on this device, so a touch has a place on it.
    static var available: Bool { (AbsolutePointer.screen?.width ?? 0) > 0 }

    /// Where p (window coordinates) is on the Mac's screen, 0...1 on each axis; a touch beyond the screen's edge
    /// is at the edge.
    static func place(_ p: CGPoint, on screen: CGRect) -> CGPoint {
        CGPoint(x: min(max((p.x - screen.minX) / screen.width, 0), 1), y: min(max((p.y - screen.minY) / screen.height, 0), 1))
    }

    static func point(at p: CGPoint) {
        guard let screen = AbsolutePointer.screen, screen.width > 0, screen.height > 0 else { return }
        let at = place(p, on: screen)
        solstice_vm_pointer_at(Double(at.x), Double(at.y))
    }

    static func button(_ down: Bool) { solstice_vm_pointer_buttons(down ? 1 : 0) }
}
