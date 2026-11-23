import Foundation

/// StartShape: a saved Mac resumes with the RAM and CPUs it was saved with, or is kept when that does not fit now;
/// a fresh start takes the settings within what fits.
@main
struct StartShapeTests {
    typealias S = StartShape.Shape

    static func main() {
        let roomy: (Int) -> UInt64 = { _ in 16384 }

        // No save: the setting, within what fits, in 512 MB steps.
        precondition(StartShape.plan(saved: nil, askedRAM: 4096, askedCPUs: 4, fits: roomy) == .boot(S(ramMB: 4096, cpus: 4)), "boot: as set")
        precondition(StartShape.plan(saved: nil, askedRAM: 4096, askedCPUs: 4, fits: { _ in 2900 }) == .boot(S(ramMB: 2560, cpus: 4)),
                     "boot: what fits, rounded down")
        precondition(StartShape.plan(saved: nil, askedRAM: 4096, askedCPUs: 4, fits: { _ in 1000 }) == .noRoom(fitsMB: 512), "boot: no room")

        // A save: its own shape, whatever the setting says now.
        let saved = S(ramMB: 2048, cpus: 2)
        precondition(StartShape.plan(saved: saved, askedRAM: 4096, askedCPUs: 4, fits: roomy) == .resume(saved), "resume: the save's shape")
        // The case that lost saves: what fits came out 1536 this launch (the save took storage, the address space is smaller).
        precondition(StartShape.plan(saved: saved, askedRAM: 2048, askedCPUs: 2, fits: { _ in 1536 }) == .saveDoesNotFit(saved: saved, fitsMB: 1536),
                     "save does not fit now: kept, not a cold boot")
        precondition(StartShape.plan(saved: saved, askedRAM: 2048, askedCPUs: 2, fits: { _ in 2048 }) == .resume(saved), "exactly fits")
        // What fits is asked for the save's CPUs (the engine's tables grow with them), not the setting's.
        var asked: [Int] = []
        _ = StartShape.plan(saved: saved, askedRAM: 2048, askedCPUs: 6, fits: { asked.append($0); return 16384 })
        precondition(asked == [2], "fits asked for the save's CPUs: \(asked)")
        print("start shape ok")
    }
}
