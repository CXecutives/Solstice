# Einrichtungs- und Startablauf (iOS 27)

> Agenten-Bericht vom 22.11.2026 (Analyse von Henge main 7b55730). Zeilenangaben beziehen sich auf diesen Stand. Wo PLAN.md abweicht, gilt PLAN.md.

I traced all six areas in the code. I built and ran nothing; the only network access was read-only `gh` calls (PRs #168, #183, #214, #141, issues #37, #211, #221, #222, CI runs, SideStore's own source). Paths below are relative to `C:/Users/owner/AppData/Local/Temp/claude/09d7ec978abda851/a4153b16-327b-44b9-a024-ab3d3e5fe0ef/scratchpad/henge-src/Henge` (main at 7b55730).

## Findings that change the plan

- **The auto-JIT setting cannot be switched on just by changing the toggle's default.** The only place it is read is `JITSetup.swift:181`, via `UserDefaults.standard.bool(forKey:)`. A changed `@AppStorage` default (`SettingsView.swift:5`) is never stored, so the toggle would show "on" while the reader still gets false.
- **"Check setup" and "Enable JIT" should be chained, not merged.** The 90 s attach timer (`JITSetup.swift:392-397`, `:480`) starts before the helper prepares the Developer Disk Image (DDI) inside `StikJIT.enableJIT` (`HengeJITHelper.swift:80-88`). The first-time DDI download takes about a minute (`JITSetupView.swift:281-282`), so one combined step can time out falsely. The helper then stays attached, nothing calls `prewarm()`, and `ready` stays false on TXM devices (`JITBootstrap.swift:188`).
- **The 30 s pairing limit is already fixed in SideStore 0.7.0-alpha and later.** SideStore rewrites `BGTaskSchedulerPermittedIdentifiers` to the re-signed bundle ID (commit bdafadbf, 2026-09-06, included in that tag). Henge reads its task ID from that list at runtime (`JITPairing.swift:239-243`), so it should then get the full background task. Only SideStore 0.6.x leaves the 30 s grace (warning at `JITSetupView.swift:197-202`). Not tested on a device.
- **The "one Mac per launch" rule now only applies after an install.** Normal stop and restart already work in one launch (`henge-vm.c:63-65`, `SessionView.swift:677-679`, `StoppedMacView`); `README.md:59` is out of date.
- **A same-launch boot after install would inherit uncached disk writes.** `Installer.swift:229` sets `HV_WRITE_CACHE=0` for the whole process. Nothing unsets it, and `host/disk.c:30` reads it at every disk open, so the first boot after the install would write 2–3x slower.
- **SideStore only offers an update when the version number goes up.** It compares major.minor.patch of the version string, not the build number (SideStore `InstalledApp.swift` `hasUpdate`, lines 208-221). It also checks the exact IPA `size`, the `sha256` if given, version and build number, bundle ID, and that every entitlement and privacy key appears in `appPermissions` (`VerifyAppOperation.swift` 58-162). Each CI build must therefore bump `0.3.N`.
- **The address-space bug on main (#211, #221) needs the extended-virtual-addressing entitlement, which a free Apple ID never gets.** The fixed allocation at 0x70_0000_0000 (`henge-ios-jit.c:534-547`) should fail harmlessly. Check `henge.log` for "high hold … successful"; if it says that, add the ~4-line fix from #221.

## 1. Launch path and gates

- `HengeApp.init` (`HengeApp.swift:10-28`): sets up logging, applies tuning, notes launch state, installs the trap guard, runs `collectImports`. It shows nothing.
- `RootView` opens on the Macs tab (`:45`, `:50-60`), and the JIT sheet is bound at `:69`.
- On every activation, `.task(id: scenePhase)` (`:70-91`) calls `jit.enableAtLaunchIfAsked()` (`:73`), then polls 10 s for a debugger and calls `prewarm()`. `:92` calls `prewarm()` when the built-in helper attaches.
- `HomeView` with no Mac shows the "No Mac yet" card with "Install macOS" and "Bring in a Mac" (`HomeView.swift:36-38`, `90-107`). JIT is never offered on its own; the sheet only appears from a button.
- With a Mac, the card shows "Turn On JIT" until `jitReady`, then Start or Resume (`:192-212`).
- Gates:
  - `chipTooOld` is false on the iPhone 16 Pro: iPhone17,1 has major ≥ 13 (`Hardware.swift:57-62`).
  - JIT `ready` (`JITBootstrap.swift:183-191`): on iOS 27 every device but iPad8,11/12 expects TXM (`HengeLog.swift:375-377`), so it needs `prewarmed`.
  - Free space for the install (`Installer.swift:145-152`, `:101`).
  - Guest RAM of at least 2048 MB to install (`Installer.swift:226-228`) and 1024 MB to boot (`SessionView.swift:591-596`). Both are measured by `GuestMemory.prepare` (`Machines.swift:42-52`, free storage minus 2 GB).

## 2. JIT on iOS 27 (built-in helper)

**How it works:**
- `resolvedMethod` (`JITSetup.swift:122-129`) picks: TrollStore, then jailbreak, then built-in if paired, then StikDebug if installed, otherwise built-in. **If StikDebug is installed and Henge is not yet paired, StikDebug wins** (`:127`).
- The built-in path is `enableBuiltIn` (`:355-422`): it finds the RemotePairing port (`:535-659`), then starts the helper extension (`JITBuiltIn.swift:66-105`). That fails if SideStore dropped the extension (`:77-81`).
- When the helper attaches, `attachGeneration += 1` (`:384`) makes RootView call `prewarm()` (`HengeApp.swift:92`). Henge claims the code region and detaches (`JITBootstrap.swift:127-136`, `223-230`).

**Pairing on the device** (`JITPairing.swift`):
- `start()` (`:78-120`) asks for notifications (`:89`), advertises `_remotepairing-pairable-host._tcp` (`:197-221`, which triggers the Local Network prompt), and submits the background task `<bundle>.pairing.session` (`:239-243`, `265-285`). If that is refused, only `beginBackgroundTask` (about 30 s) is left (`:245-261`).
- The pairing times out after 300 s (`:34`). The PIN is also sent as a notification (`:147-149`).
- On success it stores the pairing file (`:162`) via `storeOnDevicePairing` (`JITSetup.swift:313-320`).

**The auto-enable setting:**
- `autoEnableKey` is defined at `JITSetup.swift:153` and read only at `:181`.
- If it is on but Henge is not paired, it logs and skips (`:184-187`), so defaulting it to true is safe on first launch.
- With a pairing: if LocalDevVPN is installed but not connected, Henge sets `awaitingVPN` and opens LocalDevVPN (`:190-195`); the next activation continues at `:165-171`. Otherwise it calls `enable()` (`:196-198`). `autoTried` limits this to once per launch.
- After a failure, `finish` opens the sheet (`:376-380`), and the sheet jumps to the Enable page (`JITSetupView.swift:48-51`).
- Setting it after the first successful pairing (in `storeOnDevicePairing` / `importPairingFile`, `:297-320`) works from the next launch. It does nothing in the current launch, because `autoTried` is already set at `:182`. The pairing launch needs its own "continue" flag.

**LocalDevVPN (`JITSetup.swift:499-530`):**
```swift
static let connect = URL(string: "localdevvpn://enable?scheme=henge")!          // :502
static var isInstalled: Bool { UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!) } // :504, needs Info.plist:47
static var isConnected: Bool { /* getifaddrs: an IFF_UP utun* with an IPv4 in 10.7.0.0/16 */ }  // :508-522
```
- Detection works: it checks for any up `utun` interface in 10.7.x.x.
- Henge can only connect it by switching to LocalDevVPN through the URL scheme. `scheme=henge` makes LocalDevVPN return through `henge://` (`Info.plist:28-38`); `HengeApp.swift:33` only logs it, and the scene-phase task continues.
- The scheme exists only in Henge's code. It is not documented by LocalDevVPN, and I could not verify it.
- `enable()` from a "Turn On JIT" button (`:239-245`) does **not** connect the VPN first. With the VPN off it fails after the timeouts, and the sheet's "Connect LocalDevVPN" button appears (`JITSetupView.swift:308-311`).

## 3. Install path

- **JIT is not needed for the download.** `Installer.start` (`:111-143`) does the space check, then the boot ROM (an HTTP range request, `BootROM.swift`), then the download (`RangedDownload`: plain `URLSession`, resumable `.part` file, 20 retries, `Installer.swift:156-191`), then file setup (`:196-216`). JIT is first needed at the restore: the guard at `:221` and `henge_vm_install` (`henge-vm.c:234-240`, "Henge has no JIT region"). Booting needs it too (`henge-vm.c:193-196`).
- The only reason the download waits for JIT is the UI: `InstallView.swift:124-125`.
- **Why one Mac per launch after an install:**
  - `henge_vm_install` sets `installer_session = 1` (`henge-vm.c:248`), and nothing clears it.
  - `on_exit` skips `hv_vm_destroy` for the installer (`:63-65`), because the usbmuxd thread and the libusb shim keep `g_usb` pointing into that machine's USB port (`host/install.c:84-88`, `host/libusb_shim.c:31-36`).
  - From then on, `begin_start` refuses with "The installer is still attached. Quit Henge…" (`:79-83`), and `henge_vm_can_start` returns 0 (`:272-275`).
  - The app tells the user to quit at `Installer.swift:135` and `InstallView.swift:286`.
- **PR #183:**

  | | |
  |---|---|
  | State | OPEN, CONFLICTING |
  | Size | +131 / −24 |
  | Files | `host/install.c`, `host/install.h`, `host/libusb_shim.c`, `host/usb_host.h`, `ios/Henge/Native/henge-vm.c`, `tests/test_vm_lifecycle.c` |
  | What it does | Puts every shim call into the USB device under a read lock. Adds `hv_install_detach()`, which takes the port off the bus and waits out calls in flight. Adds `release_machine()`, used in `on_exit` and `failed_start`. Starts usbmuxd once per launch. |
  | Conflict | Only in `henge-vm.c`: main added the identity block (`:39-47`, from #205) exactly where the PR inserts `release_machine()`. Keep both. The other 5 files are byte-identical to the PR's base (blob hashes match). |
  | Swift | None. The quit text, auto-start and `HV_WRITE_CACHE` reset still need doing. |
- **Default version:** the first image already downloaded, otherwise Sequoia 15.6.1, chosen as "the one Henge is tested with most" (`InstallView.swift:9`, `Installer.swift:37-38`, `README.md:45`). Issue #37 confirms Sequoia with 4 GB on an 8 GB M1 device with a free ID. Keep it.

## 4. First boot and the macOS Setup Assistant

- **Autopilot automates nothing in normal use.** It runs only with the `HENGE_AUTOPILOT` environment variable or a `Documents/henge-autopilot-once.txt` file (`Autopilot.swift:31-37`).
- Its commands are blind: fixed `wait` times, absolute-pixel `move`/`click`, and `type` into whatever has focus (`:11-25`, `61-171`). It cannot see where the Setup Assistant is.
- Skipping the Apple Account, keeping the U.S. keyboard or creating the user this way is **not safe**:
  - Emulated timing varies a lot (the first login took about 15 min in #37, account creation up to 10 min on Tahoe, `Installer.swift:31`), so clicks land on the wrong pane.
  - The password would sit in plain text in Documents.
  - Upstream already saw blind typing go to a web search (`Sharing.swift:55-58`).
  - Skipping the Assistant entirely would need writes into the macOS disk, and Henge has no APFS writer (`host/install.c:1-9`).
  - A screen-reading (Vision OCR) helper would be a large project, not a minimal change.
- **The Set Up and Lighter commands** (`SessionView.swift:512-545`, `Sharing.swift:11-14`):
  - They type `curl -s http://10.0.2.4/.henge/{install,lighten} | sh` by U.S. key positions (`Input.swift:116-172`; the USB keyboard reports as Apple ANSI, `devices/xhci.c:61`). That is why they need the U.S. layout (`:525`, `:543`).
  - The user must have Terminal open and press Return; this is deliberate.
  - The scripts are served by `host/share.c:583-603` and `611-639`.
  - They cannot run automatically, because there is no guest agent before Set Up.
  - Cheapest merge: add one line to the install script before `:603`: `"curl -fsS http://" HV_SHARE_ADDR "/.henge/lighten | sh\n"`. One command then does both.
  - Optional: a German-layout table in `Keys.type` (about 15 lines, plus a toggle).

## 5. Settings defaults for the iPhone 16 Pro (8 GB, 6 cores)

| Setting | Current default | Recommendation |
|---|---|---|
| Guest RAM | 4 GB (`Hardware.swift:42`, about 7.5 GiB reported ≥ 7000 MB) | Keep; worked in #37. Fall back to 3 GB if iOS closes Henge (PR #214 caps 8 GB devices at 3 GB after an M4 8 GB kill with macOS 27). |
| Code cache | Depends on Henge's memory limit: 1.5 GB if ≥ 5.5 GB (`JITBootstrap.swift:68-69`); costs about 1.75x its size | Make it 1 GB when RAM < 9 GB (as #214), about 1 line. Or set it once in Settings. "Henge's limit" is shown at `SettingsView.swift:58`. |
| CPUs | 4 (`henge.cpus`, `HomeView.swift:163` etc.) | Keep (the A18 Pro has 2 performance + 4 efficiency cores). |
| Refresh | 60 Hz (`EngineTuning.swift:15`) | Keep; 30 Hz is optional for speed. |
| Screen | 1920x1080 (`Hardware.swift:13-17`) | Keep; Retina mode is iPad-only. |
| Instant Resume | off (`SettingsView.swift:19`, `InstantResume.swift:10`) | Turn on (2 lines). It is experimental, and the save is invalidated by each update because its ID includes the build (`InstantResume.swift:19-27`). |
| Delete download after | off (`InstallView.swift:12`) | Turn on; saves 16 GB. |

## 6. `repo.json` and CI for one-tap updates

- **Today:**
  - The workflow is manual only (`build-henge.yml:16-18`) and uploads only zipped artifacts (`:104-120`).
  - Husk is checked out unpinned (`:45-49`).
  - Main currently fails CI (run 43746224513: "NSURLHandle.h not found"). The fix is PR #168, one line at `Makefile:192`: `env -u SDKROOT make -C tl …`.
  - `package_ipa.sh` writes `~/Desktop/Henge.ipa` or `$HENGE_IPA_OUT` (`:12`), stamps the commit and date (`:45-46`), signs ad hoc with `HENGE_ENTITLEMENTS` (`:39-41`, `54-62`).
  - Versions are hard-coded at 0.3.0 / 101 (`Info.plist:26-27`, `:39-40`, and the helper's `Info.plist`).
- **Needed:**
  1. Apply PR #168.
  2. In `package_ipa.sh` after `:46`, set `CFBundleShortVersionString=$HENGE_VERSION` (for example `0.3.N`) and `CFBundleVersion=$HENGE_BUILD_NUMBER` in both the app's and `PlugIns/HengeJITHelper.appex`'s `Info.plist`, before signing (about 4 lines).
  3. In the workflow: `permissions: contents: write`, optionally `push: [main]`, pin Husk with `ref:`. After packaging: `gh release create bN Henge.ipa`, then compute `stat -f%z` and `shasum -a 256`, add a new `versions[0]` with `jq` (`version`, `buildVersion`, ISO `date`, `downloadURL` to the release asset, exact `size`, `sha256`, `minOSVersion` "17.0"), and commit with `[skip ci]` (about 30 lines).
  4. In `repo.json`: a unique top-level `identifier` (not `dev.itslevii.henge`), fork URLs, `bundleIdentifier` kept as `com.henge.app`, `appPermissions` unchanged (it matches the IPA's 4 entitlements and 2 privacy keys).
  5. The user adds `https://raw.githubusercontent.com/<user>/Henge/main/repo.json` in SideStore once and removes the upstream source (same bundle ID). Updates are then one "Update" tap and keep the app's data.
- The unpatched StikJIT in CI only matters above 0xfffffffff, which needs extended addressing, so it is irrelevant on a free ID (`ci/build-stikjit.sh:2-3`).

## (a) Current taps on iOS 27 with a free Apple ID (after SideStore install with "keep extensions")

1. Open Henge: Macs tab, "No Mac yet".
2. "Install macOS" (`HomeView.swift:101`). The download button is greyed out (`InstallView.swift:124-125`).
3. "Turn On JIT" (`InstallView.swift:135`) opens the sheet (or opens StikDebug if it is installed, `JITSetup.swift:127`).
4. "Pair on this iPhone" (`JITSetupView.swift:72-77`).
5. "Start pairing" (`:167`), then Allow notifications and Allow Local Network.
6. "Open Settings" (`:193-195`). This opens Henge's own Settings page, so the user goes back to Privacy & Security, then Developer Mode, scrolls, and taps "Pair with Henge" (about 5 taps).
7. Enter the iPhone passcode, then the 6-digit code (#222).
8. Return to Henge (tap the notification, `JITPairing.swift:165-167`).
9. "Continue" (`JITSetupView.swift:176`).
10. "Connect LocalDevVPN" (`:268`), and back.
11. "It's connected" (`:270`).
12. "Check setup" (`:331`), then wait about 1 min.
13. "Enable JIT" (`:327`), then wait about 13 s.
14. "Done" (`:325`).
15. Optional choices (version, name, RAM, delete-after), then "Download and Install" (`InstallView.swift:121`). Keep the phone on, unlocked, with Henge in front.
16. "Installed — Quit Henge" (`Installer.swift:135`): app switcher, swipe Henge away, reopen.
17. "Turn On JIT" (`HomeView.swift:209`); if the VPN dropped, repeat 10–13.
18. "Start".
19. Setup Assistant by hand (about 20+ taps plus typing; Apple Account must be skipped, `README.md:55`).
20. Optional: open Terminal, Details, "Type the Set Up Command", Return, Allow; then the same for Lighter, then log out and back in.

Every later launch: icon, "Turn On JIT" (plus the VPN round trip if it is off), "Start", type the macOS password.

## (b) The minimal change for each step

| Step | Change | Where | Approx. lines |
|---|---|---|---|
| 2 | Open on the Install tab when there is no Mac: `.onAppear { if machines.all.isEmpty { tab = .install } }` | `HengeApp.swift:45` area | 1 |
| 3–4 | Prefer built-in on iOS 27: add `if OnDevicePairing.isSupported && HengeBuiltInJIT.isAvailable { return .builtIn }` before the StikDebug line | `JITSetup.swift:126-127` | 1 |
| 3–4 | Show the sheet on first launch if not paired (once per launch), opening on the pairing page | `HengeApp.swift` task `:70-73`; `JITSetupView.swift` `onAppear :45-53` sets `path=[.pairOnDevice]` | 4 |
| 5 | Start pairing automatically when the page opens (`pairing.start()`) | `JITSetupView.swift :45-53` | 1 |
| 6–8 | Only taps; cannot be removed (see c). The 30 s limit is gone with SideStore ≥ 0.7.0-alpha. | — | 0 |
| 9–14 | After pairing: set the auto-enable key to true and a `continueAfterPairing` flag in `storeOnDevicePairing` / `importPairingFile`. At the top of `enableAtLaunchIfAsked`: connect the VPN (move `:188-195` into `connectingVPN(then:)`), then `prepareBuiltIn(thenEnable: true)` (on success it calls `enableBuiltIn()`; pass `thenEnable` into the retry closure). In the sheet: `.onChange(of: pairing.phase)` goes to `.enable`, and `.onChange(of: jit.attachGeneration) { _ in close() }`. | `JITSetup.swift:164-199`, `297-320`, `323-353`; `JITSetupView.swift` | about 22 |
| Later launches: JIT | Default auto-enable on: `object(forKey:) as? Bool ?? true` at `JITSetup.swift:181`, and `= true` at `SettingsView.swift:5`. `enable()`'s built-in branch (`:239-245`) also connects the VPN first. | as listed | 5 |
| 15 | Let the download start without JIT: drop `jitReady` from `InstallView.swift:124-125`, and wait for JIT before `Installer.swift:127` (`while !JITBootstrap.ready { phase = .checking; sleep 1 s }`, plus a label at `InstallView.swift:27`). `deleteAfter = true` (`:12`). | as listed | 5 |
| 16–18 | Cherry-pick PR #183 (resolve the conflict at `henge-vm.c:36-47`). Add `unsetenv("HV_WRITE_CACHE")` after `Installer.swift:255`. Change the text at `:135` and `InstallView.swift:286`. In RootView, when the installer finishes: `.onChange(of: installer.phase) { if case .done = $0, let m = machines.all.last { installer.reset(); tab = .macs; running = m } }` | as listed | +131/−24 from the PR, about 10 Swift |
| Later launches: Start | Auto-start once per launch: when `ready && running == nil && !installer.busy`, start the last-used Mac; call it from the `attachGeneration` handler and the scene-phase task; add a toggle `henge.autoStartMac`. Also turn Instant Resume on (`SettingsView.swift:19`, `InstantResume.swift:10`). | `HengeApp.swift` | about 12 |
| Later launches: password | No code. In macOS: FileVault off, automatic login on. | guest | 0 |
| 20 | Chain Lighter into Set Up | `host/share.c:602` | 1 (optional) |
| Updates | PR #168, version stamping, release and `repo.json` steps | `Makefile:192`, `package_ipa.sh:46`, `build-henge.yml`, `repo.json` | about 35 |
| Memory | Code cache 1 GB when RAM < 9 GB | `JITBootstrap.swift:68` | 1 |

Result after these changes:
- **First run:** open Henge, 2 Allows, about 5 taps in Settings, passcode and code, back to Henge (JIT then turns on and the sheet closes by itself), "Download and Install", then the Setup Assistant (the Mac starts by itself).
- **Later:** tap the Henge icon. The VPN round trip, JIT and resume all happen without taps.

## (c) What cannot be removed

- **JIT must be attached on every launch, and needs a pairing plus LocalDevVPN.** On TXM devices only a debugger can grant executable memory, and the grant does not survive a process restart (`JITBootstrap.swift:19-25`, `ios/README.md:15-19`, `SettingsView.swift:53`). It costs about 13 s per launch.
- **Henge cannot start LocalDevVPN itself; it can only switch to it through the URL scheme.** The VPN drops at every iPhone reboot, and only one VPN can be active (`JITNetworkAdvice.swift:79-84`).
- **Pairing must be started from Settings › Privacy & Security › Developer Mode, with the passcode and the PIN.** There is no public deep link to that pane: `openSettingsURLString` only opens Henge's own page. Wi-Fi is required (`JITSetupView.swift:152`). It must be redone after a passcode change, or when a newer pairing replaces it (`JITNetworkAdvice.swift:69-73`). An undocumented `App-prefs:` link might reach the pane; untested, not recommended.
- **The Local Network and Notifications permission prompts must be tapped once.**
- **Download and restore only run in the foreground.** iOS gives about 30 s in the background (`Installer.swift:65-67`, `115-118`), and an interrupted restore starts over (`:139`).
- **Free Apple ID limits:** 7-day expiry (refresh in SideStore with LocalDevVPN on), 3 active apps, 10 App IDs per week with Henge using 2 (`project.yml:157-167`), no extended addressing or dynamic code signing (`Henge.personal.entitlements:4-6`). Every update needs a user tap in SideStore.
- **macOS:**
  - The Setup Assistant cannot be skipped: there is no APFS writer and the restore is unmodified (`host/install.c:1-9`).
  - Apple Account sign-in fails (`README.md:55`).
  - Apple must still sign the build for virtual Macs, and an internet connection is needed (`Installer.swift:15-16`).
  - A pre-set-up macOS image may not be redistributed.
  - Henge cannot read the guest's keyboard layout or which window has focus, so it never presses Return for the user (`Sharing.swift:55-58`).

Not verified on hardware: that LocalDevVPN's `enable?scheme=` link comes back on its own; that SideStore 0.7's rewritten task ID is accepted; the iPhone 16 Pro's memory limit and the code cache it gets.

Key files: `ios/Henge/HengeApp.swift`, `ios/Henge/HomeView.swift`, `ios/Henge/SettingsView.swift`, `ios/Henge/JIT/JITSetup.swift`, `ios/Henge/JIT/JITSetupView.swift`, `ios/Henge/JIT/JITPairing.swift`, `ios/Henge/JIT/JITBootstrap.swift`, `ios/Henge/Installer.swift`, `ios/Henge/InstallView.swift`, `ios/Henge/Native/henge-vm.c`, `ios/Henge/InstantResume.swift`, `ios/Henge/Hardware.swift`, `host/share.c`, `ios/scripts/package_ipa.sh`, `.github/workflows/build-henge.yml`, `repo.json`, `Makefile`.
