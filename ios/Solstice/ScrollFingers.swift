import UIKit

/// Two fingers on the Mac's emulated Magic Trackpad 2, driven by a hardware trackpad's scroll. Finger ids 12...15
/// stay clear of the touchscreen's 1...5. The two calls GameController makes per sample are merged into one frame,
/// so the guest sees evenly spaced samples and works out the fingers' speed (and the momentum after) correctly.
///
/// The emulated pad is only so big, and a long swipe runs off it. Lifting the fingers there at speed would start
/// macOS's momentum, and putting them down again at once reads as a second flick during it, which macOS answers by
/// scrolling faster and faster. So the fingers start at the edge they move away from, and at the far edge they
/// first hold still for a moment (the motion meanwhile is kept), lift with no speed left, start again from the
/// other edge, and the kept motion is paid out over the next samples.
///
/// Everything runs on `queue` (HardwareMouse's), the timers too.
final class ScrollFingers {
    static let unitsPerPoint: Float = 40
    private let queue: DispatchQueue

    init(queue: DispatchQueue) { self.queue = queue }
    /// Two pairs, used in turn: a pair lifted at an edge isn't put down again under the same ids a moment later.
    private static let pairs: [(Int32, Int32)] = [(14, 15), (12, 13)]
    private var pair = 0
    private var ids: (Int32, Int32) { Self.pairs[pair] }
    private var eventsLogged = 0
    private static let sensorW: Float = 8134, sensorH: Float = 5206
    /// Where the fingers may go: clear of the pad's edges, and well clear of the bottom, where a real
    /// Magic Trackpad expects a resting thumb and macOS treats touches differently.
    private static let minX: Float = sensorW * 0.12, maxX: Float = sensorW * 0.88
    private static let minY: Float = sensorH * 0.15, maxY: Float = sensorH * 0.70
    private static let spread: Float = 1100 // the fingers' distance apart, about two centimetres
    /// No sample for this long: the fingers lifted without the closing (0, 0).
    private static let idleLift: TimeInterval = 0.12
    private static let mergeDelay: TimeInterval = 0.003
    /// How long the fingers rest at an edge before lifting, so macOS sees them stopped.
    private static let rest: TimeInterval = 0.05

    private var down = false
    private var x: Float = 0, y: Float = 0
    private var pendingX: Float = 0, pendingY: Float = 0
    private var flushScheduled = false
    private var idle: DispatchWorkItem?
    /// Resting at an edge until this time; motion meanwhile goes to the backlog.
    private var restingUntil: CFTimeInterval?
    private var backlogX: Float = 0, backlogY: Float = 0

    private static func now() -> UInt32 { UInt32(truncatingIfNeeded: Int(CACurrentMediaTime() * 1000)) }

    func move(dx: Float, dy: Float) {
        pendingX += dx
        pendingY += dy
        if !flushScheduled {
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + Self.mergeDelay) { [weak self] in self?.flush() }
        }
        idle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.end() }
        idle = work
        queue.asyncAfter(deadline: .now() + Self.idleLift, execute: work)
    }

    /// The gesture is over: lift both fingers, and macOS carries the scroll on as it would on a Mac.
    func end() {
        idle?.cancel()
        idle = nil
        // Whatever was held back at an edge is dropped: replaying it now would be a jump.
        restingUntil = nil
        backlogX = 0
        backlogY = 0
        flush()
        lift()
    }

    private func flush() {
        flushScheduled = false
        var dx = pendingX, dy = pendingY
        pendingX = 0
        pendingY = 0
        guard dx != 0 || dy != 0 || restingUntil != nil else { return }
        let ts = Self.now()

        if let until = restingUntil {
            backlogX += dx
            backlogY += dy
            if CACurrentMediaTime() < until {
                frame(ts) // still: the guest's idea of the fingers' speed falls to nothing
                return
            }
            restingUntil = nil
            lift()
            place(towardX: backlogX, towardY: backlogY)
            dx = 0
            dy = 0
        }
        // Pay out what was held back, a share each sample, on top of the new motion.
        if backlogX != 0 || backlogY != 0 {
            let shareX = backlogX * 0.35, shareY = backlogY * 0.35
            dx += shareX
            dy += shareY
            backlogX -= shareX
            backlogY -= shareY
            if abs(backlogX) < 1 && abs(backlogY) < 1 { backlogX = 0; backlogY = 0 }
        }
        guard dx != 0 || dy != 0 else { return }
        if !down { place(towardX: dx, towardY: dy) }
        let nx = x + dx, ny = y + dy
        if nx - Self.spread / 2 < Self.minX || nx + Self.spread / 2 > Self.maxX || ny < Self.minY || ny > Self.maxY {
            // The edge: rest here, keeping this sample's motion for after.
            restingUntil = CACurrentMediaTime() + Self.rest
            log("edge at \(Int(x)),\(Int(y)): resting")
            backlogX += dx
            backlogY += dy
            frame(ts)
            return
        }
        x = nx
        y = ny
        frame(ts)
    }

    private func frame(_ ts: UInt32) {
        solstice_vm_touch(ids.0, 1, Int32(x - Self.spread / 2), Int32(y), ts)
        solstice_vm_touch(ids.1, 1, Int32(x + Self.spread / 2), Int32(y), ts)
        solstice_vm_touch_frame(ts)
    }

    /// Fingers down at the edge the motion leads away from, so a swipe has the whole pad to travel.
    private func place(towardX: Float, towardY: Float) {
        let lowX = Self.minX + Self.spread / 2, highX = Self.maxX - Self.spread / 2
        let lowY = Self.minY, highY = Self.maxY
        if abs(towardY) >= abs(towardX) {
            y = towardY > 0 ? lowY : highY
            x = Self.sensorW / 2
        } else {
            x = towardX > 0 ? lowX : highX
            y = Self.sensorH / 2
        }
        let ts = Self.now()
        log("down \(ids.0)/\(ids.1) at \(Int(x)),\(Int(y))")
        solstice_vm_touch(ids.0, 0, Int32(x - Self.spread / 2), Int32(y), ts)
        solstice_vm_touch(ids.1, 0, Int32(x + Self.spread / 2), Int32(y), ts)
        down = true
    }

    private func lift() {
        guard down else { return }
        let ts = Self.now()
        solstice_vm_touch(ids.0, 2, 0, 0, ts)
        solstice_vm_touch(ids.1, 2, 0, 0, ts)
        log("up \(ids.0)/\(ids.1) at \(Int(x)),\(Int(y))")
        down = false
        pair = (pair + 1) % Self.pairs.count
    }

    private func log(_ text: String) {
        guard eventsLogged < 40 else { return }
        eventsLogged += 1
        SolsticeLog.log("input", "scroll fingers: \(text)")
    }
}
