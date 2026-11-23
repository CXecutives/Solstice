import UIKit
import GameController

/// Asks iPadOS to hand the pointer over, so a trackpad or mouse drives only the Mac's pointer. It does
/// that only for an app filling the screen. SwiftUI has no way to ask, so the answer is added to the
/// class of the window's root view controller, which is who iPadOS asks.
enum PointerLock {
    private static var wanted = false
    private static var patched: Set<ObjectIdentifier> = []

    static func set(_ on: Bool) {
        wanted = on
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            guard let root = window.rootViewController else { continue }
            let kind: AnyClass = type(of: root)
            if patched.insert(ObjectIdentifier(kind)).inserted {
                let answer: @convention(block) (UIViewController) -> Bool = { vc in wanted && fillsScreen(vc.viewIfLoaded?.window) }
                class_replaceMethod(kind, #selector(getter: UIViewController.prefersPointerLocked), imp_implementationWithBlock(answer), "B@:")
            }
            root.setNeedsUpdateOfPrefersPointerLocked()
            if window.isKeyWindow {
                let ask = on && fillsScreen(window)
                if ask != lastAsked {
                    lastAsked = ask
                    HengeLog.log("input", "pointer lock \(ask ? "asked for" : "not asked for"): window \(Int(window.bounds.width))x\(Int(window.bounds.height)) of \(Int(window.screen.bounds.width))x\(Int(window.screen.bounds.height))")
                }
            }
        }
    }
    private static var lastAsked: Bool?

    /// Only an app that fills the screen asks for the lock. In a Stage Manager window iPadOS can grant it and still
    /// move its hidden pointer to the screen's edges, bringing out the stage strip and the dock at every move; there
    /// the Mac's pointer follows the iPad's instead (AbsolutePointer).
    static func fillsScreen(_ window: UIWindow?) -> Bool {
        guard let window else { return false }
        let mine = window.bounds.size, screen = window.screen.bounds.size
        return abs(mine.width - screen.width) < 1 && abs(mine.height - screen.height) < 1
    }

    /// Whether iPadOS has the pointer locked to the Mac right now.
    static var isLocked: Bool {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .contains { $0.activationState == .foregroundActive && $0.pointerLockState?.isLocked == true }
    }

    /// iPadOS only locks the pointer to an app that fills the screen: in a window (Stage Manager, or iPadOS 26's windows)
    /// the request is ignored and the system pointer stays separate from the Mac's (#18). An iPhone never locks it, and
    /// its apps are always full screen, so the hint is for iPad only.
    static var refused: Bool {
        guard Device.isPad, wanted, GCMouse.current != nil else { return false }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
        let full = scenes.contains { $0.windows.contains { $0.isKeyWindow && fillsScreen($0) } }
        return full && !scenes.contains { $0.pointerLockState?.isLocked == true }
    }
}
