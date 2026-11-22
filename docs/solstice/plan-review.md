# Gegenprüfung des Plans (Mängel + Fixes)

> Agenten-Bericht vom 22.11.2026 (Analyse von Henge main 7b55730). Zeilenangaben beziehen sich auf diesen Stand. Wo PLAN.md abweicht, gilt PLAN.md.

I found 3 high, 9 medium and 17 low defects. The plan is mostly sound. The worst problems are the storage growth on a 128 GB phone, the post-pairing chain stalling in the background, and gaps in the version stamping.

All files below are relative to the clone root `C:/Users/owner/AppData/Local/Temp/claude/09d7ec978abda851/a4153b16-327b-44b9-a024-ab3d3e5fe0ef/scratchpad/henge-src/Henge/`.

## Defects

### HIGH

**H1. Storage: the Mac's disk file only grows and can fill the phone.**
- Evidence:
  - The main virtio-blk device offers no DISCARD feature (`devices/virtio_blk.c:268`, only `F_SEG_MAX|F_BLK_SIZE|F_FLUSH`), so space macOS frees is never returned to iOS.
  - #142 adds discard only for the aux disk, and implements it by writing zeros (`hv_disk_zero` calls `hv_disk_write`). That path would allocate space, not free it.
  - Arithmetic: 51 GB free is about 47.5 GiB. `spaceNeeded` for Sequoia is 15.66 + 24 = 39.7 GiB, so the check passes with about 7.8 GiB to spare. Peak during the restore is about 35–39 GiB (download + disk + `ram.tmp` if the fallback is used). After "delete download" about 23–25 GiB stay free. The sparse `disk.img` can still grow from about 21 to 64 GiB (+40 GiB), so the phone fills, guest writes fail and APFS can be damaged.
- Fix:
  - Cap the disk at about 48 GiB on this device: `Installer.swift:199/208/213/214`, plus the label in `Machines.swift:125`. Make it one constant.
  - Test-gate the cap. Whether the restore accepts a smaller disk is not verified.
  - Add a watchdog: below about 6 GB free, pause the Mac and warn.
  - Phase 2: DISCARD for the main disk using `F_PUNCHHOLE`, never #142's zero-write path.

**H2. "Automatically continue after pairing" will stall.**
- Evidence:
  - `storeOnDevicePairing` (`JITSetup.swift:313-320`) is called from `OnDevicePairing.finished` while the user is still in Settings. The code itself posts "Return to Henge" when the app is not active (`JITPairing.swift:165-167`).
  - Opening LocalDevVPN (`UIApplication.open`) and launching the helper extension do not work from the background.
- Fix: set a pending flag there. Run the chain (VPN connect, then prepare, then enable) from the `scenePhase == .active` task (`HengeApp.swift:70-73`), once.
- Also: `autoTried` is already true after the first-launch skip (`JITSetup.swift:181-186`), so the chain must call `prepareBuiltIn` and then `enableBuiltIn` itself.

**H3. Version stamping and repo.json details that would break installs or updates.**
- Evidence:
  - SideStore checks by default: bundle ID, `version == CFBundleShortVersionString`, `buildVersion == CFBundleVersion`, and sha256 (VerifyAppOperation; defaults in `UserDefaults+AltStore.swift:542-548`). The file-size check is off by default.
  - `size`, `version`, `date` and `downloadURL` are required fields (`AppVersion.swift:95-106`). `buildVersion` must be a JSON string.
  - Both Info.plists already contain `0.3.0` / `101`, so `plutil -insert` fails, and `package_ipa.sh` runs under `set -e`.
- Fix:
  - Use `plutil -replace` on `$SAPP/Info.plist` and `$SAPP/PlugIns/HengeJITHelper.appex/Info.plist` before line 54.
  - Write repo.json with `jq --arg` for version and buildVersion and `--argjson` for size. Get size with `stat -f%z` and sha256 with `shasum -a 256`.
  - Add `concurrency: {group: release, cancel-in-progress: true}`. Without it, overlapping runs can put an older build in `versions[0]` or get their push rejected.
  - Do `git pull --rebase` before the commit-back, and set `GH_TOKEN: ${{ github.token }}`.

### MEDIUM

- **M1. Fork workflows start disabled.** The `PUT /actions/permissions` call is likely not enough: workflows in a fork start disabled (state `disabled_fork`).
  - Fix: `gh workflow enable build-henge.yml -R CXecutives/Henge`, then check with `gh workflow list --all`.

- **M2. The refresh-event setting is risky on macOS 27 and Tahoe.**
  - On #161, oliverames reports that on macOS 27 offset +0x68 means something else (`protectionOptions`) and event 8 is "disconnect"; raising it stalled the desktop on an iPhone Duo.
  - The plan sets `HV_PVG_VBLANK=1` for every guest, but the Install list still offers 27 and Tahoe (`Installer.swift:29-34`).
  - `on` is read once per process (`static int on`, `pvg_lite.c:716-718`), so choosing the value per Mac from Swift does not work after the first VM in a launch (an install counts).
  - After #161, `HV_PVG_VBLANK=1` in EngineTuning is redundant (it is on when unset). `HV_PVG_VBLANK=0` turns off both the event and the timestamp.
  - The new `HV_PVG_PRESENT_TS` knob needs new C code in #161's `vblank()`, and is also read once per launch, so changing it needs an app restart.
  - Fix: in the fork, offer only Sequoia 15.6.1 (maybe Sonoma too), or make the value re-read per VM and set it from `mac.osName`.

- **M3. Auto-start and the auto-opened sheet would fire too often.** `.task(id: scenePhase)` runs again on every return to the foreground: from Settings during pairing, from the LocalDevVPN round trip, and after macOS shuts down.
  - Fix: once-per-launch flags.
  - Guards: `running == nil`, `!Installer.shared.busy`, `henge_vm_can_start() != 0`, `JITBootstrap.ready`.
  - A crash-loop guard: a persistent "boot in progress" counter that turns auto-start off after 2 failures.
  - Reuse the "start last Mac" logic in `Autopilot.swift:65-79`.

- **M4. Auto-starting pairing on first launch.** `pairing.start()` immediately triggers the Local Network prompt (`DNSServiceRegister`, `JITPairing.swift:207`) and the notification prompt (`JITPairing.swift:89, 326`). It also starts the 300-second timeout (`JITPairing.swift:34, 96`) before the user has read anything. If they deny Local Network, pairing fails with PolicyDenied and must be fixed in Settings.
  - Fix: open the pairing page automatically, with the text "first the iPhone passcode, then Henge's code" (confirmed in the #222 comments), but keep one "Start pairing" tap.

- **M5. The performance evidence does not match the iPhone configuration.**
  - The "76 % → 4–9 %" figure from #218 is from macOS 27 with 6 CPUs, not a paired comparison (still a draft). It also included an `mmu.c` change (`ijc_fills_elsewhere`) that the plan does not take.
  - The GROUPS +11 % from #164 was measured on a 12 GB iPad mini with a 1.5 GB code cache. With #214, the iPhone gets 1 GB (`JITBootstrap.swift`). GROUPS adds about 15 % code size, and `translate.c:1948` says it "measured no faster" on the Mac.
  - Fix: keep `SYNC_WAIT` and `RANGE_DROP`. Treat `GROUPS` as an A/B test in test round 2 (watch "full flushes"), or enable it only when the code cache is at least 1536 MB.

- **M6. Waiting for JIT during the install needs more than removing `jitReady`.**
  - `InstallView`'s switch (`:24-32`) is exhaustive and needs a new `Installer.Phase` case.
  - `busy` (`Installer.swift:69-74`) must include that phase, so #214's KeepAlive keeps the app awake.
  - The "Turn On JIT" button exists only in the chooser (`InstallView.swift:133-138`); the progress view needs one too.
  - Keep the guard at `Installer.swift:221` as a backstop.
  - The boot ROM download and the space check do not need JIT.

- **M7. #183 only fixes the engine side.** I verified it: `release_machine` clears `installer_session` and destroys the VM, so `begin_start` and `henge_vm_can_start` allow a new start. The Swift side is still missing:
  - After the stop (awaited off the main thread with #214), poll `henge_vm_can_start()` before starting the new Mac.
  - Call `unsetenv("HV_WRITE_CACHE")` right after `henge_vm_install` returns, and on failure. `disk.c:30` reads it only when a disk opens.
  - On a restore failure while the VM is still running (state 1), `Installer.swift:139` keeps the machine and a retry is refused. Stop the VM on failure, or keep the "quit Henge" hint at `InstallView.swift:286`.

- **M8. "Background 7-day refresh while LocalDevVPN is connected" is unreliable.** If both Henge and SideStore expire, the PC and iloader are needed again. A refresh or update also kills a running Henge.
  - Fix: tell the user to open SideStore and use "Refresh All" every 3–5 days, turn on Background App Refresh for SideStore, and shut down macOS before refreshing or updating.

- **M9. Git identity is missing.** There is no global `user.name`/`user.email` on this PC, so the first commit fails. The GitHub email is private.
  - Fix: use `203267938+CXecutives@users.noreply.github.com` in the clone.

### LOW

- **L1.** The `JITSetup.swift:126-127` change does nothing: the built-in helper already comes before StikDebug when paired, and without StikDebug it resolves to the built-in helper (line 128). Drop it.
- **L2.** The LocalDevVPN URL scheme is already declared (`Info.plist:47`, `JITSetup.swift:502`), and the launch path already does the VPN round trip (`:190-195`). For `enable()`, add the VPN step with a one-shot flag. `isConnected` is a 10.7.x.x tunnel heuristic (`:508-521`); if it misses, Henge and LocalDevVPN would switch back and forth.
- **L3.** The SideStore advice has the wrong reason. Both 0.6.4 and 0.7.0-alpha rewrite the background-task identifiers (`ResignAppOperation`), so the 30-second limit has nothing to do with 0.7. The real reason is that 0.7.0-alpha fixes Apple sign-in (503), which broke 0.6.4 and older. iloader's default download (`releases/latest`) is already 0.7.0-alpha; tell the user not to pick Nightly or LiveContainer.
- **L4.** The build-log artifact path must be `Henge/ios/build/DerivedData.buildlog`, because of the checkout path. `package_ipa.sh:22` already prints the `error:` lines.
- **L5.** `HV_STATS`:
  - The counters and the `thread_info` probes run whenever stats are on (`machine.c:243-266`).
  - The stats line also walks 2 million hash buckets on CPU 0 every interval (`dispatch.c:646-656`).
  - 30 s reduces the walk; 0 removes all overhead. Consider 0 after test round 2.
- **L6.** #188 keeps up to 768 MB of saved GPU pipelines in Application Support (not purgeable) and loads all of them at start. Set `HV_PVG_ARCHIVE_MB=256` as a default.
- **L7.** Versions from `run_number` restart if the workflow file is renamed, and a re-run reuses the tag so `gh release create` fails. Fix: never rename the workflow, upload with `--clobber`, and add `paths-ignore` for `*.md` and `repo.json` so doc commits don't create releases.
- **L8. Option:** publish repo.json as a release asset and use `.../releases/latest/download/repo.json` as the source URL. That avoids the commit-back, the race, and me having to pull before every push.
- **L9.** Drop the upstream 0.3.0/0.2.0/0.1 entries (they point to Leviidev's releases) and keep at most 10 versions. The user should not add the upstream source as well, since both list the same bundle ID.
- **L10.** With 3 GB as the default, the warning "little room under 4 GB" shows by default (`Hardware.swift:49-53`). The suggestion change itself is cosmetic, because #214 already caps guest RAM at 3072 MB on devices with up to 8700 MB.
- **L11.** "Installation only in the foreground" (plan section 7) is outdated with #214's KeepAlive.
- **L12.** After a crash the relevant log is `henge-prev.log`, so ask for both logs. Don't have the user share `StikJIT/pairingFile.plist`, which sits in the same shared Documents folder.
- **L13.** Add to the user's steps: open LocalDevVPN once, connect, and allow the VPN configuration with the passcode; keep Wi-Fi on and connected for pairing; allow Local Network and notifications.
- **L14.** The Windows clone uses `autocrlf=true` (commits normalize to LF) and file modes are off, so new scripts have no exec bit. Use `git update-index --chmod=+x` and add `*.sh text eol=lf` to `.gitattributes`.
- **L15.** #207's author says "this exact branch was compiled but not run on a device".
- **L16.** GPL: link the source commit in each release (`HengeBuildCommit` is already stamped) and keep `LICENSE` and the third-party notices. The IPA already refuses to package Apple's boot ROM (`package_ipa.sh:47-53`), and macOS images come only from Apple's CDN. Running macOS this way is a grey area under Apple's licence; mention it.
- **L17.** `Makefile:192` is `make -C tl …`, and putting `env -u … $(MAKE)` in front is the right placement. Upstream's failure is confirmed: run 43746224513 fails with "NSURLHandle.h not found". The exact variant is in CORBENDALLAS111/Henge (`Makefile:201`) with green runs on 2026-11-20.

### Verified OK
- **Husk:** tag `3.4` = `acfd7bc`; the only differences to main are `altsource.json` and `tools/update-altsource.py`, so the build is identical.
- **Runner:** `xcode-27` works (green in another fork). A push made with `GITHUB_TOKEN` does not trigger workflows, so `[skip ci]` is harmless extra; the new fork has no branch protection.
- **SideStore updates:** `hasUpdate` compares major.minor.patch semantically, so `0.3.<n>` works.
- **App IDs:** the bundle ID stays stable, so updates reuse App IDs. Henge uses 2 (app + `.JITHelper`). Extensions don't count toward the 3 active apps on iOS 13.5 and later.
- **Merge conflicts in the proposed order:** only #183 conflicts with main (older `henge-vm.c` base, block at 36-47; keep both).
  - #207 and #161 in `pvg_lite.c` are separated by 3 unchanged lines.
  - #214 and #211 in `Machines.swift` are separated by one unchanged line (`let reach`).
  - In `pvg_metal.m`, the changes of #207, #188 and #137 don't overlap.
  - Do the plan's own edits after #214: it inserts `HV_BALLOON` between `HV_FLUSH` and `HV_STATS` in EngineTuning.
- **Knobs:** each one is read on iOS (`knobs_init` via `hv_machine_init_jit`, `pvg_lite.c`, `henge-vm.c:215`). `KEY=0` turns each off (`atoi`), and `henge-env.txt` is applied last (`EngineTuning.swift:31-41`).
- **Line references:** all the file:line targets you listed point to the right code.

## Corrected step order
1. **Fork:**
   - `gh repo fork Leviidev/Henge --clone=false` (CXecutives is a user account), then clone, set the noreply identity and `.gitattributes`.
   - Create `ipad`, make it the default branch, then `gh workflow enable`.
2. **CI commit:**
   - Makefile line 192, Husk `ref: 3.4`, build-log artifact path.
   - Release step: concurrency, `paths-ignore`, version env, `plutil -replace` in both plists, idempotent upload, typed jq, own source identifier, fork-only versions.
   - Push and check green, sha256 and size.
3. **Cherry-picks:** #214, #166, #207, #188, #142, #137, #183 (resolve conflict), #161 (plus a timestamp knob, optional), #211. Push and let CI compile.
4. **Own edits:**
   - Install flow (M6, M7), JIT chain on foreground (H2), auto-sheet without auto-start of pairing (M4), once-per-launch auto-start with guards (M3), JIT-at-launch default on (reader and toggle).
   - Fork offers only Sequoia (M2); defaults `SYNC_WAIT`, `RANGE_DROP`, `ARCHIVE_MB` (GROUPS as A/B); 3 GB plus note text.
   - Disk cap plus watchdog (H1), "lighter macOS" chained in `share.c`.
   - Push and check the release.
5. **User:**
   - Set a passcode, Wi-Fi on; install LocalDevVPN, connect once and allow the VPN configuration.
   - iTunes (from apple.com) and iloader; install SideStore (default latest = 0.7.0-alpha).
   - Turn on Developer Mode, restart; trust the developer.
   - In SideStore: add the source, install Henge, keep extensions, turn on Background App Refresh.
   - In Henge: allow Local Network and notifications; pair (passcode first, then Henge's code); download and install.
   - In macOS setup: FileVault off, automatic login.
   - Every 3–5 days, Refresh All in SideStore; shut down macOS before updates.
6. **Test rounds 1–3** as planned. Collect `henge.log` and `henge-prev.log`, and check "full flushes" and the GROUPS A/B.

### Critical Files for Implementation
- `ios/scripts/package_ipa.sh` and `.github/workflows/build-henge.yml`
- `ios/Henge/Installer.swift`
- `ios/Henge/JIT/JITSetup.swift`
- `ios/Henge/HengeApp.swift`
- `devices/pvg_lite.c` and `devices/virtio_blk.c`
