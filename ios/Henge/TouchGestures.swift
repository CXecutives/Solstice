import Foundation

/// The touch surface's clicks, from fingers touching, moving and lifting: a pure state machine, so it can be
/// tested. Times are the touches' own (seconds); the surface calls `tick` at `deadline`.
///
/// - A tap is a left click. The button goes down at the lift and comes up `tapDrag` later, so touching again
///   in that time and moving drags (tap-and-drag), and tapping again is a double click.
/// - A finger held still for `hold` presses the button; moving then drags; lifting lets go.
/// - A quick two-finger tap is a right click; a quick four-finger tap reveals the session's controls.
/// - Moving the pointer is no click: sticky modifiers stay for the next one (`modifiersUsed` marks clicks).
struct TouchGestures {
    struct Timing: Equatable {
        var hold: TimeInterval = 0.4     // a finger held still this long presses the button
        var tap: TimeInterval = 0.3      // a touch shorter than this is a tap
        var tapDistance: Double = 8      // how far (points) a tap may travel
        var tapDrag: TimeInterval = 0.25 // after a tap, touching again within this drags; 0: a tap clicks at once
    }

    enum Action: Equatable {
        case press(Int32)   // a mouse button goes down: 0 left, 1 right
        case release(Int32)
        case click(Int32)   // down and up
        case reveal         // four fingers tapped
        case haptic
        case modifiersUsed  // a click ended: modifiers held for one use let go
    }

    var timing: Timing
    private(set) var fingers = 0
    private var started: TimeInterval = 0
    private var travelled: Double = 0
    private var mostFingers = 0
    private var holdAt: TimeInterval?
    private var releaseAt: TimeInterval? // a tap's button comes up then, unless a touch comes first
    private var buttonDown = false
    private var dragging = false   // a hold or a tap-drag: the button stays down until the lift
    private var continuing = false // this touch came while a tap's button was still down

    init(timing: Timing = Timing()) { self.timing = timing }

    /// When `tick` has something to do, if anything.
    var deadline: TimeInterval? { [holdAt, releaseAt].compactMap { $0 }.min() }

    /// Fingers went down; `count` are down now.
    mutating func touched(count: Int, at t: TimeInterval) -> [Action] {
        var out: [Action] = []
        if fingers == 0 { // a new gesture
            started = t
            travelled = 0
            mostFingers = 0
            continuing = false
            if let r = releaseAt {
                releaseAt = nil
                if t <= r { continuing = buttonDown } else { out += letGo() }
            }
        }
        fingers = count
        mostFingers = max(mostFingers, count)
        if count >= 2 {
            holdAt = nil
            if buttonDown { out += letGo() } // a drag becomes a multi-finger gesture
            dragging = false
            continuing = false
        } else if !dragging {
            holdAt = t + timing.hold
        }
        return out
    }

    /// The fingers moved this far (points) in all.
    mutating func moved(by distance: Double, at t: TimeInterval) -> [Action] {
        travelled += distance
        guard travelled >= timing.tapDistance else { return [] }
        holdAt = nil // moving: pointing, a gesture or a drag, not a tap or a press-to-drag
        if continuing && fingers == 1 { dragging = true } // tap-and-drag: the button is down already
        return []
    }

    /// Fingers lifted; `remaining` are still down.
    mutating func lifted(remaining: Int, at t: TimeInterval) -> [Action] {
        fingers = remaining
        guard remaining == 0 else { return [] } // fingers still down: the gesture goes on
        holdAt = nil
        let quick = t - started < timing.tap
        let still = travelled < timing.tapDistance
        var out: [Action] = []
        if dragging {
            dragging = false
            continuing = false
            out += letGo()
        } else if continuing {
            continuing = false
            if quick && still && mostFingers == 1 { // a second tap: a double click
                buttonDown = false
                out.append(.release(0))
                out += tap(at: t)
            } else {
                out += letGo()
            }
        } else if quick && still {
            if mostFingers == 1 { out += tap(at: t) }
            else if mostFingers == 2 { out += [.click(1), .haptic, .modifiersUsed] }
        }
        if mostFingers >= 4, travelled < timing.tapDistance * 3, t - started < timing.tap * 2 { out.append(.reveal) }
        return out
    }

    /// Time passed: a tap's button comes up, or a held finger presses it.
    mutating func tick(at t: TimeInterval) -> [Action] {
        var out: [Action] = []
        if let r = releaseAt, t >= r, fingers == 0 {
            releaseAt = nil
            out += letGo()
        }
        if let h = holdAt, t >= h {
            holdAt = nil
            if fingers == 1 && travelled < timing.tapDistance && !dragging {
                dragging = true
                continuing = false
                if !buttonDown {
                    buttonDown = true
                    out.append(.press(0))
                }
                out.append(.haptic)
            }
        }
        return out
    }

    /// The surface went away: nothing stays pressed.
    mutating func cancel() -> [Action] {
        fingers = 0
        holdAt = nil
        releaseAt = nil
        dragging = false
        continuing = false
        return letGo()
    }

    private mutating func tap(at t: TimeInterval) -> [Action] {
        guard timing.tapDrag > 0 else { return [.click(0), .haptic, .modifiersUsed] }
        buttonDown = true
        releaseAt = t + timing.tapDrag
        return [.press(0), .haptic]
    }

    private mutating func letGo() -> [Action] {
        guard buttonDown else { return [] }
        buttonDown = false
        return [.release(0), .modifiersUsed]
    }
}
