#ifndef HENGEVM_MACHINE_H
#define HENGEVM_MACHINE_H

#include <pthread.h>
#include <stdint.h>

#include "codecache.h"
#include "cpu.h"
#include "jit_region.h"

/* Guest physical memory: RAM regions backed by host memory, and MMIO regions
   handled by device callbacks. The fast path only ever sees RAM. */
typedef struct HvRam {
    uint64_t pa, size;
    uint8_t *host;
    int readonly;
    uint8_t *code_pages; /* one byte per 16 KB page: a translated block came from here (2^pages_log2 of them) */
    uint32_t pages_log2;
    uint32_t *page_gen;  /* per page: bumped to invalidate the blocks translated from it */
    /* Per page and CPU: up to three TLB entries (slot << 2 | table, plus 1;
       16 bits each) that mapped the page writable, or HV_WHINT_MANY when there
       were more. When the page becomes code only those are dropped, not a whole
       TLB scanned. */
    uint64_t *whint;     /* CPU-major: whint[cpu * npages + page], so CPUs filling the same pages write their own lines */
    /* Per page, HV_IJC_VAS slots: the VA pages (| 2) its blocks have been cached as branch targets under since its
       code last changed; 0 a free slot, ~0 in the first: more than fit. So a code change drops just those cached
       targets (hv_invalidate_code). */
    uint64_t *ijc_va;
    /* Per page: the exits from other pages chained into it (a slot + 1, 0 none), listed through HvMachine.slot_xnext,
       so its code changing unchains just those (it scanned every such exit, under the translation lock: 2.3% of the
       phone's busy time at a login, and the other CPUs waited for the lock). */
    uint32_t *xhead;
    size_t npages;
    uint64_t *code_hash; /* HV_CODE_CHECK (debugging): each code page's contents when it became code */
} HvRam;

typedef struct HvMmio {
    uint64_t pa, size;
    void *opaque;
    uint64_t (*read)(void *opaque, uint64_t off, unsigned size);
    void (*write)(void *opaque, uint64_t off, uint64_t val, unsigned size);
    const char *name;
    int self_locked;     /* the device takes its own lock (the GIC): no device lock around it */
} HvMmio;

/* A translated block's record. There is one for every block the code cache could hold (machine.c), so it is kept
   small: what a lookup compares first, then where its code is and the bucket's next block as 32-bit offsets. */
typedef struct HvBlock {
    uint64_t va, pa;
    uint32_t gen;        /* page_gen of its page when translated */
    uint32_t stag;       /* its code-cache segment's tag when placed (codecache.h): another now, and it is gone */
    uint32_t code_off;   /* its code: words from the JIT region's base (hv_block_code) */
    uint32_t next;       /* the next block in its hash bucket: an index into HvMachine.blocks, 0 at the end */
    uint32_t flags;      /* HV_BLOCK_* state the translation depends on */
    uint16_t ninsns;     /* at most HV_MAX_BLOCK_INSNS */
    uint8_t ram;         /* where its page lives (HvMachine.ram), for a quick staleness check (hv_block_gen) */
    uint8_t maker;       /* the CPU that translated it (index + 1; 0: not a CPU, as in tests) */
} HvBlock;
_Static_assert(sizeof(HvBlock) == 40, "HvBlock: 40 bytes");

#define HV_BLOCK_EL1   1u        /* translated for EL1 (selects tlb[1]) */
#define HV_BLOCK_FPOFF 2u        /* CPACR_EL1.FPEN traps FP/SIMD at this EL */
#define HV_BLOCK_SPX   4u        /* EL1 with SPSel = 1 (SP_EL1 in use, SP_EL0 banked) */
#define HV_BLOCK_PAN   8u        /* EL1 with PSTATE.PAN set (selects TLB table 2) */

#define HV_MAX_RAM 8
#define HV_IJC_VAS 4 /* VA pages a code page's cached targets are noted under (HvRam.ijc_va) */
#define HV_MAX_MMIO 48
#define HV_JC_BITS 16
#define HV_PROF_RING (1 << 16)
/* Block records and exit slots are reserved for a code cache full of blocks this small (bytes of translated code; the
   Mac's mix averages ~300): running out of records evicts a segment early, as a full cache does (codecache.c). */
#define HV_BLOCK_MIN_BYTES 240
#define HV_SLOTS_PER_BLOCK 2

/* Counters for --stats: where the time goes. Each CPU writes its own copy (HvPerCpu.own); HvMachine.stats holds what
   is counted off the CPUs (devices, the kicker), under a lock, or rarely; readers sum them (hv_stats_total). Every
   field up to small_at is a uint64_t counter (summed as such): the tables and rings after it are not summed. */
typedef struct HvStats {
    uint64_t blocks, translations, block_flushes;
    uint64_t flush_smc, flush_ic, flush_full;  /* why translations were dropped */
    uint64_t chained, ijc_fills, ijc_resets;
    uint64_t xchained;
    uint64_t kick_src[5];     /* exit_req set by: a request (TLBI), hv_cpu_wake, kick_all, hv_machine_wake, the CPU itself */        /* of them, exits to another page (TLB-checked) */
    uint64_t syncs, sync_ticks;        /* TLBI acks waited for, and host ticks spent waiting */
    uint64_t sync_len[4], sync_len_ticks[4]; /* those waits by length: under 10 us, 100 us, 1 ms, longer */
    uint64_t sync_probe[4];            /* a wait 100 us long looks at the other CPU: thread off a core, on one, mid walk, mid cache fill */
    uint64_t sync_phase[6];            /* a wait 1 ms long: the other CPU running (guest code or dispatcher), translating, in a helper,
                                          waiting for acks itself, at the flush barrier; or its thread off a core */
    uint64_t dev_waits, dev_wait_ticks; /* device lock taken while another CPU held it */
    uint64_t tr_waits, tr_wait_ticks;   /* translation lock likewise */
    uint64_t words_inline, words_ool, words_pool; /* translated code size by part */
    uint64_t refills;
    uint64_t ijc_light;       /* branch-cache misses resolved without the dispatcher (hv_ijc_resolve) */         /* TLB misses filled by the light path (hv_tlb_refill) */
    uint64_t stash_saves, stash_hits, stash_entries; /* user TLB entries kept across process switches */
    uint64_t code_protects;   /* pages that became code (every CPU's TLB scanned for writable entries) */
    uint64_t tlb_miss_kind[4]; /* TLB misses: EL0 empty, EL0 other page there, EL1 empty, EL1 other page there */
    uint64_t stash_stale;     /* process switches that found the stash dropped by a TLBI meanwhile */
    uint64_t slow_why[6];     /* slow accesses by cause: MMIO, code-page write, page end, TLB miss, other, TLB entry there but mismatched */
    uint64_t small_pages;     /* of the TLB misses above: the guest maps the page with a granule under 16 KB (4 KB), which the TLB cannot hold */
    uint64_t slow_kind[12];   /* hv_mem_emulate calls by HV_MEM_* kind */
    uint64_t light_kind[4];
    uint64_t light_fail[4];
    uint64_t light_walks;
    uint64_t fast_resumes;
    uint64_t fr_fail[5];    /* SVCs and ERETs that went to their block without the dispatcher */
    uint64_t protect_kind[3]; /* a page becoming code, per CPU: not mapped writable, one entry, scan */
    uint64_t light_region[2]; /* user light fills: in the shared region (0x18..0x28 << 28), elsewhere */
    uint64_t chained_early;   /* exits chained as their block was placed */
    uint64_t wfe_waits;       /* WFEs that waited on the monitored word in place */
    uint64_t kind_insns[16], kind_words[16]; /* --stats: inline words by instruction kind (HvInsnKind), as translated */
    uint64_t posted_kind[4];
    uint64_t race_kind[3];    /* remote drops that raced: walk under way, cache fill under way, either during the drop */
    uint64_t race_other_page; /* HV_WALK_LOG: drops not counted as raced, the walks meanwhile being of other pages */  /* TLBIs other CPUs had to do themselves: a page or small range that raced, a big range, the rest (ASID, all) */
    uint64_t range_spared;    /* big user-range TLBIs that needed no cached targets dropped */
    uint64_t code_ijc[3];     /* code changes: no cached target into the page, its VA page's targets dropped, all dropped (HV_IJC_PAGES) */
    uint64_t ijc_reset_kind[4]; /* whole branch-cache drops: user half, kernel half, one process's by TLBI ASID, one process's by a range of 64 MB or more */
    uint64_t kernel_ranges;   /* big kernel-range TLBIs, dropped by range rather than with everything */
    uint64_t tlb_range_flushes; /* and that dropped only the TLB entries in the range */     /* of hv_ijc_resolve's lookups, ones that walked for the target page */   /* hv_ijc_resolve could not: chaining off/odd target, filters full, no TLB entry, block not made yet */   /* the same for hv_ijc_resolve's fills */
    uint64_t fill_kind[4];    /* ijc fills into an empty slot, over another live salt, over the same salt, over a dead salt */
    uint64_t flush_why[8];
    uint64_t flush_after_switch[4];
    uint64_t flush_checked, flush_check_entries, flush_check_bad, flush_check_af; /* HV_SWITCH_FLUSH=2: flushes checked, entries walked, out of date (the flush was done), only the access flag */
    uint64_t flush_skipped;   /* TLBI all here right after a process switch, left out (HV_SWITCH_FLUSH=1) */
    uint64_t flush_skipped_late; /* of them, 20-200 us after the switch at a PC seen within 20 us of one (HV_SWITCH_FLUSH=3) */
    uint64_t reset_why[8];    /* cache drops: full flush, TLBI by ASID, TLBI user VA, TLBI kernel VA, code change, user VA in every ASID (whole user half), keyed filter full, big user range */
    uint64_t why[6];          /* dispatcher entries by cause: chain fill, kick, exception/sysreg, interrupt, cached target, cache miss */
    uint64_t miss_kind[7];    /* cache misses by the branch that missed: RET, BR/BLR, B/BL, conditional, MSR, other, unknown */
    uint64_t translate_ticks, translated_insns, translated_words; /* time spent translating, guest and host code size */
    uint64_t retrans_va, retrans_vapa; /* translations of a VA (and VA+PA) translated before: diagnostics */
    uint64_t helper[12];      /* by HV_OP_* */
    uint64_t tlb_flushes, fetch_walks, exceptions, interrupts;
    uint64_t wfi, wfi_ticks;  /* WFI exits, host ticks spent asleep */
    uint64_t retranslated;    /* blocks made while not live for TLBIs whose page was remapped meanwhile: fetched again */
    uint64_t kicker_wakes, kicker_kicks, kicker_polls; /* the kicker: wakeups, CPUs made to leave at their deadline, device polls asked of CPU 0 */
    uint64_t dev_polls;       /* CPU 0's device polls (vmapple.c) */
    uint64_t pv_waits, pv_kicks; /* paravirtual ticket locks: waits for a kick (VCPU_WFK), kicks (VCPU_KICK; exception.c) */
    uint64_t cc_tenured;      /* blocks translated into the code cache's tenured segments (codecache.c) */
    /* mmu.c: what process switches cost (counted always, one increment each). */
    uint64_t refill_kind[4];  /* hv_tlb_refill: EL0 slot empty, EL0 slot held another entry, EL1 empty, EL1 another */
    uint64_t stash_miss;      /* process switches that found no stash for the incoming address space */
    uint64_t stash_evict;     /* stashes taken over from another address space (least recently used) */
    uint64_t stash_out;       /* entries copied into stashes at process switches */
    uint64_t switch_kept;     /* user entries that stayed live across process switches (the new tables map them the same) */
    uint64_t user_reset_why[7]; /* user-half branch-cache resets by cause: all-ASID TLBI by VA, all-ASID big range,
                                   whole-TLB flush, (id, page) set half full, keyed filter full, code under several VA
                                   pages, ASID log overflow (the rest of ijc_reset_kind[0]: code-cache epochs) */
    /* Not summed: tables of the first few values seen, and debugging rings (per CPU). */
    struct { uint64_t mb, n; } small_at[8]; /* where (VA >> 20, bit 0 = EL1) the first 8 regions mapped under 16 KB were */
    struct { uint64_t pc, n; } flush_pc[8]; /* where TLBI all here comes from (first 8 PCs seen) */
    uint64_t recent[16];      /* debugging: the last blocks the dispatcher entered (pc | el) */
    struct { uint64_t from, to, spsr; uint32_t kind, el; } elchg[16]; /* debugging: last exception entries (kind = type) and ERETs (kind 9) */
    uint32_t nelchg;
    uint64_t nrecent;
} HvStats;
#define HV_STATS_COUNTERS (offsetof(HvStats, small_at) / sizeof(uint64_t))

/* The interrupt-storm detector's state (hv_storm_irq). Tiny tables: the top few are what a log needs. */
#define HV_STORM_SLOTS 8
typedef struct HvStormSlot { uint32_t id, n; } HvStormSlot;
typedef struct HvStorm {
    uint64_t t0, wfi0;           /* the window's start: host time, and the CPU's WFI count then */
    uint32_t acks;               /* interrupts acknowledged in the window */
    uint8_t armed, logged;       /* the last window was hot (record now); this episode was logged */
    uint32_t episodes;           /* storms logged */
    uint64_t began;              /* host time the episode's first hot window ended */
    HvStormSlot irq[HV_STORM_SLOTS], msr[HV_STORM_SLOTS]; /* while armed: interrupt ids, MSRs written */
} HvStorm;

#define HV_MAX_CPUS 8
#define HV_WHINT_MANY (1ull << 63) /* whint: more than three; else up to three TLB codes + 1, 16 bits each */

/* What each CPU has to itself and keeps across hv_cpu_reset (tests copy HvCpu
   structs around, so it lives here, by CPU index): its indirect-branch cache and
   the filters for dropping entries from it, the front cache of blocks, its
   interrupt lines and its wakeup. */
/* A process's user TLB entries, put aside when it is switched out (TTBR0 now
   names another address space) and put back when it comes back, as a TLB
   tagged by ASID keeps them. Any TLBI that could touch the address space
   (here or from another CPU) bumps gen; a stash whose gen moved is dropped.
   A stash stays valid while its entries are live again: the next switch away
   adds only what was filled since (mmu.c, hv_tlb_switch_user). */
#define HV_STASHES 32
#define HV_STASH_CAP 1024
#define HV_STASH_FILTER_BITS 12 /* a stash's page filter: 4096 bits, one per hash of a page number it holds */
typedef struct HvTlbStash {
    uint64_t ttbr0;      /* the address space (0: empty); read by other CPUs */
    uint32_t gen;        /* bumped by TLBIs (atomic) */
    uint32_t saved_gen;  /* gen when the entries were saved */
    uint32_t n;
    uint64_t used;       /* for replacing the least recently saved */
    uint16_t *slot;      /* slot << 2 | table, as user_fills */
    HvTlbEntry *ent;
    /* Pages that may have entries here (set as they are saved, cleared with the stash): a TLBI by VA or small range
       looks at the stashes whose bit is set only, here and from other CPUs. */
    uint64_t filter[(1u << HV_STASH_FILTER_BITS) / 64];
} HvTlbStash;

typedef struct HvPerCpu {
    /* Interrupt lines into this CPU, driven by the GIC. First and together:
       translated code reads both with one load (HvCpu.lines_ptr). */
    int irq_line, fiq_line;
    /* Its big tables in one mapping (the branch cache, ucode, cid_chunks, the stashes' entries), made when the CPU is
       first reset (hv_machine_add_cpus): a machine pays only for the CPUs it has. */
    uint8_t *tables;
    size_t tables_bytes;
    uint64_t *ijc;           /* indirect-branch cache tables (cpu->ijc points here) */
    uint64_t ijc_pages[2][1024]; /* hashed bitmap of the user pages any process cached targets in (for all-ASID TLBIs) */
    /* Hashed bitmap of (page, salt) pairs with cached targets: a TLBI for one
       address space drops its entries only if that address space cached
       something in the page. A new salt makes old bits meaningless, so this is
       only cleared (with the whole cache) when it gets an eighth full. */
    uint64_t ijc_keyed[1 << 14];
    uint32_t ijc_keyed_count;
    uint32_t ijc_tables_used; /* bit per flags value whose table was ever filled */
    /* Exactly which (user id, user page) pairs have cached targets: a hash set,
       so unmapping a big range of one address space drops only its code pages'
       entries instead of the whole address space's. Emptied with the user half. */
    uint64_t *ucode;
    uint32_t ucode_count;
    /* Per user id: which 32 MB chunks of its VA (hashed into 256) have cached
       targets, so a TLBI for a big range elsewhere (data, nearly always) drops nothing. */
    uint64_t (*cid_chunks)[4];
    uint64_t last_fill[2];
    /* Per half, hashed by (page ^ salt): which 256-byte pieces of the page have
       cached targets, so dropping a page clears 64 entries per piece instead of
       all 4096. A slot two keys wanted is spoiled (key ~0: scan it all); only
       this CPU empties one again, after clearing its page. */
    struct { uint64_t key, bits; } ijc_hint[2][4096];   /* page ^ salt of the last fill in each half: its filter bits are set already */
    /* Direct-mapped cache in front of the hash, with the VA beside the block so
       a slot holding another block is passed over without reading it. */
    struct { uint64_t va; struct HvBlock *b; } jc[1 << HV_JC_BITS];
    /* WFI sleeps on this; device threads, the GIC and other CPUs signal it. */
    pthread_mutex_t wake_mu;
    pthread_cond_t wake_cv;
    int wake_pending;            /* set by every wake (atomic); a wait that finds it set ends at once */
    uint32_t poll_req;           /* CPU 0: device work signalled (hv_machine_wake) or the kicker's poll: poll at the next tick */
    uint64_t wfi_until;          /* parked in WFI: when the sleep ends at the latest (0: not asleep on a timeout) */
    uint64_t guest_due;          /* host time its guest timer next fires (0: none), apart from CPU 0's device deadlines in
                                    timer_due: the light paths refuse a fast resume only for this (light.c) */
    HvStorm storm;               /* the interrupt-storm detector (hv_storm_irq): its own thread only */
    /* Work other CPUs ask of this one (only the owner may touch its TLB and
       branch cache while it runs). Posting bumps req_seq; the owner does the
       work at its next dispatcher entry and publishes ack_seq. */
    pthread_mutex_t req_mu;
    uint32_t req_flags;          /* HV_REQ_* */
    uint32_t nreq;
    struct { uint32_t op1, crn, crm, op2; uint64_t xt; } req[64]; /* TLBIs to apply */
    uint32_t nijc_page;
    uint64_t ijc_page[16];       /* code changed: cached targets to forget (hv_ijc_drop_code_page), queued as req */
    uint64_t req_seq, ack_seq;
    /* active: inside the dispatcher loop (0 while parked: WFI, powered off, at a
       flush barrier). tlb_live: active and neither waiting for acks itself nor
       translating, i.e. it may be using TLB entries right now. */
    int active, tlb_live;
    uint32_t ack_waiters;        /* CPUs asleep in hv_cpu_sync waiting for ack_seq to move (HV_SYNC_WAIT) */
    uint32_t walk_seq;           /* odd while it walks page tables and fills its TLB (see hv_tlbi_drop_remote_va) */
    uint64_t walk_page[8];       /* the page walk k (walk_seq 2k -> 2k+1) fills, at [k % 8]; HV_WALK_ANY: a process switch */
    uint32_t ijc_seq;            /* odd while it checks a block's mapping in its TLB and caches it (hv_ijc_fill_checked) */
    uint32_t thread;             /* its host thread (mach_port_t), for --stats: is a CPU waited for running at all */
    uint8_t phase;               /* for --stats, what a CPU others wait on is doing: HV_PHASE_* */
    HvTlbStash stash[HV_STASHES];
    uint64_t stash_clock;
    uint32_t live_stash;         /* index + 1 of the stash whose entries are live in the TLB again (0: none) */
    uint32_t live_kept;          /* user_fills before this stayed from the process before (mmu.c: not in it) */
    uint32_t live_from;          /* user_fills from here on are not in it (filled after it was put back) */
    uint32_t pos_epoch;          /* stash_pos entries of another epoch mean nothing */
    uint32_t *stash_pos;         /* by TLB code: pos_epoch << 10 | where its entry is in the stash being saved or put back */
    uint32_t cc_seen;            /* the code cache's epoch this CPU caught up with (hv_cc_service; read by others) */
    uint32_t cc_work;            /* HV_CC_NEED, HV_CC_JOB: code-cache work at the top of its loop (its own thread only) */
    /* What only this CPU's thread writes on its hot paths (or another thread while it is parked): on cache lines of
       their own, so CPUs on different cores never pass a line back and forth for a counter (128 bytes: Apple's line). */
    struct {
        HvStats stats;
        uint64_t slow_mem;       /* hv_mem_emulate calls */
        uint64_t access_pc;      /* guest PC of the load/store being emulated, for logs */
    } own __attribute__((aligned(128)));
} HvPerCpu;

/* The counters of a CPU's own thread (or of a parked CPU): HvPerCpu.own. */
#define HV_ST(cpu) ((cpu)->pc_state->own.stats)

enum { HV_PHASE_RUN, HV_PHASE_TRANSLATE, HV_PHASE_HELPER, HV_PHASE_SYNC, HV_PHASE_FLUSH };
#define HV_REQ_TLB_ALL 1u   /* drop the whole TLB and branch cache */
#define HV_REQ_IJC_RESET 2u /* drop the branch cache (code changed) */

typedef struct HvMachine {
    int locks_initialized;
    HvRam ram[HV_MAX_RAM];
    int nram;
    HvRam *main_ram;     /* the largest region: guest RAM */
    HvMmio mmio[HV_MAX_MMIO];
    int nmmio;

    HvJitRegion jit;
    HvCodeCache cc;          /* the JIT region's segments and their evictions (codecache.c) */

    /* Read on every CPU's hot paths and written rarely: on a cache line of their own (128 bytes: Apple's), away from
       the counters translations write. */
    int flush_pending __attribute__((aligned(128))); /* set by helpers; the dispatcher flushes once the block has left */
    int stw_active;          /* stopping every CPU to flush all translations (stw_mu) */
    int chain;               /* block chaining and the indirect-branch cache are enabled */
    int trace;               /* print every block entered */
    int log;                 /* 1: unknown sysregs, undefined instructions, unmapped accesses; 2: also every exception */
    int gen_checks;
    int slow_mem;            /* tests: send every load and store through hv_mem_emulate */
    int stats_interval;      /* seconds between --stats lines, 0 = off */
    int stats_deep;          /* the costly diagnostics too (page walks and decodes per miss, the block-hash walk, thread probes) */
    uint32_t hash_mask;      /* buckets - 1 */
    uint64_t stop_pc;        /* tests: leave the dispatcher when pc reaches this */
    uint64_t stop_pc2;       /* debugging: a second such place */
    /* The block hash: per bucket the index of its first block in blocks (0: none; blocks[0] is never used). A power of
       two of buckets about as many as there are records (machine.c). */
    uint32_t *hash;
    HvBlock *blocks;
    /* Written as blocks are made: lines of their own. */
    int nblocks __attribute__((aligned(128)));
    uint32_t max_blocks, max_slots; /* sized from the JIT region (machine.c) */
    uint32_t *block_jit_gen; /* HV_JIT_POISON: per record, the full flushes when it was made (checked against jit_gen) */
    size_t hash_bytes, blocks_bytes, slots_bytes; /* their mappings (hv_pages_alloc) */

    void *gic;
    /* Devices: called between blocks every so often and while the CPU waits.
       Returns the host time (mach_absolute_time units) of the next timer event, or 0. */
    uint64_t (*tick)(struct HvMachine *m, HvCpu *cpu);
    void *tick_opaque;
    /* GIC CPU interface system registers (ICC_*_EL1), reg = op0:op1:CRn:CRm:op2. */
    uint64_t (*icc_read)(struct HvMachine *m, HvCpu *cpu, uint32_t reg);
    void (*icc_write)(struct HvMachine *m, HvCpu *cpu, uint32_t reg, uint64_t v);

    void (*stop_hook)(HvCpu *cpu); /* debugging: call this at stop_pc instead of leaving */
    uint32_t jit_gen;    /* full flushes so far, as blocks see them (HV_JIT_POISON checks) */
    uint64_t switch_flush_pc[4]; /* HV_SWITCH_FLUSH=3: PCs of the TLBI VMALLE1s seen within 20 us of a TTBR0 change (xnu's pmap switch) */
    uint64_t access_pc;  /* with log on: guest PC of the load/store being emulated (each CPU keeps its own, HvPerCpu.own) */
    uint64_t watch_va;   /* debugging: log every write that touches this guest VA (0: off) */
    uint64_t watch_pa;   /* debugging: the same by physical address */
    HvStats stats;
    /* Chainable exits, 48 bytes each over these arrays (one mapping, slots_bytes). slots: two words each (HV_SLOT),
       the block chained to (0: not chained), then the exit's guest target; hv_chain_thunk reads both. The rest is
       C's: words of translated code as hv_jit_ref keeps them (offset + 1, 0: none). */
    uint64_t *slots;
    uint32_t *slot_site;     /* the B in each exit's stub that chaining rewrites to jump to the target */
    uint32_t *slot_stub;     /* what that B goes to while it isn't chained */
    uint32_t *slot_cond;     /* a conditional branch in a block's hot part that chaining may send straight to the target too */
    /* Exits to another page (see put_branch_exit): the host addend the target
       page's TLB entry must hold for the exit to go straight to the chained
       block (0: a same-page exit), and once chained, the target's RAM page (hv_xpa) so that invalidating its code
       can unchain it. Each such page's chained exits are a list from its
       HvRam.xhead through slot_xnext (slot + 1, 0 at the end); a slot is on one at a time, until the page's code changes. */
    uint64_t *slot_xa;
    uint32_t *slot_xpa;
    uint32_t *slot_xnext, nxchained;
    uint32_t *slot_xprev;    /* the list the other way (slot + 1), so an evicted exit leaves it at once; slot_xnext also links freed slots (codecache.c) */
    uint32_t nslots __attribute__((aligned(128))); /* taken by translations on every CPU: a line of its own */
    HvCpu *cpu __attribute__((aligned(128))); /* CPU 0: the one that polls devices */
    HvCpu *cpus[HV_MAX_CPUS]; /* every CPU, so device and invalidation code can ask them to leave */
    int ncpus;
    /* Per CPU (hv_pages_alloc, HV_MAX_CPUS of them): pages of a CPU never reset are never touched. */
    HvPerCpu *percpu;
    /* With more than one CPU, only the holder of this runs guest code (a fair
       ticket lock, handed over at every kick and while a CPU sleeps). */
    int big_lock_on;
    /* Devices, the GIC and the ICC registers: one CPU at a time (recursive). */
    pthread_mutex_t dev_mu;
    /* Translating and inserting blocks, the JIT region and the slots. */
    pthread_mutex_t tr_mu;
    /* Stopping every CPU to flush all translations. */
    pthread_mutex_t stw_mu;
    pthread_cond_t stw_cv;   /* stw_active: with the hot fields above */
    pthread_mutex_t big_mu;
    pthread_cond_t big_cv;
    uint64_t big_next, big_serving;
    /* --profile: host PCs of the CPU thread sampled every millisecond, drained by the stats line. */
    uint64_t *prof;
    uint32_t prof_head, prof_tail;
    /* The kicker (hv_machine_kicker) sleeps until the earliest deadline of a running CPU: kick_at, 0 while it looks at
       the CPUs. A CPU whose deadline comes earlier than that wakes it (hv_kicker_note). */
    pthread_mutex_t kick_mu;
    pthread_cond_t kick_cv;
    uint64_t kick_at;
    int kick_poked, kicker_on;
    uint32_t dev_unsignalled; /* HV_UNSIG_* bits: device work only a poll finds (hv_machine_unsignalled) */
    /* The host counter when the machine started: every CPU's CNTVOFF, so the guest's virtual counter (its
       mach_absolute_time) starts near 0 as on a Mac or under Virtualization.framework. With the host's own
       count (days of uptime) macOS 12 took the user as idle for that long and put itself to sleep while
       still starting up: its window server never drew. */
    uint64_t cntvoff;
} HvMachine;

static inline uint32_t hv_block_hash(const HvMachine *m, uint64_t va, uint64_t pa, uint32_t flags) {
    uint64_t h = (va >> 2) ^ (pa >> 2) * 0x9e3779b97f4a7c15ull ^ flags;
    return (uint32_t)(h ^ (h >> 29)) & m->hash_mask;
}

/* A block of a code-cache segment that was condemned is gone, whatever else matches (codecache.c). */
static inline int hv_block_live(const HvMachine *m, const HvBlock *b) {
    return __atomic_load_n(&m->cc.tag[(b->stag >> 24) & (HV_CC_MAX_SEGS - 1)], __ATOMIC_RELAXED) == b->stag;
}

/* Lock-free: blocks are added with a release store; a condemned segment's leave the hash, their records kept as they
   were until every CPU has been back at the top of its loop (codecache.c); a full flush stops every CPU. */
static inline HvBlock *hv_block_find(HvMachine *m, uint32_t h, uint64_t va, uint64_t pa, uint32_t flags, uint32_t gen) {
    HvBlock *blocks = m->blocks;
    for (uint32_t i = __atomic_load_n(&m->hash[h], __ATOMIC_ACQUIRE); i; i = __atomic_load_n(&blocks[i].next, __ATOMIC_ACQUIRE)) {
        HvBlock *b = &blocks[i];
        if (b->va == va && b->pa == pa && b->flags == flags && b->gen == gen && hv_block_live(m, b)) return b;
    }
    return NULL;
}

/* Where a block's code is, the RAM its page is in, and that page's generation now (not b->gen: b is stale). */
static inline uint32_t *hv_block_code(const HvMachine *m, const HvBlock *b) { return m->jit.base + b->code_off; }
static inline HvRam *hv_block_ram(HvMachine *m, const HvBlock *b) { return &m->ram[b->ram]; }
static inline uint64_t hv_block_pg(HvMachine *m, const HvBlock *b) { return (b->pa - m->ram[b->ram].pa) >> HV_TLB_PAGE_BITS; }
static inline uint32_t *hv_block_gen(HvMachine *m, const HvBlock *b) { return &m->ram[b->ram].page_gen[hv_block_pg(m, b)]; }
/* HV_JIT_POISON: the full flushes when b was made (0 without the checks). */
static inline uint32_t hv_block_jit_gen(const HvMachine *m, const HvBlock *b) {
    return m->block_jit_gen ? m->block_jit_gen[b - m->blocks] : 0;
}

/* A word of translated code as a slot keeps it: its offset in the JIT region + 1, 0 for none; and back. */
static inline uint32_t hv_jit_ref(const HvMachine *m, const uint32_t *w) { return w ? (uint32_t)(w - m->jit.base) + 1 : 0; }
static inline uint32_t *hv_jit_word(const HvMachine *m, uint32_t ref) { return ref ? m->jit.base + (ref - 1) : (uint32_t *)0; }
/* A chained exit's target page as slot_xpa keeps it: its RAM region (3 bits) and page there (28), and 1 (0: none). */
static inline uint32_t hv_xpa(uint32_t ram, uint64_t pg) { return (ram << 28 | (uint32_t)pg) << 1 | 1; }
static inline uint32_t hv_xpa_ram(uint32_t x) { return x >> 29; }
static inline uint64_t hv_xpa_pg(uint32_t x) { return (x >> 1) & ((1u << 28) - 1); }
_Static_assert(HV_MAX_RAM <= 8, "hv_xpa: 3 bits of RAM region");

/* Zeroed memory from the kernel, a page as it is first touched (0 until then), and the same given back: hv_pages_zero
   maps fresh pages over the whole pages of [p, p + bytes) (memset at the ends), so what was there costs nothing until
   it is written again. Never on the JIT region (a debugger prepared it; it cannot be prepared again). */
void *hv_pages_alloc(size_t bytes);
void hv_pages_free(void *p, size_t bytes);
void hv_pages_zero(void *p, size_t bytes);
/* Every CPU paused, none to run before this returns: drop every translation and give back the pages of the block
   records, exit slots, block hash and every CPU's branch caches (they cost nothing until the CPUs run again and
   translate). 0, or -1 if a CPU is still in the dispatcher. */
int hv_machine_trim(HvMachine *m);
/* The per-CPU tables of CPUs 0 .. n-1 (each is made at its first reset otherwise): -1 if there is no room. */
int hv_machine_add_cpus(HvMachine *m, int n);
/* The address space the engine's tables take for a JIT region of jit_bytes and ncpus CPUs, besides guest RAM and
   the tables that go with it (a few bytes per 16 KB page): for the app to leave room for when it sizes guest RAM. */
size_t hv_machine_table_bytes(size_t jit_bytes, int ncpus);

/* --stats readers: the machine's counters plus every CPU's own. */
void hv_stats_total(HvMachine *m, HvStats *out);
uint64_t hv_stat_blocks(HvMachine *m);   /* dispatcher entries, all CPUs */
uint64_t hv_stat_slow_mem(HvMachine *m); /* hv_mem_emulate calls, all CPUs */
uint64_t hv_stat_translations(HvMachine *m); /* blocks translated, all CPUs */

int hv_machine_init(HvMachine *m, size_t jit_bytes);
/* The same with JIT memory the host provides (iOS: the region a debugger granted and its writable alias). */
int hv_machine_init_jit(HvMachine *m, void *rx, void *rw, size_t jit_bytes);
void hv_machine_free(HvMachine *m);
int hv_machine_add_ram(HvMachine *m, uint64_t pa, uint64_t size, void *host, int readonly);
int hv_machine_add_mmio(HvMachine *m, uint64_t pa, uint64_t size, void *opaque,
                        uint64_t (*read)(void *, uint64_t, unsigned),
                        void (*write)(void *, uint64_t, uint64_t, unsigned), const char *name);

HvRam *hv_ram_lookup(HvMachine *m, uint64_t pa);
/* Drop the translations made from the RAM page holding pa (it was written, or the guest invalidated it). */
void hv_invalidate_code(HvMachine *m, uint64_t pa);
/* A chainable exit's slot: {the block it is chained to (0: none), its guest target}. Its stub names the slot, and
   hv_chain_thunk reads the target 8 bytes on, so the stub need not hold it (Tomba247 a3ca070). */
#define HV_SLOT(m, i) (&(m)->slots[2 * (size_t)(i)])
#define HV_SLOT_INDEX(m, p) ((uint32_t)(((p) - (m)->slots) / 2))
void hv_ret_clear(HvCpu *cpu);
int hv_ic_ivau_drops(void);
/* Settings that say how to translate or wait, to compare ways of doing it in one running guest
   ("knob NAME VALUE" in HV_INPUT_FILE; a new way starts from an empty code cache). Each starts
   from the environment variable named in hv_knob_names. */
enum { HV_K_NO_RAS, HV_K_SUPERBLOCKS, HV_K_GROUPS, HV_K_WFI_SPIN, HV_K_FLUSH, HV_K_TEST1, HV_K_TEST2, HV_K_TEST3, HV_K_TLBT, HV_K_JITCAP, HV_K_RECHECK, HV_K_SYNCWAIT, HV_K_SWITCHFLUSH, HV_K_RANGEDROP, HV_K_MOVIMM, HV_K_PREDSTAT, HV_K_WALKLOG, HV_K_HOIST, HV_K_IJCPAGES, HV_K_DNSPROXY, HV_K_COUNT };
extern int hv_knob[HV_K_COUNT];
int hv_knob_set(HvMachine *m, const char *name, int value);
/* Debugging (HV_WATCH): which pages keep losing their translations. */
extern uint32_t *hv_smc_counts;
extern uint64_t *hv_smc_last;
extern uint64_t hv_smc_pages, hv_smc_cpu, hv_smc_dma;
/* A device wrote guest memory directly: translations made from it are out of date. Any thread. */
void hv_dma_written(HvMachine *m, uint64_t pa, uint64_t len);
/* HV_CODE_CHECK (debugging): a page just became code; and, with every CPU parked, which code pages changed since
   without their translations being dropped. */
void hv_code_check_note(HvRam *ram, uint64_t pg);
void hv_code_check_all(HvMachine *m);
HvMmio *hv_mmio_lookup(HvMachine *m, uint64_t pa);
/* Host pointer for `len` bytes of guest RAM at pa, or NULL. */
void *hv_phys_ptr(HvMachine *m, uint64_t pa, uint64_t len);

/* Physical accesses from C (page-table walks, devices doing DMA, slow paths). */
int hv_phys_read(HvMachine *m, uint64_t pa, void *buf, unsigned len);
int hv_phys_write(HvMachine *m, uint64_t pa, const void *buf, unsigned len);

void hv_cpu_reset(HvCpu *cpu, HvMachine *m); /* CPU 0 */
void hv_cpu_reset_index(HvCpu *cpu, HvMachine *m, uint32_t index);
/* The CPU this thread runs (NULL outside the dispatcher: tests, devices). */
extern __thread HvCpu *hv_self;
/* Where a counter goes from a thread that may not be the CPU's whose state it works on (remote TLB drops, devices,
   wakes): the calling CPU's own copy, or the machine's off the CPUs. */
static inline HvStats *hv_stats_here(HvMachine *m) {
    HvCpu *self = hv_self;
    return self && self->pc_state ? &self->pc_state->own.stats : &m->stats;
}
void hv_dev_lock(HvMachine *m);
void hv_dev_unlock(HvMachine *m);
/* Ask another CPU to apply a TLBI (or HV_REQ_* work); returns the sequence to wait for. */
uint64_t hv_cpu_post_tlbi(HvCpu *target, uint32_t op1, uint32_t crn, uint32_t crm, uint32_t op2, uint64_t xt);
uint64_t hv_cpu_post(HvCpu *target, uint32_t flags);
uint64_t hv_cpu_post_ijc_page(HvCpu *target, uint64_t v);
/* On cpu's own thread: code changed in a page cached as branch targets at VA page v (| 2), or v = 1 (none):
   forget the return predictions and those targets (mmu.c). */
void hv_ijc_drop_code_page(HvCpu *cpu, uint64_t v);
/* Wait until target has done everything up to seq (or is parked, and will before it runs). */
void hv_cpu_sync(HvCpu *self, HvCpu *target, uint64_t seq);
/* The owner: do what other CPUs asked. */
void hv_cpu_process_requests(HvCpu *cpu);
void hv_cpu_ack_wake(HvCpu *cpu);
void hv_big_lock(HvMachine *m);
void hv_big_unlock(HvMachine *m);
/* Let a waiting CPU run (the lock is held again on return). */
void hv_big_yield(HvMachine *m);
/* Make every CPU leave its block at the next exit. */
void hv_machine_kick_all(HvMachine *m);
/* Publish a terminal reason, then wake all CPUs, including CPU_OFF waits.
   A later host stop must not overwrite the guest's shutdown/panic reason. */
void hv_machine_halt(HvMachine *m, enum HvHaltReason reason);
/* Wake one CPU out of WFI (and make it leave its block). No device poll: device work goes through hv_machine_wake. */
void hv_cpu_wake(HvCpu *cpu);
/* Make it leave its block at the next checked exit, without waking it from WFI. */
void hv_cpu_kick(HvCpu *cpu);

/* From any thread: device work is waiting for the CPU thread's tick. Makes a
   running block leave and ends a WFI sleep. */
void hv_machine_wake(HvMachine *m);

/* Device work no thread signals, which only a poll finds (HV_UNSIG_* bits, set and cleared by the device): while any
   is set, the kicker has CPU 0 poll every HV_POLL_BUSY while it runs. With none, CPU 0 polls when a device signals
   (hv_machine_wake), at its device deadlines (the display's refresh) and every HV_DEV_SAFETY. */
enum { HV_UNSIG_PVG_CHAN = 1u << 0 /* a display channel waits for another channel's stamp (pvg_lite.c) */ };
void hv_machine_unsignalled(HvMachine *m, uint32_t bit, int on);

/* Interrupt storms (an idle CPU taken out of WFI by an interrupt tens of thousands of times a second): each CPU counts
   its acknowledged interrupts in windows of HV_STORM_WINDOW; a window faster than HV_STORM_RATE a second in which
   WFI came as often as 3 in 4 interrupts is hot. After one hot window the next records which interrupts and which
   system register writes, and logs them once; the episode ends with the first window that is not hot. */
#define HV_STORM_WINDOW 8192u
#define HV_STORM_RATE 10000u
void hv_storm_irq(HvCpu *cpu, uint32_t intid);
/* Counts id in a storm table; once it is full, the rest count in the last slot as id ~0. */
static inline void hv_storm_count(HvStormSlot *t, uint32_t id) {
    unsigned i = 0;
    while (i < HV_STORM_SLOTS - 1 && t[i].n && t[i].id != id) i++;
    if (!t[i].n) t[i].id = id;
    else if (t[i].id != id) t[i].id = ~0u;
    t[i].n++;
}
/* An MSR through the helper (reg: its encoding; 0x10000 | field for MSR immediate), recorded while a storm is. */
static inline void hv_storm_msr(HvCpu *cpu, uint32_t reg) {
    HvPerCpu *p = cpu->pc_state;
    if (p && __builtin_expect(p->storm.armed, 0)) hv_storm_count(p->storm.msr, reg);
}

/* Deadlines, in host ticks (24 MHz). Translated code checks no timer, so a running CPU leaves its block only when asked:
   the kicker asks the CPU that is due, when it is due (its timer_due: the next timer event, and for CPU 0 the devices'
   next deadline: the display's refresh, a poll), instead of every CPU every millisecond. Idle CPUs sleep in WFI until
   their own deadline and need it not at all. */
#define HV_TICKS_MS 24000ull
#define HV_KICK_CAP (4 * HV_TICKS_MS)     /* longest the kicker sleeps while a CPU runs */
#define HV_KICK_SAFETY (20 * HV_TICKS_MS) /* every running CPU leaves its block at least this often */
#define HV_KICK_SLACK (HV_TICKS_MS / 4)   /* a deadline that much before the kicker's wakeup wakes it earlier */
#define HV_KICK_IDLE (1000 * HV_TICKS_MS) /* no CPU running: until one does (unpark wakes it) */
#define HV_POLL_BUSY (1 * HV_TICKS_MS)    /* CPU 0 polls the devices this often while it runs (work no device signals) */
#define HV_DEV_SAFETY (20 * HV_TICKS_MS)  /* and at least this often while it sleeps (vmapple.c) */
#define HV_WFI_MAX (100 * HV_TICKS_MS)    /* longest WFI sleep with no deadline: wakes come with hv_cpu_wake */
/* The kicker's thread: until *stop (hv_machine_kicker_poke after setting it). */
void hv_machine_kicker(HvMachine *m, _Atomic int *stop);
void hv_machine_kicker_poke(HvMachine *m);
/* cpu's deadline is now due (0: none): wake the kicker if it would sleep past it. */
void hv_kicker_note(HvMachine *m, uint64_t due);
/* After a tick: cpu's next deadline, for the kicker. */
void hv_cpu_set_due(HvCpu *cpu, uint64_t due);

#endif
