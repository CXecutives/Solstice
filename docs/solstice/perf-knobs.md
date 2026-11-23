# Laufzeit-Knöpfe und schnelle Leistungshebel

> Agenten-Bericht vom 22.11.2026 (Analyse von Henge main 7b55730). Zeilenangaben beziehen sich auf diesen Stand. Wo PLAN.md abweicht, gilt PLAN.md.

## Henge on iPhone 16 Pro (8 GB, free Apple ID): best performance gain per line changed

**Bottom line:** most of the measured wins need no rebuild. Four engine knobs from issue #164 and PR #218 (`HV_PVG_VBLANK`, `HV_GROUPS`, `HV_SYNC_WAIT`, `HV_RANGE_DROP`) can be switched on today in `Documents/henge-env.txt`. The best small code change is PR #161 (+11/−5 lines, one file). It fixes an interrupt storm that makes the Mac slow after 3–10 minutes.

All paths below are relative to `C:/Users/owner/AppData/Local/Temp/claude/09d7ec978abda851/a4153b16-327b-44b9-a024-ab3d3e5fe0ef/scratchpad/henge-src/Henge`. That clone is at 7b55730, which is still upstream main (no commits since 2026-11-15), so every open PR is based on current code. I built and ran nothing.

### How tunables reach the engine on iOS

- **Loader:** `ios/Henge/EngineTuning.swift:21-45`. The order is: built-in defaults (lines 12-19), then the Performance settings (lines 24-27), then `Documents/henge-env.txt`, which wins over both (lines 31-41).
- **File format:** one `KEY=VALUE` per line. `#` starts a comment, so a value can't contain `#`. Spaces are trimmed, and `{Documents}` is replaced with the folder path.
- **Getting the file onto the phone:** it is visible in the Files app (`Info.plist:91`), or from Windows through the Apple Devices app's file sharing.
- **When it is applied:** at app launch (`HengeApp.swift:15`) and again before every Mac start (`SessionView.swift:600`).
- **Re-read at every Mac start (stop the Mac, edit, start again; no relaunch):**
  - the knob table in `core/machine.c:24` (`knobs_init` at lines 26-36, called from `hv_machine_init_jit` at line 56)
  - `HV_QOS` (`host/vm.c:387`)
  - `HV_STATS` (`ios/Henge/Native/henge-vm.c:215`)
  - `HV_NO_SOUND` and `HV_BALLOON` (`devices/vmapple.c:323-328`)
  - `HV_HZ` for the display mode (`devices/pvg_lite.c:191-195`)
- **Read once per app launch (needs a relaunch, which means turning JIT on again):** `HV_PVG_VBLANK` and its refresh period (`pvg_lite.c:715-721`), and the `static int x = -1` debug switches in `dispatch.c`, `translate.c`, `sysreg.c` and `mmu.c`.
- **Gotcha:** deleting a line does not unset it until the next relaunch. The loader only calls `setenv`; the one exception is `HV_SUPERBLOCKS` at line 25. Write `KEY=0` instead of deleting.
- **Changing a knob mid-run:** the autopilot `knob NAME VALUE` command does this and flushes the code cache (`machine.c:38-47`). The autopilot starts without a Mac via `Documents/henge-autopilot-once.txt` (`Autopilot.swift:4-37`).

**Knobs that matter for speed (default on iOS):**

| Knob | Default | Location | Effect |
|---|---|---|---|
| `HV_HZ` | 60 | `pvg_lite.c:191` | Refresh rate macOS is told |
| `HV_PVG_VBLANK` | off | `pvg_lite.c:711-733` | Display refresh event |
| `HV_GROUPS` | off | `translate.c:1946-1951` | Grouped memory accesses; about +15% code size |
| `HV_SUPERBLOCKS` | off | `translate.c:705-716` | Blocks continue past conditional branches; Settings toggle |
| `HV_SYNC_WAIT` | off | `machine.c:190-294` | Sleep instead of spin while waiting for other vCPUs' TLB acks |
| `HV_RANGE_DROP` | 0 (32-page limit) | `sysreg.c:507-528` | Bigger TLB range invalidations done in one pass |
| `HV_RECHECK` | on | `machine.c:96-100` | Exact page-end access check; costs about 13% code size |
| `HV_WFI_SPIN` | 0 | `dispatch.c:465-483` | Settings "Quicker wake" sets 50 µs |
| `HV_FLUSH` | 2 (`F_BARRIERFSYNC`) | `host/disk.c:78-86` | Disk flush mode |
| `HV_QOS` | `USER_INITIATED` | `vm.c:384-397` | Thread priority class of the vCPU threads |
| `HV_STATS` | 10 | `EngineTuning.swift:18` | Seconds between engine stats lines |
| `HV_HOIST_CHECK` | off | `translate.c:779-786` | Loop exit-check placement; +2.3-2.5% code (hot part +0.6%) on test_fuzz's paired A/B (2026-11-23), over the 2% bar: off |

Also on by default: `HV_TLBT`, `HV_WALK_LOG`, `HV_IJC_PAGES` and `HV_DNS_PROXY`.

Other knobs worth knowing:
- `HV_NO_SOUND`, `HV_BALLOON`, `HV_WRITE_CACHE` (`disk.c:26-38`), `HV_RAM_FILE`, `HV_RAM_NO_LEDGER`, `HV_RAM_NO_PREFAULT` (`vmapple.c:259-289`).
- Leave alone: `HV_BLK_SEG_MAX` (stays 8 for stability, `virtio_blk.c:280-291`) and `HV_SWITCH_FLUSH` (stale TLB entries were found with it on the phone, `machine.c:30-33`).

The rest are:
- **Diagnostics:** `HV_PROF_IOS`, `HV_BLK_STATS`, `HV_PVG_*` dumps, logs.
- **Debug switches that make things slower:** `HV_NO_FAST_RESUME`, `HV_NO_XCHAIN`, `HV_INLINE_XJUMP`, `HV_NO_STASH`, `HV_NO_RAS`, `HV_EXIT_CHECKS`, `HV_IC_*`, `HV_TLBI_LEAVES`, `HV_WFE_SPIN`, `HV_PVG_SYNC`, `HV_SLOW_MEM`, `HV_BIG_LOCK`.
- **Mac-tool only (`host/main.c`):** `HV_JIT_MB`, `HV_NO_NET`, `HV_INPUT_FILE` and similar.

### What the code picks on an 8 GB iPhone

- **Guest RAM:** suggests 4 GB (`Hardware.swift:38-43`, ≥7000 MB physical). It is capped by free disk space and by the largest free address range minus 512 MB (`Machines.swift:40-53`).
- **How guest RAM is held:**
  - First choice: memory kept outside Henge's own memory count, allowed once a debugger has attached (`vmapple.c:168-197`, 265-268).
  - If refused: a `ram.tmp` file, with a thread that touches every page in advance (`vmapple.c:269-288`).
  - Last resort: plain anonymous memory.
  - The increased-memory-limit entitlement does not change this path. It only raises the limit for the code cache, its records and the app itself. The log says which path was taken: "outside the footprint" or "backed by a file".
- **vCPUs:** 4 (`InstallView.swift:18`; stepper 1–6 at `MacSettingsView.swift:44`). The A18 Pro has 2 performance and 4 efficiency cores.
- **Code cache:** depends on Henge's memory limit at launch (`JITBootstrap.swift:68-76`):
  - 5.5 GB or more → 1.5 GB
  - 3.5 to 5.5 GB → 1 GB
  - less → 512 MB

  Its bookkeeping costs about 0.75× its size on top. The Settings picker overrides it from the next launch.
- **Free Apple ID:** extended virtual addressing can't be signed, so the 60 GB reservation for Mac apps fails harmlessly. PRs #211 and #169 are therefore irrelevant on this phone. Increased-memory-limit may or may not survive re-signing: #37 says SideStore kept it on a free team, while #70 reported a 3068 MB limit without it. Check Settings: "Extra memory" and "Henge's limit" (`SettingsView.swift:57-58`).
- **Screen:** fixed at 1920×1080 on iPhone. The Screen picker is hidden when the fitting height is 1080 (`MacSettingsView.swift:77`), and Retina/Performance are iPad-only.

### Where the time goes

- **First boot and Setup:** everything is translated from scratch. Setup produces about 1 GB of code (`JITBootstrap.swift:60-61`), so a 1 GB cache flushes at least once. The first login storm (indexing and analysis) took about 15 minutes on an M1 iPad (#37, #89).
- **Login and after:**
  - vCPUs wait for each other's TLB invalidation acks (`machine.c:240-294`). That was 76% of one core at 6 vCPUs (#218), and 5–27% depending on vCPU count and heat (#193).
  - After 3–10 minutes, an interrupt storm starts (20–48K interrupts per second) because display page offset +0x68 is never written (#161).
- **Steady state:**
  - Software TLB lookups are about 35% of time spent in translated code (#164, #134).
  - A full code-cache flush happens about once a minute with 1 GB on macOS 27 (`JITBootstrap.swift:66`), or every 55–300 s with 1.5 GB. Afterwards the share of time spent translating jumps to 13–29% (#193). The flush stops all vCPUs (`dispatch.c:855-889`, 18-54).
  - Without VBLANK, the display freezes under load (#164).
  - The phone reaches "Hot" after 1.5–2 minutes and the block rate roughly halves (#193). Henge only logs the thermal state and does nothing about it (`SessionView.swift:662-666`).
- **Already well handled, not levers:**
  - Idle: WFI sleeps until the next timer or at most 10 ms (`dispatch.c:449-497`), and interrupts wake vCPUs (`gicv3.c:85`). The only fixed cost is a kicker thread that wakes every 1 ms regardless (`vm.c:344-351`).
  - Disk: virtio-blk is asynchronous with 4 workers (`virtio_blk.h:28`). Flushes and barriers act as fences. Measured at 130 MB/s synced write and 306 MB/s read (#37).
  - Page zeroing: `DC ZVA` runs directly on the host (`translate.c:1202-1211`, 1677-1681).
  - Indirect branches and chaining (`IJC_PAGES`, `RAS`, `xchain`, fast resume) are already tuned.
- **Hidden cost of the default `HV_STATS=10`:**
  - Every indirect-branch-cache miss does an extra software page walk just to classify it (`dispatch.c:1098-1114`).
  - TLB-ack waits make timing syscalls (`machine.c:253-268`).
  - Every 10 s, CPU 0 walks all 2M hash buckets and every cached block (`dispatch.c:643-663`). That is about one cache miss per block across 3–5M blocks. My estimate is a 0.1–0.5 s stall each time; it is not measured.

### (a) Knobs to test now, no rebuild

| # | Lever | Expected gain (evidence) | Risk |
|---|---|---|---|
| 1 | `HV_PVG_VBLANK=1` (needs relaunch) | Display froze in 1 of 6 rounds instead of 5 of 6 (#164, paired runs on an iPad) | Low |
| 2 | `HV_GROUPS=1` | +11% median frame rate, presented frames 26.8 → 32.2/s (#164, paired, 1.5 GB cache) | Low–medium: +15% code means more flushes with 1 GB or 512 MB caches; watch "full flushes" |
| 3 | `HV_SYNC_WAIT=1` | TLB-ack waits 76% → 4–9% of a core (#218, iPhone, not paired). Suits the 2+4 core layout and a hot phone | Low |
| 4 | `HV_RANGE_DROP=256` | Part of #218; not measured on its own | Low–medium |
| 5 | `HV_STATS=0` | Estimated 2–5% and no 10-second hitch; not measured. Keep 10 while testing. The `[perf]` lines still log (`SessionView.swift:683-688`) | None (you lose the stats) |
| 6 | Settings › Code cache: 1 GB if your default is 1.5 GB | Avoids being killed for memory: an 8 GB iPad M4 died at 4.4 min with a 4 GB Mac and 1.5 GB cache, and survived 8+ min with 3 GB and 1 GB (#214). Needs relaunch | Low |
| 7 | Mac memory 4 → 3 GB, only if iOS kills Henge | Survival (#214) | macOS swaps more |
| 8 | Settings › Superblocks on | Cold boot 36.1 → 34.2 s (#81, Mac host, 3 runs each) | Low (labelled experimental) |
| 9 | Settings › 30 Hz | Frees CPU during animation and reduces heat; the maintainer's comment at `EngineTuning.swift:13-14` says frame work is costly; no 30-vs-60 numbers | Choppier animation |
| 10 | CPUs 3 vs 4 (Mac settings) | Only 2 performance cores; `machine.c:190-192`; waits grow with vCPU count and heat (#193). Needs an A/B | Invalidates an Instant Resume save |
| 11 | `HV_QOS=ui` | Cold boot −1.6 s of 36 s (#80, Mac host, "directional") | May compete with the display threads, already at `USER_INTERACTIVE` (`pvg_metal.m:2684-2685`) |
| 12 | `HV_RECHECK=0` | −13% code size, so fewer flushes; the maintainer asks for exactly this phone A/B (`machine.c:96-99`) | Sends 80–240K accesses/s to the slow path during boot and login |
| 13 | `HV_FLUSH=1` | No host flush. Data survives Henge being killed (it is in the kernel cache) but not a device crash. Check flush cost first with `HV_BLK_STATS=10` (`virtio_blk.c:116-150`) | Medium |
| 14 | `HV_NO_SOUND=1` | Small; only if you don't need sound | None |
| 15 | Settings › Instant Resume | Resumes in seconds instead of boot plus login. The code cache starts cold. Saves are tied to build, RAM, CPUs and screen (`InstantResume.swift:19-26`). The Mac pauses whenever Henge is inactive (`SessionView.swift:187`) | Experimental; a failed resume falls back to a normal boot (`SessionView.swift:617-631`) |
| 16 | Inside macOS: "Lighter macOS" (`share.c:611-640`), plus `sudo mdutil -a -i off` and automatic updates off. Use Sequoia 15.6.1, not Tahoe/27 (`README.md:45`) | Removes most of the first-session storm (#89: 39.9 vs 43.9 s boot, and skips minutes of indexing) | Low; Spotlight search stops working |
| 17 | Check the log for "still traced" | A debugger left attached made a phone run 1.5–2× slower (`JITBootstrap.swift:200-210`) | None |

### (b) Default changes of a few lines (one rebuild, after the A/B)

1. **`EngineTuning.swift:12-19`, 5 lines:** add `HV_GROUPS=1`, `HV_PVG_VBLANK=1`, `HV_SYNC_WAIT=1`, `HV_RANGE_DROP=256`, and change `HV_STATS` to "0". No C change is needed because `knobs_init` already reads them from the environment.
2. **`JITBootstrap.swift:68-69`, about 5 lines:** use the 1.5 GB cache only when the device has more than 9 GB of physical memory (taken from #214).
3. **`Machines.swift:49`, 3 lines:** cap guest RAM at 3 GB when physical memory is 8.7 GB or less (#214). Optional.
4. **`SettingsView.swift:16` and `EngineTuning.swift:25`, 2 lines:** superblocks on by default (#81).
5. **`vm.c:389`, 1 line:** `USER_INTERACTIVE` for the vCPU threads (#80). Only if the A/B in item 11 wins.
6. **`vm.c:344-351`, about 4 lines, new code:** skip the kick and sleep 4 ms while no vCPU is active (`percpu[i].active == 0`). That cuts idle wakeups from 1000/s to 250/s; a battery gain, not measured.
7. **`MacSettingsView.swift:10/44` and `InstallView.swift:18`:** default CPUs 3, if the A/B in item 10 wins.

### (c) Small PRs to cherry-pick

| PR | Size and files | Gain | Notes |
|---|---|---|---|
| **#161** | +11/−5, `pvg_lite.c` | Writes the refresh time at +0x68 and turns VBLANK on. The "Timer delayed" log spam went from 30–36 per 10 min to 0. The storm of 20–48K interrupts/s after 3–10 min went away (1.3–7K/s after the fix), and the Mac idles properly (iPhone 18 Pro Max, macOS 15.6.1). Big for speed, battery and heat | Mergeable. Only verified on macOS 15.6.1 |
| #218 (draft) | +47/−8, `machine.c/.h`, `mmu.c`, `EngineTuning.swift`, `SettingsView.swift` | Its knob defaults are already covered in (a). Only the TLB race-check refinement in `mmu.c` (`ijc_fills_elsewhere`) and the `HV_TLB_FLUSH_ALL` knob need a build | Has not been compared side by side on a device |
| #207 | +176/−9, 9 files | Fixes the "signal 4 in translated code" crash that follows a full flush. Smaller caches mean more flushes and more crashes, and each crash costs a full boot | Mergeable |
| #215 | +32/−5, 3 Swift files | "Size of Things": 0.8 gives 1536×864 (64% of the pixels), 2/3 gives 1280×720 (44%). The only way to get a smaller screen on iPhone | Mergeable |
| #214 | +237/−5, 12 files | Stays alive in the background, gives memory back under pressure, sizes 8 GB devices. Mainly survival; its sizing part can be done with (a) items 6 and 7 | Overlaps #218 in `EngineTuning.swift` and `SettingsView.swift` (trivial to merge by hand) |
| #188 | +249/−26, `pvg_metal.m` | Keeps compiled Metal pipelines across launches: 527 of 542 came from the archive on the second boot. The time saved is unclear (0–2 ms per pipeline logged on an iPhone) | Mergeable |

`#161` and `#207` change neighbouring parts of `pvg_lite.c` (around lines 696–737); they should merge cleanly, and if not the fix is trivial.

Three PRs do nothing for this phone:
- **#78:** it changes a fallback in `vm.c:275` that iOS never uses, because `henge-vm.c:202` always passes the region size.
- **#211 and #169:** they need extended virtual addressing, which a free Apple ID can't sign.
- **#176:** network batching is useful, but its -O3 and 16 ms retry parts barely matter here.

### (d) Bigger items to skip for now

- **#186**, a segmented code-cache ring (+1085/−159 lines, 20 core files, draft): it would fix the flush stalls properly, with each eviction costing 112–268 ms instead of a full flush. But it is untested on a device, and #193's author writes that he found no device number for its eviction rework.
- **#196–#204:** 3.5K to 25K lines each.
- **#157:** conflicting, a prototype.
- **Too big or off topic:** #206 and #51 (Rosetta), #224 (Linux), #117, #190 (live display mode changes).
- **#134:** makes the TLB size a build setting (`core/cpu.h:36`). Each value needs its own rebuild, and the code comment says 64 MB of coverage was too small.
- **New work:** live thermal throttling, changing the refresh rate live, and keeping translated code across launches.

### How to test

- Use the one-shot autopilot file: `mac`, `wait 240`, `snap`, `stop`, `exit`. Alternate the configurations A B B A.
- Start every run with the phone at thermal "Normal" (#193's main caveat).
- Compare the `[perf]` blocks/s and GPU frames/10s, plus the `stats` "full flushes" count and the "waits: tlbi acks" share.
- **First relaunch:** items 1–5 together, as one env file (sketch below).
- **Then** try the Settings choices: code cache, superblocks, 30 Hz and CPUs.

A sketch of that first env file, using only the knob names and values above:

```
# Documents/henge-env.txt
HV_PVG_VBLANK=1
HV_GROUPS=1
HV_SYNC_WAIT=1
HV_RANGE_DROP=256
HV_STATS=10   # keep while measuring; 0 afterwards
```
