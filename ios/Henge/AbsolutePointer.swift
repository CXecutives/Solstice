import UIKit

/// In a window (Stage Manager, or iPadOS's windowed apps) iPadOS won't lock the pointer, so the iPad's pointer
/// stays on screen and the Mac's has to follow it: over the Mac's screen, the pointer's place goes to the Mac's
/// absolute pointer (a USB tablet), and the iPad's own is hidden there (Trackpad's pointer style). Clicks and
/// scrolling still come from GameController.
enum AbsolutePointer {
    /// Where the Mac's screen is, in the session's coordinates (the window's); nil when it isn't on this
    /// screen (an external display) or there is no session.
    static var screen: CGRect?
    private static var lastInUse: Bool?

    static var inUse: Bool {
        let now = Device.isPad && screen != nil && !PointerLock.isLocked
        if now != lastInUse {
            lastInUse = now
            HengeLog.log("input", "absolute pointer: \(now ? "on (the pointer isn't locked)" : "off")")
        }
        return now
    }

    /// The iPad's pointer is at p: put the Mac's there too, if p is over the Mac's screen.
    static func move(to p: CGPoint) {
        guard inUse, let screen, screen.width > 0, screen.height > 0, screen.contains(p) else { return }
        henge_vm_pointer_at(Double((p.x - screen.minX) / screen.width), Double((p.y - screen.minY) / screen.height))
    }
}
