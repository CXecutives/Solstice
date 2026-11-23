/* The engine's measurements: the stats line, the --profile summary, and rates read by the app (stats.h). */
#include "stats.h"
#include "knobs.h"

#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dispatch.h"
#include "translate.h"

uint64_t hv_reg_hist[65536];

double hv_stats_blocks_rate(HvMachine *m, HvRateMark *mark, uint64_t now) {
    uint64_t blocks = hv_stat_blocks(m);
    double rate = mark->ticks && now > mark->ticks && blocks >= mark->blocks /* (another machine since) */
                      ? (double)(blocks - mark->blocks) * 24e6 / (double)(now - mark->ticks)
                      : 0;
    mark->blocks = blocks;
    mark->ticks = now;
    return rate;
}

/* --profile: which guest blocks the sampled host PCs were in (hv_block_at). */
static void print_profile(HvMachine *m) {
    enum { SLOTS = 4096 };
    static struct { uint64_t va; uint32_t flags, n, ninsns; } top[SLOTS];
    memset(top, 0, sizeof top);
    uint32_t total = 0, outside = 0;
    static struct { const char *name; uint32_t n; } fn[64];
    static struct { uint32_t off, n; } run_off[256];
    int nfn = 0, nrun = 0;
    uint32_t head = __atomic_load_n(&m->prof_head, __ATOMIC_ACQUIRE);
    if (head - m->prof_tail > HV_PROF_RING) m->prof_tail = head - HV_PROF_RING;
    for (; m->prof_tail != head; m->prof_tail++) {
        uint32_t *pc = (uint32_t *)(uintptr_t)m->prof[m->prof_tail & (HV_PROF_RING - 1)];
        total++;
        HvBlock *b = pc >= m->jit.base && pc < m->jit.base + m->jit.used ? hv_block_at(m, pc) : NULL;
        if (!b) {
            outside++;
            Dl_info di;
            const char *name = dladdr(pc, &di) && di.dli_sname ? di.dli_sname : "?";
            const char *detail = hv_knob.prof_fn;
            if (!strcmp(name, detail)) { /* per-offset detail for one function (HV_PROF_FN, default the dispatcher loop) */
                uint32_t off = (uint32_t)((uint8_t *)pc - (uint8_t *)di.dli_saddr);
                int r = 0;
                while (r < nrun && run_off[r].off != off) r++;
                if (r == nrun && nrun < 256) { run_off[nrun].off = off; run_off[nrun++].n = 0; }
                if (r < nrun) run_off[r].n++;
            }
            int k = 0;
            while (k < nfn && strcmp(fn[k].name, name)) k++;
            if (k == nfn && nfn < 64) { fn[nfn].name = name; fn[nfn++].n = 0; }
            if (k < nfn) fn[k].n++;
            continue;
        }
        uint32_t h = (uint32_t)((b->va >> 2) ^ b->flags) & (SLOTS - 1);
        int probes = 0;
        while (top[h].n && (top[h].va != b->va || top[h].flags != b->flags) && ++probes < 64) h = (h + 1) & (SLOTS - 1);
        if (probes == 64) continue; /* table full: the block is too cold to make the list anyway */
        top[h].va = b->va;
        top[h].flags = b->flags;
        top[h].ninsns = b->ninsns;
        top[h].n++;
    }
    if (!total) return;
    fprintf(stderr, "  profile: %u samples, %.0f%% outside translated code:", total, 100.0 * outside / total);
    for (int k = 0; k < 10; k++) {
        int best = -1;
        for (int i = 0; i < nfn; i++)
            if (fn[i].n && (best < 0 || fn[i].n > fn[best].n)) best = i;
        if (best < 0) break;
        fprintf(stderr, " %s %.1f%%", fn[best].name, 100.0 * fn[best].n / total);
        fn[best].n = 0;
    }
    fprintf(stderr, "\n  %s+:", hv_knob.prof_fn);
    for (int k = 0; k < 12; k++) {
        int best = -1;
        for (int i = 0; i < nrun; i++)
            if (run_off[i].n && (best < 0 || run_off[i].n > run_off[best].n)) best = i;
        if (best < 0) break;
        fprintf(stderr, " %#x:%.1f%%", run_off[best].off, 100.0 * run_off[best].n / total);
        run_off[best].n = 0;
    }
    fprintf(stderr, "\n");
    for (int k = 0; k < 12; k++) {
        int best = -1;
        for (int i = 0; i < SLOTS; i++)
            if (top[i].n && (best < 0 || top[i].n > top[best].n)) best = i;
        if (best < 0 || top[best].n * 200 < total) break;
        fprintf(stderr, "    %5.1f%%  %llx el%u (%u insns)\n", 100.0 * top[best].n / total,
                (unsigned long long)top[best].va, top[best].flags & HV_BLOCK_EL1, top[best].ninsns);
        top[best].n = 0;
    }
}

void (*hv_stats_io)(double seconds);

uint64_t hv_stats_lines;

/* Printed by whichever CPU first finds the line due (hv_stats_tick), so one at a time: the statics are its own. */
static void print_stats(HvCpu *cpu) {
    static uint64_t last_t, start_t;
    /* This uses floating point, and the host FP registers hold the guest's state. */
    hv_fp_leave(cpu);
    uint64_t zero = 0;
    __asm__ volatile("msr fpcr, %0" ::"r"(zero));
    static HvStats last;
    HvMachine *m = cpu->m;
    uint64_t now = mach_absolute_time();
    static HvStats sum;
    hv_stats_total(m, &sum);
    static const HvMachine *last_m;
    if (!start_t || m != last_m || sum.blocks < last.blocks) { /* the first interval (of this machine) starts here */
        last_m = m;
        start_t = last_t = now;
        last = sum;
        hv_fp_enter(cpu);
        return;
    }
    hv_stats_lines++;
    double dt = (double)(now - last_t) / 24e6;
    HvStats *s = &sum;
#define RATE(f) ((double)(s->f - last.f) / dt)
    fprintf(stderr,
            "stats %5.0fs: blocks %.2fM/s, translated %.0f/s (again: va %.0f%% va+pa %.0f%%; %.0f%% of time, %.1f insns, %.1fx), slow mem %.0fK/s, mrs %.0fK/s msr %.0fK/s sys %.0fK/s, "
            "exc %.0f/s irq %.0f/s, tlb flush %.0f/s, fetch walks %.0fK/s, wfi %.0f/s (%.0f%% idle), flushes %.0f/s (smc %.0f ic %.0f full %.0f), blocks held %d (%.0f MB, %llu full flushes), chained %.0f/s ijc fills %.0fK/s resets %.0f/s, el%u pc %llx\n",
            (double)(now - start_t) / 24e6, RATE(blocks) / 1e6, RATE(translations), 100.0 * RATE(retrans_va) / (RATE(translations) + 1e-9), 100.0 * RATE(retrans_vapa) / (RATE(translations) + 1e-9), 100.0 * (double)(s->translate_ticks - last.translate_ticks) / (double)(now - last_t), RATE(translated_insns) / (RATE(translations) + 1e-9), RATE(translated_words) / (RATE(translated_insns) + 1e-9), RATE(helper[HV_OP_MEM]) / 1e3,
            RATE(helper[HV_OP_MRS]) / 1e3, RATE(helper[HV_OP_MSR]) / 1e3, RATE(helper[HV_OP_SYS]) / 1e3,
            RATE(exceptions), RATE(interrupts), RATE(tlb_flushes), RATE(fetch_walks) / 1e3, RATE(wfi),
            100.0 * (double)(s->wfi_ticks - last.wfi_ticks) / (double)(now - last_t), RATE(block_flushes), RATE(flush_smc),
            RATE(flush_ic), RATE(flush_full), m->nblocks, (double)m->jit.used * 4 / (1 << 20), (unsigned long long)s->flush_full, RATE(chained), RATE(ijc_fills) / 1e3, RATE(ijc_resets), cpu->el,
            (unsigned long long)cpu->pc);
    if (m->cc.nseg) { /* totals since the start (codecache.c) */
        const HvCodeCache *cc = &m->cc;
        fprintf(stderr, "  code cache: %u segments of %llu KB; %llu evictions (%llu tenured), %.0f ms of work, %llu blocks dropped, "
                        "%llu exits unchained; %llu waits for room (%.0f ms); %llu tenured translations, %llu redone; "
                        "branch caches caught up: %llu scanned (%llu more than one epoch behind; %.0f ms, %llu entries dropped), "
                        "%llu reset; %llu second chances\n",
                cc->nseg, (unsigned long long)(4ull << cc->seg_shift) >> 10, (unsigned long long)cc->evictions,
                (unsigned long long)cc->evict_tenured, (double)cc->evict_ticks / 24e3, (unsigned long long)cc->evict_blocks,
                (unsigned long long)cc->evict_unchained, (unsigned long long)cc->waits, (double)cc->wait_ticks / 24e3,
                (unsigned long long)s->cc_tenured, (unsigned long long)cc->stale, (unsigned long long)cc->ijc_scans, (unsigned long long)cc->ijc_behind,
                (double)cc->ijc_scan_ticks / 24e3, (unsigned long long)cc->ijc_dropped, (unsigned long long)cc->ijc_resets,
                (unsigned long long)cc->second_chances);
    }
    {
        double tot = 0;
        for (int k = 0; k < 6; k++) tot += RATE(why[k]);
        /* How much of the time since it last printed the printing CPU's thread actually ran: below 100% means the host
           took it away. */
        static double last_busy[HV_MAX_CPUS];
        static uint64_t last_busy_t[HV_MAX_CPUS];
        uint32_t me = cpu->index < HV_MAX_CPUS ? cpu->index : 0;
        thread_basic_info_data_t ti;
        mach_msg_type_number_t cnt = THREAD_BASIC_INFO_COUNT;
        mach_port_t self = mach_thread_self();
        if (thread_info(self, THREAD_BASIC_INFO, (thread_info_t)&ti, &cnt) == KERN_SUCCESS) {
            double busy = ti.user_time.seconds + ti.user_time.microseconds / 1e6 + ti.system_time.seconds +
                          ti.system_time.microseconds / 1e6;
            if (last_busy_t[me])
                fprintf(stderr, "  cpu %u's thread ran %.0f%% of the time since it last printed\n", me,
                        100 * (busy - last_busy[me]) / ((double)(now - last_busy_t[me]) / 24e6));
            last_busy_t[me] = now;
            if (m->ncpus > 1) {
                fprintf(stderr, "  cpus:");
                for (int i = 0; i < m->ncpus; i++)
                    if (m->cpus[i])
                        fprintf(stderr, " [%d] %s el%u pc %llx", i, m->cpus[i]->off ? "off" : "on", m->cpus[i]->el,
                                (unsigned long long)m->cpus[i]->pc);
                fprintf(stderr, "\n");
            }
            last_busy[me] = busy;
        }
        mach_port_deallocate(mach_task_self(), self);
        fprintf(stderr, "  whole-TLB flushes/s: TLBI all here %.0f, TLBI all shared %.0f, SCTLR %.0f, TTBR1 %.0f, TCR %.0f, MAIR %.0f, range of all %.0f, requests overflowed %.0f\n",
                RATE(flush_why[0]), RATE(flush_why[1]), RATE(flush_why[2]), RATE(flush_why[3]), RATE(flush_why[4]), RATE(flush_why[5]),
                RATE(flush_why[6]), RATE(flush_why[7]));
        fprintf(stderr, "  TLBI all here/s by time since a TTBR0 change: <2us %.0f, <20us %.0f, <200us %.0f, later %.0f; left out %.0f (%.0f of them late); at",
                RATE(flush_after_switch[0]), RATE(flush_after_switch[1]), RATE(flush_after_switch[2]), RATE(flush_after_switch[3]), RATE(flush_skipped),
                RATE(flush_skipped_late));
        for (int i = 0; i < 8 && s->flush_pc[i].pc; i++) fprintf(stderr, " %llx x%llu", (unsigned long long)s->flush_pc[i].pc, (unsigned long long)s->flush_pc[i].n);
        fprintf(stderr, "\n");
        if (s->flush_checked)
            fprintf(stderr, "  switch-flush checks/s: %.0f, entries walked %.0f, found out of date %.0f (flushed), access flag only %.0f\n",
                    RATE(flush_checked), RATE(flush_check_entries), RATE(flush_check_bad), RATE(flush_check_af));
        fprintf(stderr, "  cache drops/s: full %.0f, ASID %.0f, user VA %.0f, kernel VA %.0f, code %.0f (whole user half %.0f, filter full %.0f, big user range %.0f)\n", RATE(reset_why[0]),
                RATE(reset_why[1]), RATE(reset_why[2]), RATE(reset_why[3]), RATE(reset_why[4]), RATE(reset_why[5]), RATE(reset_why[6]), RATE(reset_why[7]));
        if (m->stats_deep) { /* block hash health: chain lengths and how much of it is stale (walks every block) */
            uint64_t used = 0, stale = 0, maxlen = 0, sumsq = 0;
            uint32_t worst = 0;
            for (uint32_t h = 0; h <= m->hash_mask; h++) {
                uint64_t len = 0;
                for (uint32_t i = m->hash[h]; i; i = m->blocks[i].next) {
                    len++;
                    if (*hv_block_gen(m, &m->blocks[i]) != m->blocks[i].gen) stale++;
                }
                if (len) used++;
                sumsq += len * len;
                if (len > maxlen) maxlen = len, worst = h;
            }
            fprintf(stderr, "  block hash: %llu buckets used, %llu stale blocks, max chain %llu, mean walk %.1f\n",
                    (unsigned long long)used, (unsigned long long)stale, (unsigned long long)maxlen,
                    m->nblocks ? (double)sumsq / m->nblocks : 0.0);
            int k = 0;
            for (uint32_t i = m->hash[worst]; i && k < 6; i = m->blocks[i].next, k++)
                fprintf(stderr, "    worst: va %llx pa %llx flags %x gen %u/%u\n", (unsigned long long)m->blocks[i].va,
                        (unsigned long long)m->blocks[i].pa, m->blocks[i].flags, m->blocks[i].gen, *hv_block_gen(m, &m->blocks[i]));
        }
        {
            double tw = RATE(words_inline) + RATE(words_ool) + RATE(words_pool) + 1e-9;
            double ti = RATE(translated_insns) + 1e-9;
            fprintf(stderr, "  code words: inline %.0f%% out of line %.0f%% literals %.0f%%; per guest insn: inline %.2f, out of "
                            "line %.2f (exits %.2f, slow paths %.2f, group copies %.2f, branch-cache misses %.2f, other %.2f), "
                            "literals %.2f\n",
                    100 * RATE(words_inline) / tw, 100 * RATE(words_ool) / tw, 100 * RATE(words_pool) / tw,
                    RATE(words_inline) / ti, RATE(words_ool) / ti, RATE(words_cold[HV_COLD_EXIT]) / ti,
                    RATE(words_cold[HV_COLD_SLOW]) / ti, RATE(words_cold[HV_COLD_GROUP]) / ti,
                    RATE(words_cold[HV_COLD_IJC]) / ti, RATE(words_cold[HV_COLD_OTHER]) / ti, RATE(words_pool) / ti);
        }
        fprintf(stderr, "  new code pages %.0f/s; waits: tlbi acks %.0f/s %.1f%%, device lock %.0f/s %.1f%%, translation lock %.0f/s %.1f%% (of one CPU)\n",
                RATE(code_protects), RATE(syncs), RATE(sync_ticks) / 240000.0, RATE(dev_waits), RATE(dev_wait_ticks) / 240000.0,
                RATE(tr_waits), RATE(tr_wait_ticks) / 240000.0);
        {
            double l = RATE(syncs) + 1e-9;
            fprintf(stderr, "  tlbi ack waits by length/s: <10us %.0f (%.1f%%), <100us %.0f (%.1f%%), <1ms %.0f (%.1f%%), longer %.0f (%.1f%%); "
                            "at 100 us the CPU waited for was: off a core %.0f, on one %.0f (mid walk %.0f, mid cache fill %.0f)\n",
                    RATE(sync_len[0]), RATE(sync_len_ticks[0]) / 240000.0, RATE(sync_len[1]), RATE(sync_len_ticks[1]) / 240000.0,
                    RATE(sync_len[2]), RATE(sync_len_ticks[2]) / 240000.0, RATE(sync_len[3]), RATE(sync_len_ticks[3]) / 240000.0,
                    RATE(sync_probe[0]), RATE(sync_probe[1]), RATE(sync_probe[2]), RATE(sync_probe[3]));
            fprintf(stderr, "  at 1 ms the CPU waited for was/s: running %.1f, translating %.1f, in a helper %.1f, waiting for acks %.1f, at the flush barrier %.1f, off a core %.1f\n",
                    RATE(sync_phase[0]), RATE(sync_phase[1]), RATE(sync_phase[2]), RATE(sync_phase[3]), RATE(sync_phase[4]), RATE(sync_phase[5]));
            (void)l;
        }
        fprintf(stderr, "  light lookups failed/s: odd %.0f, filters full %.0f, no mapping %.0f, no block yet %.0f; walked %.0fK/s\n",
                RATE(light_fail[0]), RATE(light_fail[1]), RATE(light_fail[2]), RATE(light_fail[3]), RATE(light_walks) / 1e3);
        fprintf(stderr, "  big user-range TLBIs/s: %.0f TLB only in the range, %.0f with no cached targets to drop; big kernel ranges %.0f\n",
                RATE(tlb_range_flushes), RATE(range_spared), RATE(kernel_ranges));
        fprintf(stderr, "  whole branch-cache drops/s: user half %.0f, kernel half %.0f, a process's by TLBI ASID %.0f, by a range of 64 MB+ %.0f\n",
                RATE(ijc_reset_kind[0]), RATE(ijc_reset_kind[1]), RATE(ijc_reset_kind[2]), RATE(ijc_reset_kind[3]));
        fprintf(stderr, "  code changes/s: no cached target into the page %.0f, that VA page's targets dropped %.0f, all dropped %.0f\n",
                RATE(code_ijc[0]), RATE(code_ijc[1]), RATE(code_ijc[2]));
        fprintf(stderr, "  TLBIs left to other CPUs/s: raced %.0f, every address space's cached targets %.0f, big range %.0f, ASID or all %.0f\n",
                RATE(posted_kind[0]), RATE(posted_kind[3]), RATE(posted_kind[1]), RATE(posted_kind[2]));
        fprintf(stderr, "  remote drop races/s: walking %.0f, filling %.0f, during %.0f; walks of other pages let through %.0f\n", RATE(race_kind[0]), RATE(race_kind[1]), RATE(race_kind[2]),
                RATE(race_other_page));
        {
            static const char *kn[16] = {"copy", "pcrel", "branch", "branch-reg", "eret", "literal", "memory", "prefetch",
                                         "exception", "sysreg", "sys", "barrier", "wait", "pac", "undef", "?"};
            uint64_t ti = 0, tw = 0;
            for (int k = 0; k < 16; k++) ti += s->kind_insns[k] - last.kind_insns[k], tw += s->kind_words[k] - last.kind_words[k];
            if (ti) {
                fprintf(stderr, "  inline words per insn %.2f:", (double)tw / ti);
                for (int k = 0; k < 16; k++) {
                    uint64_t i = s->kind_insns[k] - last.kind_insns[k], w = s->kind_words[k] - last.kind_words[k];
                    if (i * 200 >= ti) fprintf(stderr, " %s %.0f%%x%.1f", kn[k], 100.0 * i / ti, (double)w / i);
                }
                fprintf(stderr, "\n");
            }
        }
        fprintf(stderr, "  user light fills: shared region %.0fK/s, elsewhere %.0fK/s\n", RATE(light_region[0]) / 1e3, RATE(light_region[1]) / 1e3);
        fprintf(stderr, "  code-page protects/s: none %.0f, one entry %.0f, whole-TLB scans %.0f\n", RATE(protect_kind[0]),
                RATE(protect_kind[1]), RATE(protect_kind[2]));
        fprintf(stderr, "  fast resume refused/s: state %.0f, exit request %.0f, interrupt %.0f, timer %.0f, not cached %.0f\n", RATE(fr_fail[0]),
                RATE(fr_fail[1]), RATE(fr_fail[2]), RATE(fr_fail[3]), RATE(fr_fail[4]));
        fprintf(stderr, "  WFE waits in place %.0f/s; exits chained as placed %.0f/s; SVC/ERET resumed in place %.0f/s; fetched again after a translation %.0f/s\n", RATE(wfe_waits),
                RATE(chained_early), RATE(fast_resumes), RATE(retranslated));
        fprintf(stderr, "  exit requests/s: TLBI posts %.0f, wakes %.0f (of them device work %.0f), kick all %.0f, own %.0f\n",
                RATE(kick_src[0]), RATE(kick_src[1]), RATE(kick_src[3]), RATE(kick_src[2]), RATE(kick_src[4]));
        fprintf(stderr, "  kicker: wakeups %.0f/s, CPUs kicked at their deadline %.0f/s, for device polls %.0f/s; device polls %.0f/s\n",
                RATE(kicker_wakes), RATE(kicker_kicks), RATE(kicker_polls), RATE(dev_polls));
        fprintf(stderr, "  paravirtual ticket locks: waits for a kick %.0f/s, kicks %.0f/s\n", RATE(pv_waits), RATE(pv_kicks));
        fprintf(stderr, "  light refills %.0fK/s, light branch-cache fills %.0fK/s, chained to other pages %.0f/s\n", RATE(refills) / 1e3,
                RATE(ijc_light) / 1e3, RATE(xchained));
        fprintf(stderr, "  process switches: %.0f/s saved, %.0f/s restored, %.0f/s dropped by a TLBI (%.0f entries each)\n", RATE(stash_saves), RATE(stash_hits), RATE(stash_stale),
                s->stash_hits - last.stash_hits ? (double)(s->stash_entries - last.stash_entries) / (s->stash_hits - last.stash_hits) : 0.0);
        {   /* mmu.c: what process switches cost */
            uint64_t ur = 0;
            for (int k = 0; k < 7; k++) ur += s->user_reset_why[k] - last.user_reset_why[k];
            uint64_t ut = s->ijc_reset_kind[0] - last.ijc_reset_kind[0];
            fprintf(stderr, "  mmu refills K/s: el0 empty %.0f el0 slot taken %.0f el1 empty %.0f el1 slot taken %.0f; stashes/s: missed %.0f evicted %.0f, %.0f entries out and %.0f kept a switch\n",
                    RATE(refill_kind[0]) / 1e3, RATE(refill_kind[1]) / 1e3, RATE(refill_kind[2]) / 1e3, RATE(refill_kind[3]) / 1e3, RATE(stash_miss), RATE(stash_evict),
                    s->stash_saves - last.stash_saves ? (double)(s->stash_out - last.stash_out) / (s->stash_saves - last.stash_saves) : 0.0,
                    s->stash_saves - last.stash_saves ? (double)(s->switch_kept - last.switch_kept) / (s->stash_saves - last.stash_saves) : 0.0);
            fprintf(stderr, "  mmu user-half branch-cache resets/s: all-ASID TLBI VA %.1f, all-ASID range %.1f, whole-TLB flush %.1f, id-page set full %.1f, keyed filter full %.1f, code under several pages %.1f, ASID log full %.1f, other %.1f\n",
                    RATE(user_reset_why[0]), RATE(user_reset_why[1]), RATE(user_reset_why[2]), RATE(user_reset_why[3]), RATE(user_reset_why[4]), RATE(user_reset_why[5]),
                    RATE(user_reset_why[6]), ut > ur ? (double)(ut - ur) / dt : 0.0);
        }
        fprintf(stderr, "  tlb misses K/s: el0 empty %.0f el0 conflict %.0f el1 empty %.0f el1 conflict %.0f\n",
                RATE(tlb_miss_kind[0]) / 1e3, RATE(tlb_miss_kind[1]) / 1e3, RATE(tlb_miss_kind[2]) / 1e3, RATE(tlb_miss_kind[3]) / 1e3);
        fprintf(stderr, "  slow mem causes K/s: mmio %.0f code-page write %.0f page end %.0f tlb miss %.0f other %.0f entry-but-tag %.0f\n",
                RATE(slow_why[0]) / 1e3, RATE(slow_why[1]) / 1e3, RATE(slow_why[2]) / 1e3, RATE(slow_why[3]) / 1e3,
                RATE(slow_why[4]) / 1e3, RATE(slow_why[5]) / 1e3);
        fprintf(stderr, "  slow mem on pages mapped under 16 KB: %.0fK/s; at (MB, el)", RATE(small_pages) / 1e3);
        for (int i = 0; i < 8 && s->small_at[i].mb; i++)
            fprintf(stderr, " %llx/%d x%llu", (unsigned long long)(s->small_at[i].mb >> 1), (int)(s->small_at[i].mb & 1), (unsigned long long)s->small_at[i].n);
        fprintf(stderr, "\n");
        fprintf(stderr, "  slow mem K/s: single %.0f pair %.0f literal %.0f ldra %.0f ordered %.0f excl %.0f cas %.0f casp %.0f atomic %.0f vec %.0f/%.0f\n",
                RATE(slow_kind[0]) / 1e3, RATE(slow_kind[1]) / 1e3, RATE(slow_kind[2]) / 1e3, RATE(slow_kind[3]) / 1e3,
                RATE(slow_kind[4]) / 1e3, RATE(slow_kind[5]) / 1e3, RATE(slow_kind[6]) / 1e3, RATE(slow_kind[7]) / 1e3,
                RATE(slow_kind[8]) / 1e3, RATE(slow_kind[9]) / 1e3, RATE(slow_kind[10]) / 1e3);
        fprintf(stderr, "  ijc fills into: empty %.0fK/s, live other salt %.0fK/s, dead salt %.0fK/s, same salt %.0fK/s\n",
                RATE(fill_kind[0]) / 1e3, RATE(fill_kind[1]) / 1e3, RATE(fill_kind[3]) / 1e3, RATE(fill_kind[2]) / 1e3);
        fprintf(stderr, "  light fills into: empty %.0fK/s, live other salt %.0fK/s, dead salt %.0fK/s, same salt %.0fK/s\n",
                RATE(light_kind[0]) / 1e3, RATE(light_kind[1]) / 1e3, RATE(light_kind[3]) / 1e3, RATE(light_kind[2]) / 1e3);
        fprintf(stderr, "  misses at: RET %.0fK/s, BR/BLR %.0fK/s, B/BL %.0fK/s, conditional %.0fK/s, MSR %.0fK/s, other %.0fK/s, unknown %.0fK/s\n",
                RATE(miss_kind[0]) / 1e3, RATE(miss_kind[1]) / 1e3, RATE(miss_kind[2]) / 1e3, RATE(miss_kind[3]) / 1e3,
                RATE(miss_kind[4]) / 1e3, RATE(miss_kind[5]) / 1e3, RATE(miss_kind[6]) / 1e3);
        fprintf(stderr, "  entries %.2fM/s: chain fill %.0f%%, kick %.0f%%, exception/sysreg %.0f%%, interrupt %.0f%%, cached target %.0f%%, cache miss %.0f%%\n",
                tot / 1e6, 100 * RATE(why[0]) / tot, 100 * RATE(why[1]) / tot, 100 * RATE(why[2]) / tot,
                100 * RATE(why[3]) / tot, 100 * RATE(why[4]) / tot, 100 * RATE(why[5]) / tot);
    }
#undef RATE
    if (hv_stats_io) hv_stats_io(dt);
    if (m->prof) print_profile(m);
    /* The busiest system registers or SYS operations (reads + writes) this interval: deep stats only (the table's
       512 KB are written only then). */
    for (int k = 0; k < 14 && m->stats_deep; k++) {
        uint64_t best = 0;
        uint32_t bi = 0;
        for (uint32_t r = 0; r < 65536; r++) {
            uint64_t n = (hv_reg_hist[r] & 0xffffffff) + (hv_reg_hist[r] >> 32);
            if (n > best) best = n, bi = r;
        }
        if (!best) break;
        fprintf(stderr, "   S%u_%u_C%u_C%u_%u: %.0f reads %.0f writes/sys per s\n", bi >> 14, (bi >> 11) & 7, (bi >> 7) & 15,
                (bi >> 3) & 15, bi & 7, (double)(hv_reg_hist[bi] & 0xffffffff) / dt, (double)(hv_reg_hist[bi] >> 32) / dt);
        hv_reg_hist[bi] = 0;
    }
    if (m->stats_deep) memset(hv_reg_hist, 0, sizeof hv_reg_hist);
    last = *s;
    last_t = now;
    hv_fp_enter(cpu);
}

/* Every 4096 dispatcher entries of any CPU: is the stats line due? The CPU that moves the deadline on prints it, so the
   interval holds while CPU 0 sleeps or runs long chains (it stretched to 107-161 s of 30 on the phone). */
void hv_stats_tick(HvCpu *cpu) {
    static uint64_t due;
    uint64_t now = mach_absolute_time(), d = __atomic_load_n(&due, __ATOMIC_RELAXED);
    if (now < d) return;
    if (__atomic_compare_exchange_n(&due, &d, now + (uint64_t)cpu->m->stats_interval * 24000000ull, 0, __ATOMIC_RELAXED,
                                    __ATOMIC_RELAXED))
        print_stats(cpu);
}
