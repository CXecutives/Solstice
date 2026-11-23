import Foundation

/// DeviceProfile's table for a 4 GB, an 8 GB and a 16 GB device, and what holds for every row.
@main
struct DeviceProfileTests {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; print("FAIL: \(message)") }
    }

    static func main() {
        // iPad Air 4: 4 GB, 2 performance cores, signed without the increased memory limit or extended addressing.
        let air = DeviceProfile(physicalMB: 3_800, performanceCores: 2, memoryLimitMB: 3_000, extendedAddressing: false, isPad: true)
        check(air.row == DeviceProfile.rows[0], "4 GB is the first row")
        check(air.ramGB == 2 && air.cpus == 2, "4 GB: a 2 GB Mac on 2 CPUs")
        check(air.screenClass == .leanPad, "4 GB iPad: the lean screens")
        check(air.codeCacheMB == 384 && air.guestCapMB == 2048 && air.headroomMB == 340...700, "4 GB: cache, cap and headroom")
        check(air.jitMB(chosen: nil) == 384, "4 GB: the default region")

        // iPhone 16 Pro: 8 GB, 2 performance cores, the increased limit, no extended addressing (a free team).
        let phone = DeviceProfile(physicalMB: 7_680, performanceCores: 2, memoryLimitMB: 6_144, extendedAddressing: false, isPad: false)
        check(phone.ramGB == 3 && phone.cpus == 3, "8 GB phone: a 3 GB Mac on 3 CPUs")
        check(phone.screenClass == .phone, "8 GB phone: the phone screens")
        check(phone.codeCacheMB == 1024 && phone.guestCapMB == 3072 && phone.headroomMB == 600...1100, "8 GB: cache, cap and headroom")
        check(phone.jitMB(chosen: 1536) == 1024, "without extended addressing 1.5 GB is taken as 1 GB")
        check(phone.jitMB(chosen: 768) == 768, "a choice the signing allows is kept")
        check(phone.jitMB(chosen: 700) == 1024, "a value Settings never offers falls back to 1 GB")
        let phoneSmallLimit = DeviceProfile(physicalMB: 7_680, performanceCores: 2, memoryLimitMB: 3_000, extendedAddressing: false, isPad: false)
        check(phoneSmallLimit.codeCacheMB == 512, "under a 3.5 GB limit at most 512 MB")

        // iPad Pro M4: 16 GB, 4 performance cores, everything signed.
        let pro = DeviceProfile(physicalMB: 15_800, performanceCores: 4, memoryLimitMB: 12_000, extendedAddressing: true, isPad: true)
        check(pro.ramGB == 6 && pro.cpus == 5, "16 GB: a 6 GB Mac on one CPU past the P cores")
        check(pro.screenClass == .bigPad, "16 GB iPad: Retina by default")
        check(pro.codeCacheMB == 1536 && pro.guestCapMB == nil && pro.headroomMB == 1100...2100, "16 GB: cache, cap and headroom")
        check(pro.jitMB(chosen: nil) == 1536, "16 GB: the 1.5 GB region where it is signed for")
        let proUnsigned = DeviceProfile(physicalMB: 15_800, performanceCores: 4, memoryLimitMB: 12_000, extendedAddressing: false, isPad: true)
        check(proUnsigned.codeCacheMB == 1024, "without extended addressing 1 GB")

        // Every row: ordered, CPUs never past the P cores + 1, and the default cache one Settings offers.
        for (i, row) in DeviceProfile.rows.enumerated() {
            if i > 0 { check(row.belowMB > DeviceProfile.rows[i - 1].belowMB, "rows rise in memory") }
            for cores in 1...8 {
                let p = DeviceProfile(physicalMB: row.belowMB == .max ? 64_000 : row.belowMB - 1, performanceCores: cores,
                                      memoryLimitMB: 64_000, extendedAddressing: true, isPad: false)
                check(p.row == row, "a device just under a row's limit is in that row")
                check(p.cpus <= max(cores + 1, 3) && p.cpus <= row.maxCPUs, "CPUs within the row and the cores")
                check(DeviceProfile.codeCacheChoices.contains(p.codeCacheMB), "the default cache is a Settings choice")
            }
        }

        // A Mac's memory and CPUs: Settings offers only what boots, and suggests one of those.
        for row in DeviceProfile.rows {
            let p = DeviceProfile(physicalMB: row.belowMB == .max ? 64_000 : row.belowMB - 1, performanceCores: 2,
                                  memoryLimitMB: 64_000, extendedAddressing: true, isPad: false)
            let top = p.memoryChoicesGB.upperBound
            if let cap = row.guestCapMB { check(UInt64(top) << 10 == cap, "the largest memory choice is the boot cap") }
            else { check(top == DeviceProfile.largestMacGB, "no cap: the largest Mac") }
            check(p.memoryChoicesGB.contains(p.suggestedGB) && p.suggestedGB <= p.ramGB, "the suggested memory is a choice")
            check(p.cpus(chosen: nil) == p.cpus, "a Mac without its own CPU count gets the device's")
            for chosen in [-1, 0, 1, 4, 99] {
                let got = p.cpus(chosen: chosen)
                check(DeviceProfile.cpuChoices.contains(got), "a stored CPU count comes back as a choice")
                if DeviceProfile.cpuChoices.contains(chosen) { check(got == chosen, "a valid CPU count is kept") }
            }
        }

        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("device profile: all passed")
    }
}
