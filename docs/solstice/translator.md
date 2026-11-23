# Übersetzer: Optimierungsplan (O1–O22)

> Agenten-Bericht vom 22.11.2026 (Analyse von Henge main 7b55730). Zeilenangaben beziehen sich auf diesen Stand. Wo PLAN.md abweicht, gilt PLAN.md.

I read the code only; nothing was built or run. All paths below are relative to `REPO = C:/Users/owner/AppData/Local/Temp/claude/09d7ec978abda851/a4153b16-327b-44b9-a024-ab3d3e5fe0ef/scratchpad/henge-src/Henge` (upstream main 7b55730).

# Henge CPU core: aggressive performance plan

## 0. Short version

**Is Henge in Rust? No, and a rewrite would not make it faster.**
- **What it is written in:** C11 plus arm64 assembly. Line counts: `core/` 8.0K, `host/` 7.7K (including `enter.S`), `devices/` 11.3K, iOS native glue 2.8K. The app is Swift/ObjC (8.8K). There are no `.rs` files; rustup only appears in the CI workflow to build Husk dependencies.
- **Where the speed comes from:** almost all guest time runs in arm64 code that the translator emits. Its speed depends on which instruction sequences `core/translate.c` writes, not on the language the translator is written in. A Rust translator that emits the same words runs the guest at the same speed.
- **The host-side C paths gain nothing either.** The dispatcher, page walker and helpers already go through LLVM (clang). rustc uses the same backend.
- **Rust's safety would not apply.** The engine is mostly code Rust would have to mark `unsafe`: JIT memory, raw guest RAM, signal handlers, fixed struct offsets shared with assembly (`cpu.h` `_Static_assert`s), and lock-free seqlock protocols (`mmu.c` walk_seq/ijc_seq).
- **Rewrite cost and upstream sync:** a rewrite is months of work and resets device validation to zero. This repo collects fixes from community forks, and upstream is very active (#164–#218, PR #186). A Rust fork could never merge them again.
- **Better plan:** spend the effort on the emitted code and on the system design. Rust would only make sense for new, isolated, non-hot components.

**Actions with the most gain for the least work:**
1. Turn on `HV_SYNC_WAIT=1` by default. It is one line, and #218 shows TLBI-ack spinning drop from 76% of a core to 4–9%.
2. Stop running the expensive stats paths on every phone. `HV_STATS=10` is on by default (`EngineTuning.swift:18`).
3. Fix how knobs reach tests and the Mac tool. `hv_machine_init` never calls `knobs_init` (`machine.c:49-53`), so `HV_GROUPS=1 make test` silently tests nothing.
4. Move hot statistics counters to per-CPU storage. Today every vCPU writes the same `m->stats` cache lines on every dispatcher entry and exception.
5. Compact the out-of-line slow paths. Estimated 25–30% less code, which means about 1.4x fewer full flushes.
6. Rework grouped memory accesses (`HV_GROUPS`) so their code-size cost mostly disappears, then turn them on by default.
7. Replace the stop-the-world full flush with segmented, generational eviction that uses epochs instead of stopping all vCPUs (building on #186).
8. Build the measurement harness first: a CI perf gate plus a one-tap on-device benchmark.

---

## 1. Profile model: where time goes today

### 1.1 Cost of each piece of emitted code (from the translator source)

**Plain ALU/FP instructions** are copied 1:1 (`translate_copy`, `translate.c:580-641`). They only cost extra when they use guest x6/x7/x15/x18/x28, which live in `HvCpu`.

**Every load or store** goes through the inline TLB check (`translate.c:1066-1098`, `put_tlb_slot` at 136-145). In the common case:
```
ubfx T,addr,#14,#14 ; add T,x28,T,lsl #5 ; [add T,T,#table (EL1)] ; ldr U,[T,#tag]
sub U,addr,U ; lsr U,U,#14 ; cbnz U,slow ; ldr U,[T,#addend] ; ldr rt,[addr,U]
```
- That is 8–9 instructions instead of 1, with two dependent loads on the critical path.
- The TLB entries live in 512 KB tables per EL (16K entries × 32 B, `cpu.h:20-41,104`). That is far bigger than L1D (128 KB on a P-core, 64 KB on an E-core), so hot entries are often served from L2.
- Evidence that TLB cache footprint is first-order: switching to table-major layout gave "9-20% faster in 5 of 6 paired rounds" (`machine.c:80`). Together with #164/#134 (TLB ≈35% of translated-code time), the inline TLB is the single largest cost inside translated code.

**Each memory instruction also gets an out-of-line slow path** (`emit_ool`, `translate.c:1766-1819`):
- a retry B,
- the 5–6-word exact recheck,
- `mov x7`,
- a 5-word helper call (`put_helper`, 492-503),
- a 16-byte pool record,
- `b join`.

That is about 17–18 words (≈70 B) per load or store.

Upstream measured 296–300 bytes per block with the recheck and 259–261 without (`machine.c:96-100`), so the recheck alone is about 10 words per block, i.e. ~1.7 memory slow paths per block. My estimate is that **slow-path stubs are ~45–50% of all emitted bytes**. This is the main driver of code-cache fill and flush frequency.

**Branches:**
- Same-page direct branches chain to a plain `B`, plus an `exit_req` check on backward edges (`translate.c:393-473`).
- Cross-page direct branches add an exec-tag check (4–5 instructions) or go through the shared xjump thunk.
- Indirect branches take ~14 instructions with 4 dependent loads (`put_ijc_jump`, 249-312).
- Returns take 9 instructions but use the host's own return stack (`put_return`, 758-776).

**System instructions:**
- SVC, ERET, MRS/MSR that are not inlined, TLBI and AT go through `hv_helper_entry` (`enter.S:180-211`).
- Each helper call saves all GPRs, all 32 Q registers (512 B stored, 512 B loaded) and NZCV, then runs C (`dispatch.c:355-411`), then reloads everything.
- That is roughly 300–1000 cycles per call before any real work.

**Dispatcher round trip** (`run_loop`, `dispatch.c:931-1145`; `hv_enter`/`hv_exit`, `enter.S:129-178`):
- Full FP save and restore, an ISB on every entry, then fetch, front-cache lookup, IJC fill with seq_cst atomics, and stats.
- Estimated 300–600 ns per entry.
- The app's "blocks/s" figure is exactly this rate (`m->stats.blocks++` at `dispatch.c:1119`). Important: **it is not a throughput metric.** It goes down when chaining improves.

### 1.2 System-level costs (from your measurements plus code)

- **Translation after a full flush:** 13–29% of time (#193). Flushes happen every 55–300 s. `hv_flush_blocks` (`dispatch.c:18-54`) wipes every translation, and the stop-the-world routine (`dispatch.c:855-889`) parks every vCPU while it runs.
  - The flush itself memsets the 16 MB block hash plus IJC/ret/front caches. The retranslation storm afterwards costs far more than the pause.
  - Averaged over the flush interval, this is ~2–8% of time, plus visible stutter.
- **Multi-vCPU TLBI waits** (`sysreg.c:484-543`, `hv_cpu_sync` at `machine.c:240-294`): spinning burns up to 76% of a core (#218). `HV_SYNC_WAIT` defaults to 0 (`machine.c:248`; `knobs_init` at 26-36).
- **Shared statistics cache lines** written by every vCPU on hot paths. Each write from a different core is a coherence miss, typically 100+ ns across the P/E clusters:
  - `m->stats.blocks++`, the `recent[]` ring and `nrecent` (`dispatch.c:1097,1119`);
  - `stat_slow_mem` (`dispatch.c:364`);
  - `exceptions`, `interrupts` and the `elchg` ring on every exception and syscall (`exception.c:46-54`);
  - `fetch_walks` (`mmu.c:826`) and `tlb_flushes`/`reset_why` (`mmu.c:143-144`).
- **The expensive stats paths that `HV_STATS=10` turns on, on every iPhone by default** (`henge-vm.c:215`):
  - a page walk plus physical read on every dispatcher cache miss (`dispatch.c:1098-1114`);
  - a walk of all 2M hash buckets every 10 s (643-663);
  - `mach_absolute_time` and seen-table hashing per translation (156-165, 200-207);
  - a decode per slow memory access (365-368);
  - a TLB probe plus extra walk per slow access (`memop.c:303-337`);
  - `thread_info` probes in `hv_cpu_sync` (`machine.c:253-268`);
  - instruction classification per translated instruction (`translate.c:1983-1987`).
- **1 ms kicker:** `vm.c:344-351` forces every CPU out of its chain 1000 times a second. On each kick, CPU0 takes the device lock and polls every device (`dispatch.c:969-973`, `vmapple.c:222-248`). Other CPUs take the GIC mutex twice for timer PPIs even when nothing changed (`gicv3.c:395-404`). It is also 1000 host wakeups a second, which costs power and heat.
- **Thermal throttling:** "Hot" after 1.5–2 minutes, after which throughput halves. This is the largest device-level factor, so every wasted spin or poll costs twice.
- **Core count:** 4 vCPUs (`HomeView.swift:163`) on 2 P-cores plus 4 E-cores means at least two vCPUs often run on E-cores at roughly 0.3–0.4 of P-core speed. That creates stragglers for TLBI broadcasts and lock-holder preemption inside the guest.
- **Debugger left attached:** 1.5–2x slower. This is already handled by `JITBootstrap.releaseLingeringDebugger`, but it must be recorded in every benchmark line.

### 1.3 Theoretical ceiling (an estimate, to be checked with `test_bench`)

Model of today's design, cost relative to native per instruction class:

| Class | Share of instructions (macOS userland) | JIT cost vs native |
|---|---|---|
| ALU/FP | ~50% | ~1.0–1.1x |
| Loads/stores | ~30% | ~2.5–4x (TLB check, L2-resident entries) |
| Branches | ~15% | ~1.5–3x (IJC/returns higher) |
| System instructions | <1% of instructions, but 10–50x each | |

That gives about **0.5x native per core at best for compute-bound user code**. Kernel-heavy and syscall-heavy phases realistically reach 0.2–0.3x. Whole-system GUI work today is probably 0.2–0.35x.

What is plausibly achievable:
- About 1.3–1.6x from engine work: smaller code, fewer flushes, grouped checks, cheaper system paths.
- A further 1.2–1.5x on the phone from system fixes: TLBI waits, false sharing, vCPU and QoS choices, less wasted power.

These multiply only partially; validate each step. The hard ceiling on an iPhone 16 Pro remains 2 P-cores' worth of throughput, under thermal limits.

---

## 2. Findings to fix before any optimization (they affect measurement)

**F1. Env knobs don't reach tests or `hengevm`.**
- `hv_machine_init` (`machine.c:49-53`) does not call `knobs_init`. On that path, only TLBT, MOVIMM, WALKLOG, HOIST, IJCPAGES, DNSPROXY, SUPERBLOCKS and RECHECK are read from the environment (`init_rest`, 79-100).
- So `HV_GROUPS`, `HV_SYNC_WAIT`, `HV_RANGE_DROP`, `HV_JIT_CAP` and `HV_K1..3` set in the environment do nothing in CI.
- Fix: call `knobs_init()` in `hv_machine_init`, keeping the `init_rest` defaults.

**F2. Some env settings are read once per app launch, not per Mac start.**
- About 20 settings are cached in function-level `static int v = -1` variables: `HV_NO_XCHAIN`, `HV_INLINE_XJUMP`, `HV_TLBI_LEAVES`, `HV_EXIT_CHECKS`, `HV_C_EXCL`, `HV_NO_FAST_RESUME`, `HV_WFE_SPIN`, `HV_IC_IVAU` and others.
- `EngineTuning` says settings apply "before each Mac starts", but these keep their first value until the app is relaunched.
- Rule for this plan: every new knob goes into `hv_knob[]` (enum at `machine.h:327`, names at `machine.c:24`). Those are re-read at each start and can be changed live with Autopilot's `knob` command.

**F3. "blocks/s" (`SessionView.swift:654-656`, `henge-vm.c:349`) counts dispatcher entries, not work done.** Do not use it to judge optimizations. Section 4 defines better metrics.

**F4. Stats are on by default on iOS** (`EngineTuning.swift:18`). See O2.

---

## 3. Ranked optimizations

Gains are estimates; they overlap and are not additive. Every item is knob-guarded with the old behaviour as default until a device A/B result comes in.

### Tier 0: days, mostly configuration, low risk

**O1. `HV_SYNC_WAIT=1` by default.**
- **Mechanism:** a vCPU waiting for TLBI acks sleeps on the kernel's compare-and-wait (`__ulock_wait`) after 64 spins instead of spinning and yielding (`machine.c:271-279`).
- **Change:** add `"HV_SYNC_WAIT": "1"` to `EngineTuning.swift:12-19`, or default it to 1 in `knobs_init` when unset.
- **Gain:** frees up to ~0.7 of a core at 4+ vCPUs. Estimated 5–20% in multi-threaded phases (login, app launch), because a spinning waiter steals one of only two P-cores.
- **Risk:** low. The worst case is a missed wake costing 100 µs.
- **Effort:** 1 line.
- **CI:** `make core-test` with `HV_SYNC_WAIT=1` (needs F1 first); `test_mmu` multi-CPU cases.
- **Device:** A/B over the benchmark's login and app-launch phases; compare the `tlbi_wait` and `busy` fields.

**O2. Cheap stats by default.**
- **Mechanism:** split stats into cheap counters (always on, per-CPU after O4) and deep diagnostics behind a new knob `HV_STATS_DEEP`.
- **What moves behind `HV_STATS_DEEP`:** every expensive site listed in 1.2: `dispatch.c:156-165, 200-207, 365-368, 643-663, 1098-1114`; `memop.c:303-337`; `machine.c:253-268`; `translate.c:1983-1987, 1998-2002`.
- **Keep:** the `HV_STATS` cadence for upstream bug reports, but only the cheap counters.
- **Gain:** estimated 1–4% (the walk on every cache miss, decode per slow access, a 16 MB scan every 10 s, timer reads).
- **Risk:** none. **Effort:** half a day.

**O3. Device sweeps of settings that already exist.** No new code, only benchmark runs (section 4.2):
- `cpus` 2/3/4 (my guess is 3 on iPhone 16 Pro and 4 on iPad M3/M4);
- `HV_QOS=ui|init`, plus a new `HV_QOS0=ui` for vCPU0 only (see below);
- `HV_GROUPS=1` (#: +11% fps; the code comment at `translate.c:1948` says "measured no faster" on the Mac, so resolve this on the device);
- `HV_HOIST_CHECK=1`, `HV_SUPERBLOCKS=1` (steady state, not boot), `HV_RANGE_DROP=256`, `HV_WFI_SPIN=0/20/50`, `HV_RECHECK=0/1`;
- code cache 1024 vs 1536 MB.

Translation knobs can be switched live with Autopilot `knob` (it flushes), so A/B/A/B runs fit in one session.

`HV_QOS0=ui` (new): SPIs route to CPU0 by default (`gicv3.c:41-45`) and CPU0 polls the devices, so it is the latency-critical vCPU. Run it at USER_INTERACTIVE and the others at USER_INITIATED (`vm.c:384-397`).

### Tier 1: 1–3 weeks each, medium gain, low to medium risk

**O4. Per-CPU statistics.**
- **Mechanism:** add an `HvStats` copy to `HvPerCpu` (`machine.h:156-212`), 128-byte aligned. Every hot `m->stats.x++` becomes `pcs->stats.x++`.
- **Readers:** `print_stats` and `henge_vm_blocks` sum across CPUs.
- **Drop:** `recent[]` and `elchg[]` become per-CPU debug rings, or move behind `HV_STATS_DEEP`.
- **Gain:** ~0 with 1 vCPU; estimated 2–8% at 3–4 vCPUs (each removed write is a cross-core cache-line transfer on millions of dispatcher entries and exceptions per second).
- **Risk:** low. **Effort:** 1–2 days, ~200 lines.
- **CI:** new `test_bench_mp` (4.1) checks that per-thread throughput scales from 1 to 3 threads.

**O5. Compact out-of-line slow paths, with the recheck moved into a thunk** (largest code-size win).
- **Mechanism:** replace each ~18-word per-access slow path with:
  `str x30,[x28,#240]` ; `bl <per-chunk trampoline>` ; a 16–20 B record ; `b join`.
- **Record contents:** guest PC, instruction, op, refill flags, retry delta, address register, the T/U registers, and the spilled-register list (3 × 5 bits).
- **Trampoline:** placed at the start of each 1 MB chunk (`chunk_take`, `translate.c:2045-2063`) so that `bl` reaches it. It is `ldr x15,[x28,#slow_thunk]; br x15` (x15 is free at a slow-path entry).
- **The new `hv_slow_thunk` in `enter.S`:**
  - saves GPRs, then fixes the saved register file from `cpu->spill` using the record;
  - runs the exact last-15-bytes recheck in asm; on a pass, it rebuilds T = slot pointer and returns to `at+1`, so the fast path resumes;
  - otherwise calls `hv_tlb_refill` and, on success, returns to retry;
  - otherwise calls `hv_helper` and returns to join.
- **Code to change:** `Ool` (`translate.c:38-54`), `emit_ool` (1766-1819), `put_helper_refill`/`put_helper` (476-503), `hv_helper_thunk` (`enter.S:221-271`).
- **Gain:** estimated −25 to −30% total code (≈296 → ≈210 B per block). That means about 1.4x longer between flushes, 15–25% less translation time (fewer words written and IC-invalidated), and better I-cache/iTLB density. Estimated 3–8% overall, more once O6 enables groups. It also makes `HV_RECHECK`'s ~13% code cost disappear while keeping its speed benefit (the phone sees 80–240K page-end accesses/s).
- **Risk:** medium, because the thunk decodes registers generically. **Effort:** 1.5–2 weeks, ~500 lines.
- **Knob:** `HV_OOL_COMPACT`.
- **CI:** `test_mem`/`test_jit` under the knob; new accesses in `mem_programs.S` that cover page-end, page-crossing, TLB-miss, MMIO, code-page-write, fault, and stolen-register (x18/x28) cases; the differential fuzzer (4.1). Deterministic gate: cold words per guest instruction must drop by at least 30% with time-to-result unchanged.
- **Device:** benchmark plus the flush count and interval in the `HENGE-BENCH` line.

**O6. Groups v2, then on by default.**
1. Emit group copies in the cold part. Today `emit_group_copies` runs before `cold_on` (`translate.c:1994-1997`), so the copies sit in hot code; this needs `plink` for the branch back to `after[end]`.
2. Give the group check (`OOL_GROUP`, 1019, 1786-1791) a refill-and-retry with a range length. Extend the refill flags to carry up to 4096 bytes. A cold TLB then no longer drops into the plain copy.
3. Optional: drop the copies entirely and on a persistent failure exit to the dispatcher to run a lazily translated version of the block without groups.
- **Gain:** keeps the reported +11% fps while shrinking its +15% code cost to about +2–4%, and removes the double `translate_emit` on overflow (1950).
- **Risk:** medium. **Effort:** 1 week.
- **Knob:** `HV_GROUPS` = 2 for v2.
- **CI:** test matrix with `HV_GROUPS=1/2`; fuzzer with groups that straddle pages.

**O7. TLB miss-path improvements**, ordered by how sure the payoff is.

(a) **Light refill for pre/post-index accesses.**
- `can_refill` excludes writeback forms (`translate.c:1087`). In `translate_mem`, the base writeback is emitted after the access (1177-1195), and retry starts before the spill (989), so re-running is safe.
- This covers `stp x29,x30,[sp,#-16]!` and `ldp ...,[sp],#16` in every function prologue and epilogue after a process switch or TLB drop: they would then take the light refill instead of the full `hv_mem_emulate`.
- Knob `HV_REFILL_WB`. Effort: 1 line plus tests (pre/post accesses on fresh pages, including SP and stolen-register bases).

(b) **Victim TLB / 2-way set.** In `hv_tlb_refill` (`mmu.c:856-875`), before walking, look up an 8–16-entry per-table victim array that `tlb_fill` (628-657) feeds when it evicts a live entry.
- Every invalidation path must also clear the victims: `hv_tlb_flush`, `flush_va*`, `flush_user*`, the stash save/restore, and both remote-drop functions (732-806).
- Build this only if device stats show conflict misses ≥50K/s per CPU (the line `tlb misses K/s: ... conflict`).
- Knob `HV_TLB_VICTIM`.

(c) **Page-walk cache.** Per CPU, cache the last-level table base by (TTBR, VA>>25), tagged with a global generation. Any TLBI other than the last-level forms (VALE1/VAALE1) bumps the generation; TTBR/TCR/SCTLR writes flush it.
- Saves 2–3 dependent descriptor loads per walk; these are usually cache misses.
- Knob `HV_WALK_CACHE`.

- **Gain for (a)–(c):** estimated 1–4% total.
- **Risk:** (a) low; (b) and (c) medium (staleness).
- **CI:** `test_mmu` with the knobs; a new `bench_tlb_conflict`.

**O8. Fewer and shorter TLBI ack waits.**

(a) **Translating CPU stops counting as live.** While a CPU translates (`dispatch.c:157-160`), set `tlb_live=0`. After translating, set it back to 1, call `hv_cpu_process_requests`, and recheck that the block's exec tag still matches before entering it; if not, `continue`. This removes "translating" from the wait causes (`sync_phase[1]`).

(b) **Process pending requests at the start of the TTBR0-write helper** (`sysreg.c:203`).

(c) **Skip the wait for ASID TLBIs when the target runs a different ASID.**
- Conditions: the target's current ASID ≠ the TLBI's ASID, read inside an even `walk_seq` window.
- Then: drop the target's stash for that ASID remotely (already remote-safe), post only the branch-cache part, and do not wait. The target's live TLB holds no entries for that ASID, and its IJC entries are only reachable after a TTBR0 switch, which (b) makes process requests first.

- **Gain:** cuts the remaining 4–9% plus wait latency on the requesting CPU.
- **Risk:** (a) and (b) low-medium; (c) medium.
- **Knob:** `HV_TLBI_FAST`.
- **CI:** `test_mmu` multi-CPU, `bench_mp_tlbi` (4.1).

**O9. Deadline-driven kicker, and less work on each kick.**
- **Kicker:** sleep until min(`timer_due` of running CPUs, next device-poll time) with `mach_wait_until`, and kick only the CPUs that are due (`vm.c:344-351`).
- **Keep `timer_due` current:** update it in the CNTV/CNTP write path too (`sysreg.c:245-255`), and signal the kicker when a new deadline is earlier.
- **Polling floor:** `HV_KICK_US`, default 1000; try 2000–4000.
- **GIC:** in `hv_gicv3_set_ppi` (`gicv3.c:395-404`), check the level before taking the lock (only the owning CPU changes its PPIs).
- **Gain:** 1–3% CPU, plus noticeably fewer wakeups (thermal); better timer precision.
- **Risk:** latency regressions in input and audio, so keep the floor knob.
- **Effort:** 3–4 days.

**O10. Inline the hottest helper-bound system registers** (choose from the device's `S3_x_Cx_Cx_x: N reads M writes` stats lines).
Likely candidates:
- MSR SCTLR_EL1 when the M/WXN/E0E/EE bits are unchanged (xnu flips the PAC-enable bits on every switch): compare inline, store with the RES fixups, call the helper only if one of those bits changed;
- MSR CONTEXTIDR_EL1, CNTKCTL_EL1 and MDSCR_EL1;
- MRS CNTV_CTL/CVAL, with ISTATUS computed inline.

Fields must first move into the fixed area that translated code can address (free space at `0x518–0x57f`, `cpu.h:97-104`). Code: `translate_sysreg_inline` (`translate.c:1479-1559`).
- **Gain:** 1–3%. **Risk:** low. **Knob:** `HV_SYSREG_INLINE`.
- **CI:** `test_exc`/`test_jit` sysreg cases; new `bench_sysreg`.

**O11. Smaller code-cache records, so a bigger cache fits the same memory.**
- **Today:** `HvBlock` (`machine.h:43-54`, ~72 B) plus 7 slot arrays at 52 B per slot, 2 slots per block (`machine.c:101-119`).
- **Proposed:**
  - `HvBlock`: RAM index as u8, `pg` as u32, `code`/`next` as u32 offsets or indices, `jit_gen` as u16, ~40 B in all;
  - `slot_site`/`stub`/`cond` as u32 word offsets and `slot_xpa` as a u32 page index, ~28 B per slot;
  - size `max_blocks` from the measured average (~296 B per block) instead of 160 B.
- **Gain:** a full 1.5 GB cache holds ~5M blocks, so records drop from ≈930 MB to ≈510 MB. That memory can buy a larger cache or less jetsam pressure on 8 GB devices (sizing logic at `JITBootstrap.swift:62-76`).
- **Risk:** low-medium (mechanical pointer-to-offset changes). **Effort:** 1 week.
- **CI:** all tests; HV_JIT_POISON flush stress.

### Tier 2: multi-week, high value, high risk

**O12. Segmented, generational code cache with epoch-based eviction (no stop-the-world).** Builds on #186.
- **Segments:** split the region into S = 16 segments. `chunk_take` allocates 1 MB chunks from the head segment. Blocks, slots and incoming-edge lists live in per-segment pools.
- **Condemn the segment one ahead of the head, before its space is needed:**
  - (i) unpatch every recorded incoming chain from live segments, the same B-to-stub rewrite `hv_invalidate_code` already does (`machine.c:480-495`);
  - (ii) mark the segment's blocks invalid by bumping a segment generation that `hv_block_find` and the `jc` front-cache hit check (`dispatch.c:126-141`, `mmu.c:1030-1038`) both test;
  - (iii) post `HV_REQ_IJC_RESET` to all CPUs. Salt bumps are cheap, and `ret_new` empties the return tables.
- **Epoch wait:** wait until every active CPU has passed the top of `run_loop` (a per-CPU epoch, incremented at `dispatch.c:943`; parked CPUs count as passed). `hv_machine_kick_all` makes this sub-millisecond. While waiting, process requests, as `stop_the_world` does at 869.
- **Free the segment.** Also:
  - revalidate `pending_chain` against segment generations (as `dispatch.c:1020-1024` does for full flushes);
  - unlink the segment's slots from the per-page `xhead` lists (make them doubly linked).
- **Generational part (where the real CPU saving is):** a block that is retranslated after its segment was evicted (the hashed seen-bitmap at `dispatch.c:200-206` is already that signal) goes into a tenured segment set. Tenured segments are evicted only when the tenured set fills.
  - FIFO alone does not reduce total retranslation: each lap retranslates the hot working set once. It smooths the cost and removes the stop-the-world pause.
  - Tenuring means the young ring churns through one-off boot and launch code, and hot kernel and framework code stays put.
- **Gain:** removes the 13–29% post-flush dips and the stall; estimated 3–10% average plus much smoother interaction. Also allows a 1 GB cache on 8 GB devices with similar flush cost.
- **Risk:** high (stale jumps into freed code).
- **Effort:** 3–5 weeks. Start by reviewing #186: where its 112–268 ms evictions go (memsets, hash rebuild, stop-the-world) and how it keeps edges.
- **Knob:** `HV_CC_SEGMENTS` (0 = today's full flush, kept as fallback), `HV_CC_TENURE`.
- **CI:** all tests with `HV_JIT_CAP=1..4` (forces constant evictions) plus `HV_JIT_POISON=1`, so a stale jump faults immediately; `bench_flush`; a 3-thread stress run that also chains and posts TLBIs.
- **Device:** a long session (≥20 minutes) with flush/evict counts and the `translate%` time series.

**O13. Fast SVC/ERET thunks.**
- **SVC thunk (EL0 to EL1):**
  - Writes SPSR, ELR, ESR (`EC_SVC64`) and the SP banks.
  - Masks DAIF and sets PAN/SSBS per SCTLR, as `hv_take_exception` does (`exception.c:45-73`).
  - Clears the exclusive monitor.
  - Looks up pc = VBAR + 0x400 in the EL1|SPX|PAN IJC table with the kernel salt.
  - Falls back to the helper on a miss.
- **ERET thunk:**
  - Restores PSTATE from SPSR and switches SP banks.
  - Falls back to the dispatcher if an interrupt is pending and unmasked, `exit_req` is set, or `timer_due` has passed.
  - Otherwise does an IJC lookup with the target's flags.
- These skip `hv_helper_entry`'s full save/restore and the C call. Code: `translate.c:1728-1736`, `fast_resume` (`dispatch.c:279-305`), `enter.S`.
- **Gain:** estimated 3–6% on syscall- and Mach-message-heavy GUI work.
- **Risk:** medium-high. **Effort:** 1.5–2 weeks.
- **Knob:** `HV_FAST_EXC`.
- **CI:** `test_exc` plus a new `bench_syscall` (an EL0 SVC to EL1 ERET loop).
- **Done (no knob):** SVC, ERET and WFE carry `HV_OP_LIGHT`; `hv_helper_thunk` sends them to `hv_light` (`core/light.c`,
  `-mgeneral-regs-only`, a root of `tools/simd_gate.py`), saving only x0-x17, NZCV and SP. It commits the exception or
  ERET (`hv_exception_enter`, `hv_eret`), then `hv_resume` (was `fast_resume`) goes on at the cached block without an
  ISB, or leaves for the dispatcher. Only a logged SVC (log level 2 or more, trace) falls back to the full helper. Tested by
  `test_exc` "el0 svc" (MMU on, kernel vectors in TTBR1) and `test_mp` "spinlock" (WFE).

**O14. Cheaper dispatcher round trip.**
- **Lazy FP:** `hv_exit` does not save the Q registers and sets `fp_live`. The hot dispatcher loop moves to a `-mgeneral-regs-only` file, like `mmu.c` (`Makefile:69-70`). Every call that may use SIMD must save FP first: device tick, translation (`memcpy`), `print_stats`, WFI, and `hv_tlb_flush`'s `memset`.
- **ISB elision in `hv_enter`:** skip it when the block was made by this CPU, or was published before this CPU's last ISB (per-CPU ISB epoch).
- **Gain:** 1–5%, depending on the dispatcher entry rate. Measure the rate first: `entries %.2fM/s` and the `why` breakdown at `dispatch.c:742-744`.
- **Risk:** medium-high (silent FP corruption). Mitigate with an `HV_FP_GUARD` debug knob that checksums Q0–Q31 across each round trip, on in all CI tests.
- **Knob:** `HV_LAZY_FP`.

**O15. 16-byte TLB entries (experiment).**
- **Mechanism:** separate R and W tables of {tag, addend} (16 B) and an X table of 8 B, so one 128 B line holds 8 neighbouring pages instead of 4.
- **Placement:** put the TLB at a 4 KB-aligned `HvCpu` offset, so one `add ..., lsl #12` covers the table select for every EL.
- **Emitted sequence:** use `ldp` for tag and addend; A is free when the address register is used directly. That gives 8 instructions for all tables (today 8 for EL0, 9 for EL1) with one load before the access instead of two.
- **Uncertainty:** pages that are both loaded and stored now touch 2 lines instead of 1. Estimated −2 to +8%, so device data decides.
- **Change points:** `put_tlb_slot`, `cross_addend`, every `mmu.c` fill/flush/stash/remote-drop path, `wfe()` (`dispatch.c:235`). Switch only at a flush, like `HV_TLBT` (`dispatch.c:20-27`).
- **Knob:** `HV_TLB16`. **Effort:** 1.5 weeks.

**O16. Warm start after Instant Resume.**
- At save time (`host/snapshot.c`), write a list of (va, pa, flags) for live blocks, most recently used first, capped at ~200K.
- At resume, utility-QoS threads pre-translate the list while vCPUs start; they set `code_pages` directly. With no `hv_self`, `cross_addend` returns 0, so only same-page chains are made, which is still correct.
- **Gain:** removes the post-resume translation storm, using idle E-cores.
- **Risk:** low-medium. **Effort:** 1 week. **Knob:** `HV_RESUME_WARM`.

### Tier 3: research and experiments

- **O17. Thermal policy.** Today thermal state is only logged (`SessionView.swift:662-666`). Proposal: at `.serious`, (a) cap the number of vCPU threads running at once to N−1 with an N-ary version of the big lock at `run_loop` top, and/or (b) switch the guest display to 30 Hz. (b) needs a live mode change through `pvg_lite`; `HV_HZ` is read only at start today. Knob `HV_THERMAL`. Gain unknown; needs a sustained 10-minute A/B.
- **O18. Tiered JIT.** Retranslate blocks that the 100 Hz PC sampler (based on `host/prof_ios.c`) finds hot, with superblocks, groups, cross-iteration TLB hoisting, and guest x6/x7/x15 kept in host registers where they are dead. Large effort; do it after O5/O6/O12.
- **O19. Kernel physmap fast path (loads only).**
  - xnu maps all of RAM linearly in the physmap. Kernel loads that fall in that window could use a range check plus a constant addend instead of a TLB load.
  - Stores must keep the TLB path because of code-page write detection.
  - First collect `HV_KVA_HIST` data (`mmu.c:596-626`) to see what share of kernel fills land there. Doing it safely requires detecting the window from page tables and revalidating it on TLBIs.
- **O20. Inline monomorphic cache at BR/BLR sites:** a patched compare against the last target VA, plus an exec-tag check, plus a direct `B`. About 8 instructions and 1 dependent load instead of 14 and 4. Gain 1–2%.
- **O21. Make AUT* a no-op** (`HV_PAC_NOSTRIP`, `translate.c:687-692`): saves 2 instructions per arm64e epilogue (~0.5–1%). Keep `XPAC*`.
- **O22. Incremental GIC updates:** recompute only the CPU that changed on PPI/SGI/IAR/EOI instead of all CPUs (`gicv3.c:77-87`). Gain 0.5–2%.

### Feasibility notes on the topics you listed

**Fastmem, region-based direct mapping, ASID-tagged inline TLB:**
- **Full guest-VA "fastmem" is not feasible without EVA (and not really with it).**
  - **Address space.** The guest's address spaces are sparse 48-bit spaces (user, kernel at 0xfffffe…). Henge's VA is already mostly taken by guest RAM (3 GB), the JIT RX and RW views (1–1.5 GB each, `henge-ios-jit.c:473-475`), and IJC tables (64 MB per vCPU, `machine.c:122`), inside a window of a few GB.
  - **Context switches.** macOS switches processes thousands of times a second. Mirroring a process's mappings would take thousands of 16 KB `vm_remap` calls per switch.
  - **What remains feasible:** only the constant-offset windows of O19.
- **ASID tagging in the inline check:** it would add 2 instructions to every access (the current ASID id has to be folded into the address). The existing per-TTBR0 stashes (`mmu.c:1203-1292`) are the better trade-off; tune `HV_STASHES`/`CAP` from stash hit statistics.
- **Bigger direct-mapped TLB:** the TLBT evidence says cache footprint hurts more than capacity helps. Prefer the victim TLB and walk cache (O7).

**Persisting translations across launches:**
- **Mechanically possible under TXM:** loaded bytes can be written into the RW alias of each launch's debugger-granted region.
- **Semantically invalid across cold boots:** the kernel slide (KASLR) and the shared-region slide change the guest VAs that are embedded everywhere (exit target literals, return addresses, ADR results).
- **Not position-independent:** emitted code also contains absolute host pointers (chain stub slot address at `translate.c:460-461`, `ram->host`/`code_pages` at 1240/1247).
- **Instant Resume:** VAs are identical there, but O16 recovers most of the benefit without relocation or gigabyte-sized writes.
- **Verdict:** reject persistence for cold boots; do O16.

**Memory backing:**
- Keep guest RAM outside the footprint via ledger tagging (`vmapple.c:174-197`); it is anonymous and has no I/O.
- Use file-backed RAM (`HV_RAM_FILE`) only as a fallback: kernel write-back of a shared mapping causes latency spikes.
- Record which route was used in the benchmark line.

---

## 4. Measurement harness

### 4.1 CI perf gate on the macOS arm64 runner

**Makefile:**
- New `core-test` target that builds and runs only `$(TESTS)`. Today `test` depends on `all`, which pulls in Homebrew libslirp and the restore stack (`Makefile:17,118-119`).
- New `bench` target that builds `build/test_bench`, `build/test_bench_mp` and `build/test_xlate`.
- Keep `ulimit -s 65520`.

**`tests/test_bench.c` extensions:**
- **Options:** `--reps N` (default 21), `--json FILE`, `--filter`, `--knob NAME=V` (calls `hv_knob_set` on a fresh machine), `--chain 0` (forces every block through the dispatcher, to measure round-trip cost directly), `--jitcap MB`.
- **Timing pass:** stats off; record min, median and MAD of JIT time and native time, plus the jit/native ratio. The ratio is measured within one process, so it cancels runner frequency drift.
- **Counting pass:** `stats_interval=1`; deterministic counters: dispatcher entries, helper calls per op, slow memory accesses, refills, IJC fills, translations, and hot/cold/pool words per guest instruction.

**New programs in `tests/bench_programs.S`:**
- `bench_tlb_hot`: loads over 512 pages, so TLB entries are L2-resident.
- `bench_tlb_conflict`: two pages 256 MB apart. Register a lazily touched 512 MB RAM region; with the MMU off, guest PA = host address, as in `harness.h:196-218`.
- `bench_pairs`: memcpy-like LDP/STP of Q registers, which exercises groups.
- `bench_stack`: many small functions with pre/post-index prologues across pages.
- `bench_indirect_poly`: a 64-target jump table driven by an LCG.
- `bench_syscall`: EL0 SVC to EL1 ERET, reusing the vector setup from `test_exc`.
- `bench_sysreg`: non-inlined MSR/MRS.
- `bench_flush`: the working set is larger than `--jitcap`.

**`tests/test_bench_mp.c`:** 1, 2 and 3 threads on one `HvMachine`, each looping, with an optional `TLBI VAE1IS`/`ASIDE1IS` every K iterations. Reports per-thread throughput scaling and ack-wait time. Covers O1, O4 and O8.

**`tests/test_xlate.c`:** translation throughput in ns per guest instruction, translating the encoding corpus in `tests/classify_cases.s` repeatedly with `hv_translate_emit` and `hv_translate_place`.

**Differential fuzzer:** random memory-op sequences (bases near page ends, sizes 1–64, pre/post-index, pairs, stolen registers) run natively and through the JIT and compared with `compare_cpus` (`harness.h:130-160`). This is the safety net for O5, O6, O7 and O15.

**Workflow `.github/workflows/perf.yml`** (`runs-on: xcode-27`):
1. **Correctness matrix job:** `make core-test` under each of:
   - default;
   - `HV_GROUPS=1` and `=2`;
   - `HV_SUPERBLOCKS=1`, `HV_HOIST_CHECK=1`, `HV_TLBT=0`, `HV_MOVIMM=1`, `HV_SYNC_WAIT=1`;
   - `HV_JIT_CAP=2 HV_JIT_POISON=1`;
   - every new knob, plus `HV_FP_GUARD=1`.
   This needs F1 first, or the matrix tests nothing.
2. **Bench job:**
   - Check out the PR head and the merge base into separate folders and build both.
   - `tools/bench_compare.py` runs 25 rounds in ABBA order (alternating order cancels drift).
   - Per program: median of (head/base) of the jit/native ratio, with a bootstrap 95% confidence interval.
   - **Fail** if the median is above 1.05 and the CI's lower bound is above 1.0. **Warn** above 1.02.
   - **Deterministic counter gate:** fail if hot words per guest instruction rise by more than 1% or dispatcher entries rise, unless the PR carries a `perf-expected` label.
   - Write a table to `$GITHUB_STEP_SUMMARY` and upload the JSON as an artifact for history.
3. **Caveats:** runners are small virtualized M1/M2 machines, so results are relative. Instruction-count and code-size wins transfer to the phone. Cache-footprint changes (O15) must be confirmed on the device.

### 4.2 On-device one-tap benchmark (Autopilot)

**Native side:** new `henge_vm_perf(HengePerf*)` in `ios/Henge/Native/henge-vm.c` returning summed per-CPU counters (after O4):
- wall time and each vCPU thread's CPU time (`thread_info` on `pc_state->thread`);
- WFI idle %, dispatcher entries, translated instructions and translate %;
- full flushes and evictions, TLBI wait %, helper calls/s, slow memory/s, GPU frames, net frames;
- the knob/env hash, `P_TRACED`, and which RAM route was used.

**New Autopilot commands** (`Autopilot.swift:61-171`):
- `bench begin NAME` and `bench end NAME` (log the deltas);
- `waitfor frames N SECS` (uses `henge_vm_gpu_frames`);
- `waitfor settled SECS` (vCPUs ≥85% idle for 5 s in a row);
- `waitfor nominal SECS` (thermal state);
- `readfile NAME`: logs the first line of a file the guest uploaded to the share, e.g. with `curl -T r.txt http://10.0.2.4/`;
- `bench summary`.

**One tap:** Settings → Performance → "Run benchmark".
- It runs a bundled script (`Resources/bench-v1.txt`). Requires a small refactor so `Autopilot.run` can start from a button, not only from the launch-time `enabled` flag (`Autopilot.swift:31-37`).
- Script sequence:
  1. wait for nominal thermal state;
  2. cold-boot the last-used Mac;
  3. measure boot to first frame, then boot to settled (needs auto-login in the guest);
  4. open Terminal with `cmd space` and run a fixed workload: a process-spawn loop plus an `awk` CPU loop, timed with `/usr/bin/time` and uploaded via curl to the share;
  5. run a 30 s animation phase (Mission Control toggles) and record fps;
  6. log the summary line and stop the Mac.
- The app shows the line with a Copy button.
- "A/B mode": repeats the workload ABAB with `knob` switches and `wait 120` cooldowns. Changes to env-type knobs are collected into separate runs (they need a Mac restart).

**Summary line**, one line in `henge.log`, ready to paste into an issue:
```
HENGE-BENCH v1 build=7b55730+<sha> dev=iPhone17,1 ios=27.2.1 cpus=3 cc=1024 ram=3072 env=<hash> traced=0 ram=ledger |
boot_frame=48.2 boot_settled=131.0 wl_spawn=22.4 wl_awk=9.8 fps=21.3 | busy=2.41c idle=38% xlate=6.1% flush=1 evict=0
tlbi_wait=3.2% helper=410K/s slow=95K/s disp=1.9M/s | thermal=nominal>fair batt=82%c
```
**Protocol for the user:** same charging state each time, other apps closed, start only at nominal thermal state. Report the median of at least 3 workload repetitions per knob value, and discard runs that started at `.serious`.

---

## 5. Staging

**Stage 0 (week 1): harness and free wins**
- F1 and F2 (knob plumbing), `core-test` target and `perf.yml`, the test_bench extensions, the fuzzer.
- The device benchmark command plus one-tap button.
- O1 (SYNC_WAIT default) and O2 (cheap stats).
- First device round: baseline plus the O3 sweeps (cpus, QoS, GROUPS, HOIST, SUPERBLOCKS, RANGE_DROP, WFI_SPIN, cache size). Choose the defaults from this data.

**Stage 1 (weeks 2–5): most gain per unit of effort**
O4 per-CPU stats → O7a pre/post refill → O8a/b → O9 → O6 Groups v2 → O5 compact OOL → O10 (driven by `reg_hist` data) → O11 smaller records. Then turn `HV_GROUPS=2` on by default.

**Stage 2 (weeks 6–12): structural work**
- O12 segmented/generational cache: rebase or review #186, add epochs and tenuring, flush-stress it in CI, then run long device sessions.
- O13 fast SVC/ERET.
- O8c (ASID TLBI without waiting).
- O7b/c only if the conflict-miss and walk statistics justify them.
- O14 if dispatcher entries are ≥1M/s per CPU.
- O15 as an A/B experiment.
- O16 warm resume.

**Stage 3 (later):** O17 thermal policy, O18 tiered JIT, O19 physmap fast path (after `HV_KVA_HIST` data), O20, O21, O22.

**Rejected, with reasons:**
- **Rust rewrite:** no speed gain, months of work, loses upstream sync (section 0).
- **Guest-VA fastmem or VA mirroring:** not enough address space without EVA, and remapping at macOS context-switch rates is impossible.
- **Persistent code cache across cold boots:** KASLR and shared-region slides, absolute host pointers in emitted code.
- **ASID-tagged inline TLB check:** +2 instructions on every access.
- **Larger direct-mapped TLB:** cache footprint already dominates.
- **`HV_SWITCH_FLUSH` on by default:** upstream found stale entries on the phone (`machine.c:30-33`).
- **Big lock, keeping the debugger attached, 120 Hz by default, file-backed RAM by default.**
- **Speculatively translating code that has not run yet:** wastes the 2 P-cores.

**Upstream sync rule:** each item is a small, knob-guarded patch series in the style of `hv_knob`, rebased on upstream and offered upstream. This keeps the fork's maintenance cost low and lets the community's device results confirm the gains.

### Critical Files for Implementation
- C:/Users/owner/AppData/Local/Temp/claude/09d7ec978abda851/a4153b16-327b-44b9-a024-ab3d3e5fe0ef/scratchpad/henge-src/Henge/core/translate.c
- C:/Users/owner/AppData/Local/Temp/claude/09d7ec978abda851/a4153b16-327b-44b9-a024-ab3d3e5fe0ef/scratchpad/henge-src/Henge/core/dispatch.c
- C:/Users/owner/AppData/Local/Temp/claude/09d7ec978abda851/a4153b16-327b-44b9-a024-ab3d3e5fe0ef/scratchpad/henge-src/Henge/core/mmu.c
- C:/Users/owner/AppData/Local/Temp/claude/09d7ec978abda851/a4153b16-327b-44b9-a024-ab3d3e5fe0ef/scratchpad/henge-src/Henge/host/enter.S
- C:/Users/owner/AppData/Local/Temp/claude/09d7ec978abda851/a4153b16-327b-44b9-a024-ab3d3e5fe0ef/scratchpad/henge-src/Henge/core/machine.c (with core/machine.h, tests/test_bench.c and ios/Henge/Autopilot.swift for the harness)
