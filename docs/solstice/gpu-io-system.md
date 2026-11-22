# Grafik, I/O, Speicher, Strom, Gast-macOS

> Agenten-Bericht vom 22.11.2026 (Analyse von Henge main 7b55730). Zeilenangaben beziehen sich auf diesen Stand. Wo PLAN.md abweicht, gilt PLAN.md.

I've read all the key files; here is the full plan. I could not write a plan file because this session is read-only.

# Henge performance plan for everything outside the CPU translator

All file:line references are relative to the repo root `C:/Users/owner/AppData/Local/Temp/claude/09d7ec978abda851/a4153b16-327b-44b9-a024-ab3d3e5fe0ef/scratchpad/henge-src/Henge` (upstream `7b55730`). The PRs mentioned (#161, #176, #188, #207, #214, #215, #142, #109) are not in this tree. Stage 0 merges or rebases them first.

**How to read each item.** "Gain" is an estimate with its reasoning. Some numbers are educated guesses and say so. The aim is a measurable A/B for each one, not trusting the estimate.

- Effort: S is half a day or less, M is 1–3 days, L is 1–2 weeks.
- Every item has a knob, read once when the machine is created.
- A default flips on only after at least 3 alternating A/B pairs on the iPhone show a gain and no regression.

---

## 0. Measure first (Stage 0 enablers)

### E0 — Energy, wakeup and engine telemetry in the 10 s perf line (S–M, no risk)
- **Where:**
  - The app's perf line is `ios/Henge/SessionView.swift:683-688`.
  - The engine already has `hv_pvg_lite_barrier_stats` (`devices/pvg_lite.c:403`), the per-2000-exec encode/GPU line (`devices/pvg_metal.m:2211-2216`), `HV_BLK_STATS` (`devices/virtio_blk.c:116-152`) and `HV_STATS` (`EngineTuning.swift:18`).
- **What to add:**
  - From `task_info(TASK_POWER_INFO_V2)`, which is a public Mach API on iOS: `task_energy` in nJ, `task_interrupt_wakeups`, `task_platform_idle_wakeups`, `task_ptime` (time on P-cores) and `gpu_energy`.
  - `os_proc_available_memory()`, `isLowPowerModeEnabled`, and the battery level.
  - Engine counters:
    - kicks/s and WFI wakes/s
    - device polls/s and dev_lock wait time
    - pvg execs/s and encode ms/s
    - objects made/s, pipelines made/s and ms spent making them
    - IOSurface bytes synced/s
    - presents/s, split into fresh frames and cursor-only
    - vblanks/s and barrier retries
    - JIT `flush_full`/min
- **Why it comes first:** the tester is not an expert and has no Instruments. Energy in nJ and wakeups/s make every later A/B objective.
- **Verify:** CI builds it (`make test`, `make ios-lib`). On the device, check that the values move.

### B0 — Scripted A/B benchmark the tester can run
- **Mechanism:** `Documents/henge-autopilot-once.txt` (see `ios/Henge/Autopilot.swift:4-26`) runs the same script each time:
  1. `mac`, then `wait 240`.
  2. `log idle`, `wait 300` (idle energy and wakeups).
  3. `log ui`: Terminal scroll load (`type` a 3000-line `seq`), then `wait 60`.
  4. `log disk`: `dd` write 1 GB, then read.
  5. `log net`: `curl` a 100 MB file.
  6. `stop`.
- **Run order:** alternate A and B in `henge-env.txt`, with a 10-minute cooldown between runs and the same brightness and charger state.
- **Collect:** `henge.log` (perf lines, thermal transitions with timestamps, time-to-Hot).

---

## 1. GPU and display (ranked by gain per effort)

**Background: where the replay time goes.** The replay worker sits on the guest's critical path. The guest waits for stamps between batches inside a frame (`pvg_lite.c:382-387`). That makes exec, then encode, then GPU, then completion IRQ, then the next submit one serial chain. Encode microseconds on the host turn directly into guest frame time.

### G1 — Retry barrier-blocked channels on every doorbell (S, low risk, knob `HV_PVG_DOORBELL_RETRY=1`)
- **Where:** a blocked channel sets `chan_pending` (`pvg_lite.c:647-651`). It is retried only in `hv_pvg_lite_poll` (`:734-744`), which runs on CPU 0's tick. The doorbell handler `gfx_write` (`:774-776`) never retries pending channels.
- **Problem:** when the guest later writes the awaited stamp on another channel and rings its doorbell, the blocked channel waits until CPU 0 next polls. That can be up to 1 ms (kicker), or up to 10 ms if CPU 0 is in WFI (`core/dispatch.c:456-457`).
- **Fix:** after `do_channel(p, v)`, drain `p->chan_pending` in the same handler. `do_channel` is already re-entrancy-guarded by the `draining` bits.
- **Gain:** removes 1–10 ms stalls from frames that use cross-channel barriers (swaps wait on drawing). This improves smoothness more than average fps.
- **Verify:**
  - Device: `barrier_retries` in E0 should drop to near zero, and GPU frames/10 s while dragging a window should rise or steady.
  - CI: extend `tests/test_pvg_lifecycle.m` with a two-channel barrier stream.

### G2 — Hot-path hygiene in the replay (S, very low risk, no knob needed)
- **`getenv` inside the per-resource exec loop** (`pvg_metal.m:2107`, `getenv("HV_PVG_TALLY")`). `getenv` scans about 40–60 `environ` entries, roughly 0.5 µs each. With 20–50 resources per exec and thousands of execs per second, that is tens of ms of worker time per second. Fix: cache in a `static`.
- **`NSUserDefaults` reads on every presented frame:** `henge.cursor.sharp` at `:2545`, and `cursor_scale()` at `:21-36`, called twice per frame at `:2293` and `:2538`. Fix: cache them and update through `UserDefaults.didChangeNotification`.
- **Shader dumps always on:**
  - `EngineTuning.swift:30` always sets `HV_PVG_TRACE_FILE`.
  - As a result, `makeFunction` (`pvg_metal.m:496-509`) writes up to 48 relabelled metallibs to `Documents/shaders` on every launch, synchronously on the worker, whenever libraries need relabelling (the log says "library: loaded relabelled").
  - Separately, `makeSerialized` attaches a formatted `NSString` to every pipeline (`:545-548`).
  - Fix: gate both on `hv_pvg_trace_on()` (the file actually exists) or on `HV_SHADER_DUMP`.
- **Strings formatted before the dedupe check:** `complain:` (`:426-430`) is always called with `stringWithFormat` already built. Fix: add a check-then-format macro for the high-frequency sites, such as unknown render, compute, blit or info tags.
- **Gain:** a few percent of one host core while the GUI is active, and less worker latency.
- **Verify:** CI builds. On the device, the encode seconds in the `pvg-metal: … execs` line should drop.

### G3 — vblank with a presentation timestamp, gated by OS version (PR #161 for #164) (S, medium risk, knobs `HV_PVG_VBLANK=1` and `HV_PVG_VBLANK_TS=1`)
- **Where:** `vblank()` at `pvg_lite.c:714-732`. The mode rate comes from `HV_HZ` at `:192-196`.
- **Mechanism:** take PR #161 (the timestamp at display page +0x68), but write it only when `HV_PVG_VBLANK_TS=1`.
  - The app sets this only when `VirtualMac.osName` starts with macOS 15. `osName` comes from `Machines.swift:14`, and the knob would be set in `EngineTuning.apply`.
  - This keeps macOS 27 safe: the reviewer reports +0x68 is `protectionOptions` there.
  - Also log, once per boot, the protocol version the driver offers at gfx +0x1034 (`pvg_lite.c:10`, held in `p->regs`). That gives a future device-side gate that doesn't depend on `osName`.
- **Gain:** fixes display freezes under load (#164) and stops the 20–48K/s interrupt storm. It is also the prerequisite for G13.
- **Verify:**
  - Device: vblanks/s in E0 should be 60 ± 2 (not thousands) after 15 minutes.
  - No freeze during a 10-minute `yes | head` load in Terminal.

### G4 — Persistent Metal pipeline archive (PR #188) (M, merge, knob `HV_PVG_ARCHIVE=1`)
- **Where:** pipeline creation at `pvg_metal.m:513-567`.
- **Gain:** measured upstream at 527 of 542 pipelines served from the archive. That removes most first-use stalls, which are tens of ms each and block the replay worker. It matters at login, on the first launch of each app, and after Instant Resume, because Metal objects are rebuilt lazily (`pvg_lite.c:819-820`). It also includes the AGX crash fix.
- **Verify:** pipelines-made ms in E0 on the second boot should be at least 90% lower.

### G5 — Present pacing for ProMotion (S, low risk, knobs `HV_PRESENT_HZ` with default = `HV_HZ`, and `HV_DRAWABLES` with default 3)
- **Where:** `presentLoop` at `pvg_metal.m:2438-2584`, with `presentDrawable` at `:2576` and `maximumDrawableCount = 3` at `:2362`. `CADisableMinimumFrameDurationOnPhone` is on (`Info.plist:10-11`).
- **Problem:** every cursor move presents immediately. At iPhone touch rate (120 Hz) that pushes the panel to 120 Hz, with a 1920×1080 copy pass plus compositor work each time.
- **Fix:**
  - Use `[cb presentDrawable:d afterMinimumDuration:1.0/HV_PRESENT_HZ]`.
  - Coalesce cursor-only dirtiness: the latest position is already read at present time, `:2535-2537`.
- **Gain:** about half the presenter and compositor work during pointer motion, and the ProMotion panel can stay at 60 Hz. My estimate is tens to roughly 100 mW of display and DRAM power; E0's `gpu_energy` will show the real figure.
- **Verify:** device presents/s while moving the pointer should be ≤ 60.

### G6 — Zero-copy multi-plane surfaces (Safari `b3a8` tiles, video) (M, medium risk, knob `HV_PVG_PLANES_ZEROCOPY`)
- **Where:**
  - `newSurface` builds a real IOSurface for 2 or more planes (`pvg_metal.m:982-1019`).
  - `sync_iosurface` hashes every 64th byte of each plane and memcpys changed planes (`:826-916`). It runs for each resource of each exec at `:2106`.
  - The texture comes from the IOSurface plane at `:1091-1097`.
- **Mechanism:** create each plane's texture as a linear texture over the surface's existing guest-page buffer: `[buf newTextureWithDescriptor:t offset:first+plane_from[p] bytesPerRow:plane_row[p]]`.
  - The guest's per-plane format (R8, RG8, R16, and so on) is already in its descriptor; see the comment at `:1072-1075`.
  - Use `linear_texture_fits` (`:237-248`) and fall back to today's IOSurface path when it fails.
- **Side benefits:**
  - It removes the "CPU copy overwrites GPU-drawn plane" hazard that the per-plane hashes work around.
  - It removes the cross-process `planar` sharing table, because aliasing the same guest pages makes sharing automatic.
  - It frees 27–65 MB host IOSurfaces per 4K frame (`:2860-2861`).
- **Gain:** removes O(surface bytes) of CPU on the worker for every changed tile or frame. Safari scrolling (macOS draws page tiles as multi-plane surfaces, `:137-139`) and video are the main beneficiaries. For 4K30 video, it removes about 360 MB/s of memcpy plus hashing.
- **Risk:**
  - Alignment of row and plane offsets.
  - Aliased views on one buffer. This aliasing already exists for single-plane surfaces, so it is a known-working pattern.
- **Verify:**
  - CI: extend `test_pvg_lifecycle.m` with a synthetic 2-plane descriptor in guest RAM, a plane-1 texture, and a GPU read-back compare.
  - Device: IOSurface bytes synced/s in E0 should be about 0, and Safari scrolling should be smooth with no green or black tiles.

### G7 — C-array object cache and a per-exec page-walk memo (M, low–medium risk, knob `HV_PVG_OBJCACHE`)
- **Where:**
  - Every `get:` goes through `object:task:` (`pvg_metal.m:1108-1170`). Each call does a 12-byte `task_read` with a 1–3 level page walk (`pvg_lite.c:278-307`, `:363-373`), two `NSDictionary` lookups, and an `entry` memcmp.
  - Each draw binds 5–15 refs (`:1443-1610`).
- **Mechanism:**
  - Keep a per-task `HvObject *__strong` sparse vector indexed by ref.
  - Keep a small direct-mapped vpn-to-host-page memo for task memory, valid for one exec.
  - Compare the 12-byte entry straight from the memoized host pointer.
- **Gain:** roughly 150–250 ns per binding falls to roughly 20–40 ns. With 100–500 draws per WindowServer frame, that is about 0.3–1.5 ms per frame off the critical path.
- **Verify:**
  - CI: a microbenchmark in `test_pvg_lifecycle.m` that replays a synthetic exec with 10,000 bindings, old path against new.
  - Device: encode seconds per 2000 execs.

### G8 — Command-buffer scratch reuse and in-place parse (S–M, low risk, knob `HV_PVG_CB_INPLACE`)
- **Where:** `pvg_metal.m:2136-2137` does `NSMutableData dataWithLength` (which zero-fills) and then `task_read`, so every segment is written twice and up to 64 MB is allocated.
- **Mechanism:**
  1. Use one growable scratch buffer per replay (S).
  2. Parse in place when the segment's task pages map to physically consecutive guest pages. Guest RAM is one host mapping, so `task_ptr` (`pvg_lite.c:278-294`) can prove contiguity (M). The record bounds checks already use `end`.
- **Gain:** one fewer pass over all command bytes, and no allocations.
- **Verify:** CI replay test; device encode time.

### G9 — Fast path for `refresh_pages` (S, low risk)
- **Where:** `pvg_metal.m:320-338` runs for every mapped resource in every exec (`:2105`). It walks n page-table entries and memcmps them.
- **Mechanism:** skip the walk when the object was already checked in this exec (one exec can name the same object more than once). Compare the leaf table in place instead of copying out first.
- **Gain:** smaller than G7, but free.
- **Verify:** CI replay test.

### G10 — Cursor as a Core Animation overlay layer (M, medium risk, knob `HV_CURSOR_LAYER`)
- **Where:** pointer moves call `hv_pvg_metal_cursor_moved` (`:2842-2855`), then `screenChanged` (`:2429-2436`), then a full-screen redraw plus cursor quad (`:2519-2548`).
- **Mechanism:** a sublayer of the target `CAMetalLayer` holds the cursor glyph image. The glyph is premultiplied BGRA from `cursorGlyph`, at `:2239-2264`.
  - Its position is updated under `CATransaction setDisableActions` plus flush from the presenter queue.
  - Fresh guest frames still use the drawable path. Cursor-only changes never touch the GPU.
- **Gain:** removes about 16 MB of read plus write per cursor-only frame, plus compositor work. Pointer motion is the most common screen change, so this is a power and thermal win. It also lowers latency a little, because there's no `nextDrawable` wait.
- **Risk:**
  - Layer coordinate mapping in zoom and external-display modes.
  - Hot-spot scale; `cursor_scale` already exists.
- **Verify:** device presents/s while only the pointer moves should be about 0, plus a visual check in upright, landscape, zoomed and external modes.

### G11 — Opaque layer, with brightness and colour matching moved into the existing pass (S, low risk, knob `HV_SCREEN_OPAQUE`)
- **Where:** `BootDisplay.swift:111-113` sets `isOpaque = false` on a clear view. `:148-154` sets `colorspace` to sRGB and brightness as `view.alpha`.
- **Mechanism:**
  - Make the layer opaque.
  - Multiply brightness in `screen_plain`/`screen_linear` (`pvg_metal.m:2313-2326`).
  - Optionally do the sRGB-to-P3 conversion in the same shader and set `colorspace = nil`, with knob `HV_SCREEN_CM=shader`.
- **Gain:** the compositor skips the blend and colour-match per frame. This is modest; the ALU is nearly free in our existing full-screen pass.
- **Verify:** check colours with `tools/colorprobe` and `HV_COLOR_PROBE`.

### G12 — Lower guest resolution by default on iPhone (PR #215 plus #109) (S, low risk, it's a per-Mac setting)
- **Where:** `Hardware.swift:13-23`, with the mode built at `pvg_lite.c:208-210`.
- **Gain:** 1536×864 is 64% of the 1080p pixel count, and 1280×720 is 44%.
  - The guest's software-drawn content (text and layer backing stores drawn with CoreGraphics) runs on the emulated CPU and scales roughly with pixel area.
  - WindowServer composition and replay bandwidth scale with it too.
  - This is one of the biggest guest-CPU levers. On a 6.3-inch 2622×1206 panel, 1536×864 at 1x stays readable.
- **Verify:** device benchmark B0 at each size; blocks/s and energy in the UI phase.

### G13 — Dynamic vblank rate for idle and heat (S once G3 lands, medium risk, knobs `HV_VBLANK_IDLE_HZ`, `HV_VBLANK_HOT_HZ`)
- **Where:** the period computed in `vblank()` at `pvg_lite.c:719-721` becomes an atomic the app can change at runtime.
- **Mechanism:** the app lowers the rate to 30 Hz after 5 s without input, or at thermal state "serious".
  - Frozen displays without vblank (#164) suggest WindowServer paces on these events. With real timestamps from G3, Core Animation's media-time animations stay correct.
- **Gain:** while throttled, WindowServer and app compositing CPU plus GPU replay should drop by up to roughly half during animations.
- **Verify:** GPU frames/10 s and energy while a video plays, at 60 against 30 Hz.

### G14 — Fewer, cheaper command buffers (M, medium risk, knobs `HV_PVG_BATCH=N`, `HV_PVG_UNRETAINED=1`)
- **Where:** one command buffer, one completion handler and one commit per exec (`pvg_metal.m:2058-2076`, `:2099`, `:2208`).
- **Mechanisms:**
  1. When the worker queue already holds more execs, encode up to N (2–4) execs into one command buffer. The handler completes their stamps in order.
  2. Use `commandBufferWithUnretainedReferences`, with a graveyard array of objects freed by ops 0x25, 0x28 and 0x20 (`:2782-2794`). The graveyard is released in the next completion handler.
- **Gain:** commit costs about 10–30 µs, and each bound resource costs a retain/release. Estimated at a few percent of a core under GUI load.
- **Risk:** the first mechanism can delay early stamps by the GPU time of later work in the same buffer, so cap N.
- **Verify:** CI lifecycle test under `HV_PVG_SYNC`; device frame times.

### G15 — Shorter device-lock hold on the vCPU during submit (M, low risk)
- **Where:**
  - MMIO handlers run under `dev_lock` (`core/machine.c:561,596`).
  - `do_channel` does `malloc`, `ring_read` and `dispatch_async` per command (`pvg_lite.c:662-666`, `pvg_metal.m:2757-2818`).
- **Mechanism:** collect one drain's commands into a single allocation and do one `dispatch_async` per drain.
- **Gain:** less vCPU time under the global device lock, which matters with 4 vCPUs, and fewer worker wakeups.
- **Verify:** dev_lock wait time in E0.

### G16 — Separate presenter command queue with an event wait (M, medium risk, knob `HV_PRESENT_QUEUE`)
- **Where:** presents share the replay queue (`pvg_metal.m:2519`), so they wait behind work for future frames.
- **Mechanism:** fresh-frame presents use `encodeWaitForEvent` on an `MTLSharedEvent` signalled by the swap's command buffer. Cursor-only presents don't wait. This pairs with G10.
- **Gain:** less pointer latency under GPU load.
- **Verify:** device latency check and visual tearing check.

### G17 — Several display modes and resolution switching through the agent (L, high risk, research, knob `HV_MODES=1920x1080,1536x864,1280x720`)
- **Where:** `pvg_lite.c:190-196`. The mode count is at +0x208. The first mode's size is at +0x210 and its rate at +0x214, which suggests 8-byte entries.
- **Mechanism:** offer several modes. `tools/henge-agent.m` switches with `CGConfigureDisplayWithDisplayMode`.
- **Gain:** true dynamic resolution, for example dropping to 720p when hot, with no reboot.
- **Verify:** device only. The user recovers from a bad setting by deleting `henge-env.txt` in Files.

### G18 — Purgeable GPU memory (M, low–medium risk, knob `HV_PVG_PURGEABLE`)
- **Where:** op 0x3f, "may be thrown away", is a no-op today (`pvg_metal.m:2789-2791`).
- **Mechanism:** `setPurgeableState:Volatile`, then make it non-volatile again on the next use.
- **Gain:** jetsam headroom; private heaps count toward the app's memory footprint.

### G19 — Skip a swap whose surface hasn't changed (S, low risk, knob `HV_SKIP_SAME_SWAP`)
- **Mechanism:** a surface is "written since its last present" when an exec names it with flag bit 1 (`pvg_metal.m:2123-2128`). Skip a swap to a surface without that mark when the cursor hasn't changed.
- **Gain:** only if E0 shows such swaps happen.

---

## 2. Disk, network, sound, input

### D1 — Turn the write cache back on after an install (S, no risk)
- **Where:** `Installer.swift:229` sets `HV_WRITE_CACHE=0` for the whole process. `disk.c:26-37` then opens the writer with `F_NOCACHE`, which upstream measured as 2–3x slower for big writes.
- **Fix:** `unsetenv` after `henge_vm_install` returns, or pass the setting per machine.
- **Gain:** the first boot after an install (the 15-minute storm) runs with normal write caching when it happens in the same process.
- **Verify:** CI (none needed); device: `HV_BLK_STATS` MB/s on the first boot.

### D2 — `preadv`/`pwritev` per request (S, low risk, knob `HV_BLK_VECTOR=1`)
- **Where:** `seg_io` issues one `pread`/`pwrite` per segment (`virtio_blk.c:27-47`), up to 8 per request (`:290`).
- **Fix:** build an iovec array from `hv_phys_ptr` for the run and make one syscall, chunked at `DISK_IO_CHUNK` (`disk.c:11`). Keep `hv_dma_written` per segment.
- **Gain:** up to 8x fewer syscalls and VFS/APFS passes. More throughput when the workers are CPU-bound, and less worker CPU.
- **Verify:** CI: `tests/test_devices.c:296-370`, adding a 3-segment read/write chain. Device: `HV_BLK_STATS`.

### D3 — Configurable queue depth (S, low risk, knob `HV_BLK_WORKERS`, default 4, try 8)
- **Where:** `virtio_blk.h:30`, and the worker creation at `virtio_blk.c:216-219` and `:277-280`.
- **Gain:** Apple NVMe random-read IOPS rise markedly from QD4 to QD8. Boot and app launch are dominated by random reads (page-ins).
- **Verify:** device B0 disk phase and boot-to-desktop time.

### D4 — Flush coalescing, plus an honest `HV_FLUSH=1` option (S, low risk)
- **Where:** a flush is a fence that waits for all in-flight requests (`virtio_blk.c:131-136`), then `F_BARRIERFSYNC` (`disk.c:79-86`).
- **Coalescing:** a flush with no write completed since the previous flush returns at once. This is semantically safe.
- **`HV_FLUSH=1`:** document in Settings (`EngineTuning.swift:27`) that writes are safe if iOS kills Henge, because the data is in the kernel's page cache, which survives the process. They are only at risk on a phone crash or forced reboot.
- **Gain:** large for fsync-heavy work (APFS checkpoints, sqlite, `git`). The synced-write ceiling is 130 MB/s.
- **Verify:** device flushes/s and MB/s from `HV_BLK_STATS`.

### D5 — Notification suppression while workers are busy (M, medium risk, knob `HV_VQ_NO_NOTIFY`)
- **Where:**
  - Every `avail` append causes a doorbell MMIO exit (`virtio.c:141`).
  - The device never sets `VRING_USED_F_NO_NOTIFY`.
  - `VIRTIO_F_EVENT_IDX` is not offered (`virtio_blk.c:268`, `virtio_net.c:52`).
- **Mechanism:** set NO_NOTIFY while the blk ring has unclaimed work; clear it and re-check `avail` before the workers sleep. The same applies to net TX. EVENT_IDX is a later step.
- **Gain:** fewer exits under I/O and network bursts.
- **Risk:** lost-wakeup hangs, so this needs a test.
- **Verify:** CI `test_devices.c` with a burst of 64 requests; device exits/s in E0.

### D6 — TRIM/discard for the main disk (extend PR #142) (M, medium risk, knob `HV_DISCARD_ROOT`, default off)
- **Mechanism:** offer `VIRTIO_BLK_F_DISCARD` and `F_WRITE_ZEROES`, mapped to `fcntl(F_PUNCHHOLE)` on 4 KB-aligned ranges. The aux disk already has this in #142.
- **Gain:** the 64 GB sparse image stops growing forever, so host storage is freed. Raw speed gain is small.
- **Risk:** APFS trims free space at mount, which may slow boot; measure boot time.
- **Verify:** CI punch-hole test in `test_devices.c`; device boot time and image size.

### D7 — Host read-ahead off (experiment, S, knob `HV_RDAHEAD=0`)
- **Mechanism:** `fcntl(F_RDAHEAD, 0)` on the disk file descriptor. The guest does its own read-ahead, so the host's doubles bandwidth on random reads.
- **Verify:** device B0 disk phase and boot time.

### N1 — Network wakeup batching (PR #176, plus edge-triggered wakes) (S, low risk, knob `HV_NET_BATCH`)
- **Where:**
  - `send_packet` calls `hv_machine_wake` per RX frame (`net_slirp.c:111-117`).
  - `transmit` does a `write()` to the wake pipe for every TX frame, from the vCPU thread (`:254-263`).
- **Fix:**
  - Write the pipe only when `to_host` goes from empty to non-empty.
  - Wake CPU 0 once per `slirp_pollfds_poll` iteration (`:216-227`).
- **Gain:** a syscall and a condvar signal saved per packet. At 30K packets/s that is noticeable vCPU and wakeup cost.
- **Verify:** CI `test_devices.c:381-415`; device wakeups/s and download MB/s.

### N2 — Preallocated frame slab instead of `malloc` plus copy per frame (S, low risk)
- **Where:** `net_slirp.c:69-81`.
- **Gain:** small.

### N3 — Large MTU (experiment, M, medium risk, knob `HV_NET_MTU=65520`)
- **Where:** slirp `if_mtu`/`if_mru` at `net_slirp.c:304-305`. The device would offer `VIRTIO_NET_F_MTU` (bit 3) with the MTU at config +10 (`virtio_net.c:55-59`).
- **Guest step:** `sudo networksetup -setMTU en0 <n>`, checked with `-getMTU`.
- **Gain:** if Apple's driver accepts it, TCP to the guest runs at about 64 KB per segment instead of 1.5 KB. That is about 40x fewer packets through the emulated guest network stack, the classic QEMU user-net speedup.
- **Risk:** driver support is unknown.
- **Verify:** device `curl` throughput and guest CPU in `top`.

### N4 — Checksum offload (experiment, M, medium risk, knob `HV_NET_CSUM`)
- **Mechanism:**
  - `GUEST_CSUM`: slirp's packets are already valid, so set `DATA_VALID` in the RX header (`virtio_net.c:39-41`).
  - `CSUM`: finish TX checksums natively before `slirp_input`.
- **Gain:** checksum work moves from the emulated CPU to native code.
- **Risk:** driver support is unknown.

### A1 — Audio (S, low risk)
- **Where:** `hv_virtio_snd_pull` wakes CPU 0 on every render callback (`virtio_snd.c:266`).
- **Fix:** wake only when a completed buffer can be returned, that is when `consumed` crosses `pending_end[phead]`. Optionally set `AVAudioSession` `preferredIOBufferDuration` to 20–40 ms (`HengeApp.swift:21`).
- **Gain:** fewer wakeups during playback and background keep-alive.

### I1 — Input (low gain)
The path is already good: touch reports are queued and CPU 0 is woken (`xhci.c:1057-1113`). Optional: poll the xHCI directly under the device lock from the touch call to save one hop, though that hop is under 1 ms. Leave it unless E0 shows input latency spikes.

---

## 3. Memory

### M1 — Prefault guest RAM by reading, not writing (S, low risk, knob `HV_RAM_PREFAULT=read|write|0`)
- **Where:** `vmapple.c:216` uses `__atomic_fetch_add(…, 0)`, which dirties every page of the file-backed RAM (the fallback when the footprint-free path is refused, `:263-288`). The kernel then owes up to 3 GB of writeback to flash.
- **Fix:** a volatile load still populates the page cache from the hole. The guest's first write becomes a cheap soft fault.
- **Gain:** avoids up to 3 GB of flash writes per boot, but only in the file-backed case.
- **Verify:** log `ri_diskio_byteswritten` via `proc_pid_rusage` in E0.

### M2 — Memory-pressure ladder (with PR #214) (M, medium risk)
- **Mechanism:** use `DispatchSource.makeMemoryPressureSource` and `os_proc_available_memory`, escalating in this order:
  1. Drop host caches: planar IOSurfaces (gone anyway with G6) and retired frames.
  2. Mark purgeable objects volatile (G18).
  3. Inflate the balloon (`virtio_balloon.c:128-149`) by 256 MB steps.
  4. As a last resort, an Instant Resume save.
- **Note:** the guest's own compressor plus the iOS compressor means pages get compressed twice. The balloon is the only clean lever.
- **Verify:** footprint and available memory in E0; no jetsam in a 30-minute Safari run.

### M3 — Code cache size, based on measurement (S)
- **Where:** `JITBootstrap.swift:62-76`.
- **Mechanism:** log `flush_full`/min. On the 8 GB iPhone, use 1 GB if the memory limit allows it ("macOS 27 filled 1 GB about once a minute"). A full flush is a retranslation storm that also heats the phone.
- **Verify:** flushes/min against memory headroom.

### M4 — Snapshots skip ballooned pages (S–M, low risk)
- **Where:** after `MADV_FREE_REUSABLE`, pages may still be resident with stale content, so `chunk_pack` (`snapshot.c:275-305`) stores them.
- **Fix:** keep a "given back" bitmap in the balloon and skip those pages.
- **Gain:** smaller and faster saves after any inflate.

### M5 — Guidance
Keep guest RAM at 3 GB or less on 8 GB phones, as the existing `memoryNote` suggests. The `obj_seen` table (4 MB, `pvg_lite.c:84`) is only touched with `HV_PVG_TALLY`, so no change is needed.

---

## 4. Power and thermal

### P1 — Adaptive kicker (M, medium risk, knob `HV_KICK=adaptive|<µs>`, default 1000)
- **Where:** `vm.c:344-351` wakes 1000 times a second unconditionally and calls `hv_machine_kick_all`. It runs even when every vCPU sleeps in WFI.
- **Mechanism:**
  - Sleep with `pthread_cond_timedwait` until the earliest `cpu->timer_due` of the running (unparked) CPUs. That field already exists (`dispatch.c:972`).
  - Also include CPU 0's device deadlines (vblank).
  - Cap the sleep at 4–8 ms.
  - Kick only the CPU that is due.
  - Block indefinitely when all CPUs are parked, with `unpark` signalling the kicker.
  - IPIs and devices already set `exit_req` directly (`machine.c:334-343`), so they don't depend on the kicker.
- **Gain:** idle wakeups drop from about 1000/s to near 0. That matters most for the idle desktop and for background keep-alive (PR #214). It also means fewer forced exits from translated code. Timer precision improves too: deadline-driven instead of quantized to 1 ms.
- **Verify:** wakeups/s and idle energy in E0's B0 idle phase. Check that audio and animation smoothness don't regress.

### P2 — WFI cap tied to device deadlines, and a split device-poll rate (M, medium risk, knobs `HV_WFI_MAX_MS` default 10, `HV_POLL_US`)
- **WFI cap:** `wait_for_interrupt` caps sleep at 10 ms (`dispatch.c:456-457`), so each idle vCPU wakes at least 100 times a second. Raise the cap to 50–100 ms when `tick_locked` (`vmapple.c:222-239`) reports no device deadline (vblank or the sound clock).
- **Device polls:** CPU 0's tick runs 12 device polls under `dev_lock` on every kick, every WFI wake, and every write to CNTV/CNTP_CVAL or CTL (`sysreg.c:255`). Split `tick()` (`vmapple.c:242-248`) into a timer update, which always runs, and device polls, which run when a device has flagged work through `hv_machine_wake` or after `HV_POLL_US` (for example 250 µs).
- **Gain:**
  - Idle: 4 × 100 wakeups/s fall to tens.
  - Busy: less device-lock contention.
- **Verify:** E0 wakeups/s and dev_lock wait.

### P3 — Thermal and Low Power Mode profile (M, low risk, knob `HV_THERMAL_POLICY=1`)
- **Where:** the app only logs the thermal state (`SessionView.swift:662-666`).
- **Mechanism:** a new `henge_vm_set_power_profile(level)`. At thermal "serious" or in Low Power Mode:
  - `HV_PRESENT_HZ=30`
  - vblank at 30 Hz (G13)
  - kicker cap 8 ms
  - optionally a vCPU duty cycle (L effort; touches the dispatcher)
- **Gain:** degradation without stutter. Display and GPU energy is handed back to the CPU budget before the governor halves clocks.
- **Verify:** time-to-Hot and time spent in "serious" in B0.

### P4 — vCPU count against 2P+4E (S, it's a setting)
- **Where:** the default is 4 (`SessionView.swift:24`). On the A18 Pro, 2 of the 4 vCPUs land on E-cores. Guest macOS assumes symmetric CPUs, which leads to stragglers and lock convoys, plus more heat.
- **A/B:** 2, 3 and 4 vCPUs with Autopilot `cpus N`, measuring E0 `task_ptime` (P-core time) and B0 times.
- **Default heuristic** (only with evidence): `hw.perflevel0.physicalcpu + 1`.

### P5 — Low-power camera for the volume-button intercept mode (S, low risk)
- **Where:** `VolumeClicks.swift:264-282` runs the back camera at the default preset with a full frame stream that is thrown away.
- **Fix:**
  - `sessionPreset = .low`.
  - The device's lowest frame rate (`activeVideoMin/MaxFrameDuration`).
  - `alwaysDiscardsLateVideoFrames`.
- **Gain:** large for users of intercept mode. The camera pipeline costs hundreds of mW and heat.
- **Verify:** E0 energy with intercept on.

### P6 — UI churn while a Mac runs (S, no risk)
- **SessionView:** the 1 Hz loop copies 200 log lines into `@State` (`SessionView.swift:661`) plus other state. Update those only while Details is shown.
- **Hidden screens:** stop `HomeView.swift:63-68` and the `InstallView` 1 s loops while a session is up, since the `TabView` stays alive beneath it (`HengeApp.swift:50-66`).
- **Clipboard:** poll the Mac clipboard every 1 s instead of every 0.5 s (`Sharing.swift:34-41`).
- **Gain:** a few main-thread wakeups per second.

### P7 — Explicit QoS for every helper thread (S, low risk)
- **Where:** vCPU threads are set (`vm.c:384-397`). Others inherit or default:
  - blk workers (`virtio_blk.c:217,278`)
  - slirp (`net_slirp.c:324`)
  - DNS lookup threads (`dns_proxy.c`)
  - kicker (`vm.c:609`)
  - dt_fixup (`dt_fixup.c:427`)
- **Table:**

| Thread | QoS |
|---|---|
| vCPUs | user-initiated |
| pvg worker, presenter | user-interactive (already) |
| blk workers, slirp | user-initiated |
| kicker | user-interactive (less timer slack) |
| DNS, dt_fixup, prefault | utility |

### P8 — Background eco mode and guest display sleep (M, low–medium risk, knob `HV_BG_DISPLAY_SLEEP`)
- **Problem:** with keep-alive (#214), the guest keeps compositing while iOS forbids GPU work in the background, so CPU is burned on frames that fail.
- **Fix:** the henge-agent (`tools/henge-agent.m`, already polling `share.c`) runs `pmset displaysleepnow` when Henge goes to the background, and `caffeinate -u -t 1` when it returns. Combine with P1/P2/P3 at the "eco" level.
- **Gain:** WindowServer goes idle in the background, which lowers the risk of iOS killing the app for background CPU.

### P9 — `HV_STATS=0` A/B (S)
- **Where:** stats are on by default (`EngineTuning.swift:18`). The counters are shared across vCPUs (for example `m->stats.why[]`, `dispatch.c:1096`), which causes cache-line bouncing.
- **Caveat:** first check that `henge_vm_blocks` still counts with stats off, because the perf line uses it.
- **Verify:** B0 blocks/s.

---

## 5. Startup

- **S1 — Pipeline archive (G4).** The biggest warm-start win, after cold boot and after a resume.
- **S2 — Instant Resume on by default after a soak period** (`InstantResume.swift:10`; it's opt-in today). The save is already LZ4, multi-core and skips zero pages (`snapshot.c:275-389`). Add M4. Keep the pause at `.inactive` (see the rejected list).
- **S3 — First-boot path:**
  - D1 (write cache back on).
  - Offer "Lighter macOS (full)" right after Setup Assistant, before the Spotlight storm.
  - Advise running the first login on a charger at room temperature.
- **S4 — Small boot items:**
  - `dt_fixup` memmems 3 GB of guest RAM per pass, but only when the host-identity option is on (`dt_fixup.c:355-391,416-423`). Lower its pass rate.
  - Persist the metallib relabel `start_stage` across launches (`pvg_metal.m:461-467`) to save one failed library load per launch.
- **S5 — Pre-warm pipelines** from the archive on a utility thread at boot (if #188 doesn't already).

---

## 6. Guest macOS 15.6.1 tuning (biggest gain for zero engine risk)

### What is available
- **SIP is on and there is no known way to turn it off in Henge.** `csrutil disable` needs a recoveryOS boot; the cfg flags in `devices/cfg.c` / `vmapple.c:283-290` don't expose one. Treat SIP-off as unavailable.
- **`launchctl disable`/`bootout` of Apple agents doesn't work.** Upstream measured that disable doesn't survive a log out (`share.c:605-610`), and bootout of protected agents is refused under SIP.

### How to ship it
- Serve the tiers below as `/.henge/lighten` (A), `/.henge/lighten-admin` (B, asks for the password once through `sudo -v`; sudo reads from `/dev/tty`, so `curl | sh` still works) and `/.henge/lighten-fda` (C), all in `share.c` next to `lighten_script` (`:611-639`).
- Extend `unlighten_script` (`:642-654`) to revert each tier.
- The agent can re-apply Tier A at each login.

### Tier A — user level, no password, works with SIP on
```sh
# Fewer animated frames (each one is emulated drawing plus a replayed GPU frame)
defaults write -g NSAutomaticWindowAnimationsEnabled -bool false     # existing
defaults write -g NSWindowResizeTime -float 0.001                     # existing
defaults write -g NSScrollAnimationEnabled -bool false                # smooth scrolling off
defaults write -g NSToolbarFullScreenAnimationDuration -float 0
defaults write -g NSBrowserColumnAnimationSpeedMultiplier -float 0
defaults write -g QLPanelAnimationDuration -float 0
defaults write -g NSDocumentRevisionsWindowTransformAnimation -bool false
defaults write com.apple.finder DisableAllAnimations -bool true
defaults write com.apple.dock launchanim -bool false                  # existing
defaults write com.apple.dock expose-animation-duration -float 0.1
defaults write com.apple.dock autohide-time-modifier -float 0
defaults write com.apple.dock autohide-delay -float 0
defaults write com.apple.dock mineffect -string scale
defaults write com.apple.dock show-recents -bool false
defaults write com.apple.dock mru-spaces -bool false
defaults write com.apple.dock workspaces-swoosh-animation-off -bool true
defaults write com.apple.dock springboard-show-duration -float 0
defaults write com.apple.dock springboard-hide-duration -float 0
# Background intelligence that this preference actually controls
defaults write com.apple.assistant.support "Assistant Enabled" -bool false   # Siri
defaults write com.apple.Siri StatusMenuVisible -bool false
defaults write com.apple.Siri UserHasDeclinedEnable -bool true
defaults write com.apple.lookup.shared LookupSuggestionsDisabled -bool true  # Look Up/Spotlight suggestions
defaults -currentHost write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool false  # Handoff
defaults -currentHost write com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool false
defaults write com.apple.CrashReporter DialogType -string none
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true # no .DS_Store over Henge's WebDAV share
# existing: widgets hidden, screen saver off, still black wallpaper, killall Dock
```
- **Expected gain:** fewer frames during window, Dock, Finder and scroll interactions, and less Siri and suggestions daemon work.

### Tier B — admin (sudo once), works with SIP on
```sh
sudo mdutil -a -i off            # Spotlight indexing off on every volume (mds stays, idle). Finder/Mail search degrade.
sudo tmutil disable              # Time Machine
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false            # App Store
sudo pmset -a powernap 0
sudo defaults write "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist" AutoSubmit -bool false
sudo defaults write "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist" ThirdPartyDataSubmit -bool false
# Opt-in only (security trade-off): CriticalUpdateInstall / ConfigDataInstall -bool false (XProtect data updates)
```
- **Spotlight is the biggest single item.** mds_stores and mdworker dominate a fresh install's first-login storm. I expect a large part of the ~15-minute storm to go, but this is an estimate: confirm with `top -o cpu -l 2 -n 15` before and after.
- **Software update** removes catalog checks, downloads and disk churn after boot.

### Tier C — needs Full Disk Access for Terminal (granted once in System Settings › Privacy & Security)
```sh
defaults write com.apple.universalaccess reduceTransparency -bool true   # no backdrop blur passes
defaults write com.apple.universalaccess reduceMotion -bool true
defaults write com.apple.Safari UniversalSearchEnabled -bool false
defaults write com.apple.Safari SuppressSearchSuggestions -bool true
```
- **Expected gain:** Reduce Transparency removes the blur render and compute passes for the menu bar, sidebars and Dock. That means less GPU replay CPU, and fewer guest compositing passes, for every frame.
- **Caveat:** on 15.6.1, check that the writes land, using `defaults read com.apple.universalaccess`. If they don't, the fallback is the System Settings toggles.
- **Also, during Setup Assistant:** don't sign in with an Apple ID (no iCloud, Photos or bird sync); turn off Location and Analytics; skip Siri and Screen Time.

### Tier D — needs SIP off, so not possible here
Disabling these isn't possible:
- photoanalysisd, mediaanalysisd, suggestd, knowledge-agent, duetexpertd, triald, spotlightknowledged
- the XProtect remediator scans
- anything that needs NVRAM boot-args or changes to the sealed system volume

Mitigate instead by not using Photos, keeping suggestions off (Tier A), and keeping the Mac signed out of iCloud.

---

## 7. Staged order (most gain per effort first)

| Stage | Items | Why first |
|---|---|---|
| **0 (days 1–3)** | E0, B0; merge #161 (gated, G3), #188 (G4), #176 (N1), #207, #215 + #109 (G12), #214; G1, G2, D1; guest Tier A/B/C scripts | Instrumentation and existing PRs; trivial fixes with clear wins; the guest script costs no engine risk and gives the largest CPU reduction |
| **1 (week 1)** | G5, G11, P5, P6, P7, D2, D3, D4, A1, M1, P9 A/B, P4 A/B | Each S effort and low risk; covers power, pacing and disk throughput |
| **2 (weeks 2–3)** | P1 + P2 (idle path), G6 (zero-copy planes), G7 + G8 + G9 (replay hot path), G10 (cursor layer), P3 + G13 (thermal and idle pacing), M2 + G18 | Medium effort, large gains for idle power, Safari/video and frame latency |
| **3 (later)** | G14, G15, G16, N3, N4, D5, D6, D7, P8, M3, M4, S2 default-on, G17 | Bigger bets, or ones that depend on unknown guest driver support |

Flip each default only after B0 evidence. Stage 1–2 knobs stay off by default until then. Exceptions, which can be on by default from the start: D1, G1 and G2 (bug-class fixes), and P6.

---

## 8. Rejected ideas, with reasons

- **Hypervisor or ParavirtualizedGraphics on iOS:** neither is available. The app only probes for the framework (`HengeApp.swift:23-27`).
- **Zero-copy scanout (an IOSurface over guest memory as the layer's contents):** iOS doesn't allow an IOSurface over client memory, so the presenter's copy pass stays.
- **Damage-tracked partial presents:** a `CAMetalLayer` drawable doesn't keep earlier contents, and the layer has no partial-update path. G10 gets the main benefit instead.
- **Guest at 120 Hz by default:** doubles guest compositing CPU (`EngineTuning.swift:13-15`).
- **`HV_WFI_SPIN` by default:** spins host cores and costs power.
- **`HV_WRITE_CACHE=0` in normal use:** 2–3x slower big writes (`disk.c:26-29`).
- **`F_FULLFSYNC`:** slower than the barrier, with no benefit when the threat is iOS killing the app.
- **Larger `seg_max` or indirect descriptors:** Apple's driver doesn't use indirect tables and hit ENOMEM above 8 segments (`virtio_blk.c:283-290`).
- **MSI-X for virtio:** each slot already has its own INTx line (`pcie.c:63-68`), so the only saving is one ISR read per interrupt. Not worth the complexity.
- **SIP-off tuning, `launchctl disable`/`bootout`, `killall -STOP` on Apple daemons:** no recovery-boot path; the bench showed it doesn't persist; and stopping daemons hangs their XPC clients (Photos, Quick Look).
- **Async pipeline compile with completion handlers:** the guest needs the object right away. The archive (G4) is the right fix.
- **Debouncing the pause at `.inactive`:** the quiesce has to happen while the GPU still belongs to Henge (`InstantResume.swift:45-53`); background GPU work fails.
- **Demand-paged ("lazy") resume:** Darwin has no userfaultfd, and Mach exception faulting would break the JIT's direct host-memory fast path.
- **Thread pinning or affinity:** no API on iOS.
- **All vCPUs at user-interactive QoS:** starves the presenter and the main thread.
- **Converting the half-float framebuffer to 8-bit on the host:** WindowServer picks the format, and a conversion adds work. Revisit only as a guest-side display-capability change.
- **MetalFX upscaling of a low-res guest:** adds a pass. Core Animation scaling is free, and the gain comes from the guest drawing fewer pixels.
- **A DNS cache layer:** mDNSResponder already caches on both sides. IPv6 in slirp gives no speed gain.
- **Residency sets instead of `useResource`/`useHeap`:** small gain, and they risk losing hazard tracking. Revisit after G7 and G14.

---

## 9. iPad Air M3 and iPad Pro M4

- More P-cores (M3: 4P+4E; M4: 3–4P+6E) mean P4's heuristic likely gives 4–5 vCPUs.
- 8–16 GB of RAM: M2 thresholds scale with `os_proc_available_memory`, and the 1.5 GB code cache becomes the default (`JITBootstrap.swift:68`).
- The Air is 60 Hz, so G5 matters less there. The Pro is 120 Hz like the iPhone.
- Retina mode on iPad (`Hardware.swift:28-35`) quadruples guest pixels. Recommend Performance mode (`:20-23`) or G12-style sizes unless the user asks for Retina.
- iPads have better thermal headroom, so P3 triggers later. Keep the same knobs.

---

### Critical Files for Implementation
- C:/Users/owner/AppData/Local/Temp/claude/09d7ec978abda851/a4153b16-327b-44b9-a024-ab3d3e5fe0ef/scratchpad/henge-src/Henge/devices/pvg_metal.m
- C:/Users/owner/AppData/Local/Temp/claude/09d7ec978abda851/a4153b16-327b-44b9-a024-ab3d3e5fe0ef/scratchpad/henge-src/Henge/devices/pvg_lite.c
- C:/Users/owner/AppData/Local/Temp/claude/09d7ec978abda851/a4153b16-327b-44b9-a024-ab3d3e5fe0ef/scratchpad/henge-src/Henge/host/vm.c
- C:/Users/owner/AppData/Local/Temp/claude/09d7ec978abda851/a4153b16-327b-44b9-a024-ab3d3e5fe0ef/scratchpad/henge-src/Henge/devices/vmapple.c
- C:/Users/owner/AppData/Local/Temp/claude/09d7ec978abda851/a4153b16-327b-44b9-a024-ab3d3e5fe0ef/scratchpad/henge-src/Henge/host/share.c
