import Foundation

/// What a start gets: RAM and CPUs. A saved Mac goes back into exactly the shape it was saved with (its memory goes
/// into no other), whatever the settings say now; they apply once it starts afresh. A fresh start takes the settings
/// within what fits now. Pure: what fits comes in (GuestMemory.fits).
enum StartShape {
    struct Shape: Equatable {
        var ramMB: UInt64
        var cpus: Int
    }

    enum Plan: Equatable {
        case resume(Shape)                              // the save, in its own shape
        case boot(Shape)                                // no save: the settings, within what fits
        case saveDoesNotFit(saved: Shape, fitsMB: UInt64) // the save is kept; nothing starts now
        case noRoom(fitsMB: UInt64)                     // no save, and less than a Mac needs fits
    }

    static let minimumMB: UInt64 = 1024
    static let stepMB: UInt64 = 512

    /// fits(cpus): the most RAM that fits now beside the engine's tables for that many CPUs (storage, address space,
    /// the device's cap), in MB.
    static func plan(saved: Shape?, askedRAM: UInt64, askedCPUs: Int, fits: (Int) -> UInt64) -> Plan {
        if let saved {
            let room = fits(saved.cpus)
            return saved.ramMB <= room ? .resume(saved) : .saveDoesNotFit(saved: saved, fitsMB: room)
        }
        let ram = min(askedRAM, fits(askedCPUs)) / stepMB * stepMB
        return ram >= minimumMB ? .boot(Shape(ramMB: ram, cpus: askedCPUs)) : .noRoom(fitsMB: ram)
    }
}
