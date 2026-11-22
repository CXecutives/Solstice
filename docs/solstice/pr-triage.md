# Upstream-PR-Triage und Konfliktkarte

> Agenten-Bericht vom 22.11.2026 (Analyse von Henge main 7b55730). Zeilenangaben beziehen sich auf diesen Stand. Wo PLAN.md abweicht, gilt PLAN.md.

## Henge fork: PR triage, CI and high-hold checks, Husk, and cherry-pick order

**Bottom line**
- **CI claim: confirmed.** The `#168` fix is right, but the only proven-green CI run used a slightly stronger variant of it.
- **#211/#221: confirmed, but it does not affect a free-account install.** On a free account the high hold never succeeds, so `#211` does nothing there. It is cheap to carry and matters once you sign with a paid account.
- **Husk:** main has had no build-relevant change since 5 Nov. Pin it anyway.
- **Base:** use main at `7b55730`, not tag 0.3.
- **Limits of this check:** "mergeable" is GitHub's answer against main. The conflicts between PRs are worked out from overlapping diff ranges, not from test merges, because the clone stayed read-only.

### 1. Checks

**CI.** Run 43746224513 (15 Nov, `7b55730`) fails in step 12 "Package Henge.ipa":
- The error is `NSURL.h:12: fatal error: 'Foundation/NSURLHandle.h' file not found` with iPhoneOS27.1.sdk.
- Cause: the Xcode pre-build step builds `build/tl-samples.dmg` (`ios/project.yml:113`). Its rule (`Makefile:191-192`) runs `make -C tl`, which compiles for macOS with `xcrun clang -target arm64-apple-macos13` (`tl/Makefile:4-6`). That inherits Xcode's iOS `SDKROOT`, and NSURLHandle.h does not exist in the iOS SDK.
- The last green run was 42726403841 on 10 Nov, 42 commits before tag 0.3. 0.3 itself never ran through GitHub CI.
- `#168` adds `env -u SDKROOT` in front of that sub-make, which is the correct root fix.
- Proof from forks:
  - `dajgduyqwgdq/Henge` run 44008706350 is green in every step, including IPA and TIPA. It is `7b55730` + the mouse fix from `#209` + `env -u SDKROOT -u IPHONEOS_DEPLOYMENT_TARGET`. The extra `-u` matches the existing henge-agent rule at `Makefile:53`.
  - `Chenyu550/Henge` is also green with that variant.
  - I found no green run of `#168` exactly as written. zightning-code's run with it plus many other PRs failed, and the cause is hidden because `package_ipa.sh` swallows the build log.
- **So: take `#168` and add `-u IPHONEOS_DEPLOYMENT_TARGET`,** and add a step that uploads `ios/build/DerivedData.buildlog` when the build fails.

**#211/#221 (`ios/Henge/Native/henge-ios-jit.c:525-589`).**
- `henge_ios_hold_high()` reserves three blocks at fixed addresses (`VM_FLAGS_FIXED`) at 0x7000000000 and above: 40 + 16 + 4 GB.
- That address range only exists with extended-virtual-addressing (EVA). Every report of the bug is from an EVA-signed device: `#211` (M5, development-signed), `#221` (paid team), `#121` (Duo).
- A free account has no EVA:
  - `ios/Henge/Henge.personal.entitlements` says a personal team can't sign it.
  - Free-account logs say `extended addressing: no; … largest mapping 5120` (`#11`) and "free Apple ID" (`#113`).
- So on your iPhone the fixed-address calls fail and `g_high_hold[]` stays empty. The fallback that moves the JIT view to 0x7A00000000 only runs when `g_high_hold[0]` is set (around lines 771-778).
- **Result: main behaves like 0.3 on a free account.** `#211` becomes relevant on a paid signature, for example the iPad Pro later.
- Related: the patched StikJIT for addresses above 0xFFFFFFFFF (`ci/build-stikjit.sh`) only runs in Bitrise. The GitHub workflow ships Husk's unpatched copy, which also only matters with EVA.

**Husk.**
- The workflow checks out `Leviidev/Husk` main with no `ref:` (`build-henge.yml:45-49`).
- It builds libffi, glib and libslirp (`build_ios.sh`) and the pairing library (`build_rppairing_ios.sh`). It copies Husk's vendored `src/app/Frameworks/StikJIT.xcframework`, last changed 5 Oct (`ios/scripts/fetch_deps.sh`).
- Husk HEAD is `29abb51` (11 Nov). The three commits after `afe83d4` only touch `altsource.json` and `tools/update-altsource.py`, and compare `3.4...main` changes only those files.
- **Pin `ref: 3.4` (or `29abb512…`).** For the build it is identical to main.

### 2. Ranked must-have and high-value PRs

"Merge" is GitHub's verdict against main (M = mergeable). "Collides with" means overlapping or adjacent diff ranges.

| # | PR | What it does | Size / files | Merge | Collides with | Tested on real hardware |
|---|---|---|---|---|---|---|
| 1 | **168** | Mac sample programs built without Xcode's iOS SDKROOT (CI fix) | +1/-1 · Makefile | M | none (#176/#127/#32 touch other Makefile lines) | Author: Xcode 27.2 build ran on an iPad. CI green only with the `-u IPHONEOS_DEPLOYMENT_TARGET` variant |
| 2 | **214** | Stays alive in the background (silent audio), gives memory back via balloon under pressure, caps 3 GB Mac + 1 GB code cache on ≤8 GB devices, jetsam logging | +237/-5 · 12 files (Machines, henge-ios-jit.c, henge-vm.c/h, Settings, Session, EngineTuning, JITBootstrap, KeepAlive…) | M | #211 (adjacent in Machines.swift), #81 (SettingsView) | iPad Pro M4 8 GB in a combined build: still running at 8 min vs killed at 4.4. iPhone 12 GB. This exact branch not soaked |
| 3 | **166** | Built-in JIT uses only a RemotePairing port that is open on this device (fails today when another Apple device is on the same Wi-Fi) | +22/-6 · JITSetup, HengeJITHelper, RSDPortResolver | M | **#130 (duplicate)**, #192 | iPad iOS 26 (TXM). oliverames saw the same bug on an iPhone (it picked an Apple TV) |
| 4 | **207** | Fixes the "signal 4 in translated code" crash: GPU surfaces over 64 MB use two-level page lists; also unmap ordering and virtio code invalidation | +176/-9 · 9 files (core/classify, dispatch, machine, pvg_lite, pvg_metal, virtio) | M | #187 (same root fix), #161, #186/#218 | iPhone Duo and iPad Pro M4 in the author's build. Exact branch only compiled |
| 5 | **188** | Fixes the GPU delete-task bug (AGX crash, #102) and keeps compiled Metal pipelines across launches (`HV_PVG_ARCHIVE=0` turns it off) | +249/-26 · pvg_metal.m | M | #216/#82 (top of the file), #173 | Each half on iPhone Duo. Combined branch untested |
| 6 | **142** | Aux disk supports discard, so macOS clears its panic record (no repeat panic dialog at every boot) | +77/-1 · virtio_blk, disk.c/h, test | M | none | iPhone, macOS 27.2 |
| 7 | **211** | Releases the 60 GB Mac-apps hold before sizing guest RAM | +14 · Machines, henge-ios-jit.c/h | M | **#169, #121 (duplicates)**, #214 | iPad Pro M5, full install and boot (EVA). No-op on a free account |
| 8 | **183** | Installer releases its machine, so a new Mac starts without quitting Henge (no relaunch, no second JIT setup) | +131/-24 · install.c/h, libusb_shim, usb_host.h, henge-vm.c, test | **Conflicting** (one hunk: merged #205 inserted code at the same spot near henge-vm.c:38; keep both) | #121 (test file) | iPhone: macOS 27.2 install, then auto-start |
| 9 | 137 | Missing macOS icons drawn (corrects Metal's last-row length rule) | +6/-3 · pvg_metal.m | M | none | iPhone Duo: 20 apps, 0 failed draws |
| 10 | 209 | Pointer no longer drifts while scrolling (each report carries both axes) | +25/-4 · host/vm.c | M | #191, #123 (close, separate) | iPad Pro M4 in the author's build. Same commit built green in a fork |
| 11 | 215 | "Size of Things": smaller logical screen so text and buttons are bigger on a phone | +32/-5 · MacSettings, Machines, Session | M | #141, #190 (separate) | iPhone |
| 12 | 109 | Pointer drawn where it clicks at scaled resolutions | +22/-2 · pvg_lite.c/h, pvg_metal.m | M | **#216 (duplicate)**, #173 | iPhone Duo |
| 13 | 141 | CPU stepper goes up to the active core count (max 8) and names P/E cores; Install-tab memory note | +38/-8 · 4 files | M | Hardware.swift (Device enum only) | iPhone A20 Pro (oliverames) |
| 14 | 98 | Scroll-speed slider also drives touch two-finger scrolling; finer wheel steps | +100/-35 · Hardware, ScrollMotion, Session, Settings, Trackpad | M | **#167 (same function)**, #170, #99, #123 | iPad Air M3, iPadOS 27.0.1 |
| 15 | 99 | Opt-in clipboard sync device→Mac; Paste button always visible | +53/-22 · share.c, Session, Sharing | M | #98 (2 adjacent SessionView hunks), #74/#76/#77 | iPad Air M3 (on 0.3) |
| 16 | 208 | Keyboard asks iOS for an ASCII-capable layout; key that switches the Mac's input source | +22 · Input.swift | M | #191 | Compiled only |
| iPad | 170 | Trackpad click no longer nudges the pointer | +60/-1 · Hardware.swift | M | #98, #167 | iPad, iPadOS 26, Magic Keyboard |
| iPad | 167 | Two-finger trackpad scroll arrives as real trackpad fingers (smooth, momentum) | +173/-19 · Hardware.swift | M | **#98** | iPad, iPadOS 26 |
| iPad | 123 | Stage Manager: one pointer via an absolute USB pointer on xHCI port 3 | +165/-15 · 9 files | M | #32/#90/#191 (each adds a USB device), #98/#170 | iPad Pro M1 on 0.3. Rebase onto main compiled only |

**Nice-to-have (later, after testing on the device):**
- Performance, each needs an A/B run on the device: #176 (untested on a device), #80 and #81 (only measured on a Mac host; #81 just flips an existing toggle), #186 (draft), #218 (draft; also switches VBLANK on, see #161 below).
- #187 (draft; fixes blank Safari pages, only if you use a macOS 27 guest).
- #92 (no device test, and hashing the full surface costs CPU).
- #126 (wakes the display on pointer input; the RAM scan it adds is riskier).
- #127 (keep the 64 GB default), #139.
- File sharing (share.c): #74, #76, #77, #88.
- #91, #32 (large; competes for USB port 3), #82 (competes with #190), #173, #178, #192 (parts), #206, #217 (not tested with a real mouse).
- Alternatives to picks above: #216, #130, #169, #121.
- #72, #85, #86, #115, #144, #193.

**Skip:**
- #73: redundant, fix `f0eec63` per oliverames.
- #78: no effect on iOS. The app always passes `jit_bytes`; the `host/vm.c:275` fallback only applies to Mac host builds.
- #161: disputed. oliverames says +0x68 is `protectionOptions` on macOS 27 and writing it stalled the desktop.
- #110: duplicates the merged #205.
- #190, #191: large bundles (#191's sound recovery is worth mining later).
- Huge, drafts, or out of scope: #51, #79, #83, #84, #87, #90, #93, #100, #103, #108, #114, #117, #129, #134, #157, #174, #189, #196–#204, #219, #224, #227.

### 3. Conflict map
- **Makefile:** #168 · #176 · #127 · #32 are on separate lines, so they apply cleanly.
- **Machines.swift `GuestMemory.prepare` (lines 45-54):** #211 and #214 sit one line apart. #169 and #121 duplicate #211. The VirtualMac struct is touched separately by #215 and #121.
- **henge-ios-jit.c/.h:** #211 (line 572) and #214 (line 220) don't overlap; #192, #169 and #121 do.
- **henge-vm.c:** #183 (lines 36-87) clashes with the already-merged #205. #214 (107, 190) and #121 (181, 222) are separate.
- **pvg_metal.m (11 open PRs):** the core set #207, #188, #137 and #109 don't overlap each other.
  - #216 overlaps #188 (lines 15-21) and #109/#173 (around 2290).
  - #82 overlaps #188 (lines 17-40).
  - #173 overlaps #109 (2291) and #188 (2740).
  - #92 touches the same function as #207 (`newSurface`).
  - #187 duplicates #207's first commit.
- **pvg_lite.c/.h:** #109 and #216 change the identical lines (duplicates). #161 overlaps #207 (lines 696-732).
- **Hardware.swift `HardwareMouse`:** #98, #170, #167, #123, #217 and #191 all collide. #141 only touches the Device enum and is clean.
- **SessionView.swift:** #98, #99 and #82 collide at the top of the file and around line 505. #214, #215 and #123 are separate.
- **SettingsView.swift:** #81 and #214 collide (lines 13-23). #98 is separate.
- **host/vm.c:** #78, #80, #209 and #123 are on separate lines.
- **xhci.c, USB port 3:** #123, #32, #90 and #191 each add a USB device on the same port, so only one of them can go in.
- **JIT helper:** #166 and #130 are duplicates; #192 also overlaps.
- **share.c:** #74, #76, #77, #88, #99 and #32 all collide.

### 4. Recommended order (base: main at `7b55730`)

**Why main and not 0.3:**
- Nearly all open PRs are cut against main from 12 Nov or later, so they cherry-pick as-is. On 0.3 each one would need porting.
- What main adds over 0.3 is either switched off by default (Mac apps, Instant Resume, About This Mac) or useful (the code-cache size for 6 GB devices from `2595e10`).
- The high hold that breaks main is a no-op on your free account.
- Fallback: a 0.3-based branch does build green today (`cucaichuadien-tech/Henge`).

**Stage A, "builds and installs"** (one CI run, then an install on the iPhone 16 Pro):
1. `#168`, amended with `-u IPHONEOS_DEPLOYMENT_TARGET`. In the fork itself: Husk `ref: 3.4` and the build-log upload step.
2. `#211`
3. `#214`
4. `#166`
5. `#142`
6. `#207`
7. `#188`
8. `#137`
9. `#183` (resolve the one henge-vm.c hunk by keeping both blocks)

**Stage B, iPhone ease of use:**
10. `#209`
11. `#109`
12. `#215`
13. `#141`
14. `#98`
15. `#99` (resolve two small SessionView hunks)
16. `#208`

One fork-only tweak to add here: `suggestedRAMGB` (`ios/Henge/Hardware.swift:38-43`) still suggests 4 GB on 8 GB devices, while `#214` caps the Mac at 3 GB when it starts. Set the suggestion to 3 so the UI matches.

**Stage C, iPads (Air M3, Pro M4):** `#170`, then `#167` (merge it by hand against `#98`'s scroll code, or drop `#98`'s physical-input path), then `#123`.

**Stage D, performance:** A/B on the device one at a time: `#176`, `#80`, `#81`, then `#187` (only with a macOS 27 guest), then `#186`.

Key paths, all under `C:/Users/owner/AppData/Local/Temp/claude/09d7ec978abda851/a4153b16-327b-44b9-a024-ab3d3e5fe0ef/scratchpad/henge-src/Henge/`:
- `ios/Henge/Native/henge-ios-jit.c`
- `ios/Henge/Machines.swift`
- `ios/Henge/Native/henge-vm.c`
- `ios/Henge/Henge.personal.entitlements`
- `ios/Henge/Hardware.swift`
- `Makefile`
- `tl/Makefile`
- `ios/project.yml`
- `.github/workflows/build-henge.yml`
- `ios/scripts/fetch_deps.sh`
- `ci/build-stikjit.sh`
