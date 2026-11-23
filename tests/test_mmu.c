// Stage 1 walker: granules, block sizes, TTBR0/TTBR1, TBI, permissions and
// fault codes, checked directly against hv_mmu_walk. Then TLBIs between CPUs:
// requests and remote drops directly, and guest code on four CPU threads at once.
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "dispatch.h"
#include "knobs.h"
#include "machine.h"
#include "mmu.h"
#include "sysreg.h"

#define PT_PA 0x80000000ull
#define PT_SIZE (1u << 20)

static uint8_t *pt;
static uint64_t pt_next;
static int failures, checks;

static uint64_t *host(uint64_t pa) {
    return (uint64_t *)(pt + (pa - PT_PA));
}

static uint64_t alloc_table(void) {
    uint64_t pa = PT_PA + pt_next;
    pt_next += 65536; /* big enough and aligned for any granule */
    memset(host(pa), 0, 65536);
    return pa;
}

/* Install a leaf for va at `leaf_level`, creating tables from the start level. */
static uint64_t *map(uint64_t root, int g, int inputsize, uint64_t va, int leaf_level, uint64_t desc,
                     uint64_t table_bits) {
    int stride = g - 3;
    int levels = (inputsize - g + stride - 1) / stride;
    uint64_t table = root;
    for (int level = 4 - levels;; level++) {
        int shift = g + stride * (3 - level);
        int idx_bits = level == 4 - levels ? inputsize - shift : stride;
        uint64_t *e = &host(table)[(va >> shift) & ((1ull << idx_bits) - 1)];
        if (level == leaf_level) {
            *e = desc;
            return e;
        }
        if (!(*e & 1)) *e = alloc_table() | 3 | table_bits;
        table = *e & 0x0000fffffffff000ull & ~((1ull << g) - 1);
    }
}

#define AF (1ull << 10)
#define PAGE 3ull
#define BLOCK 1ull
#define AP(x) ((uint64_t)(x) << 6)
#define PXN (1ull << 53)
#define UXN (1ull << 54)

static void expect(const char *what, HvCpu *cpu, uint64_t va, HvAccess acc, int el, uint64_t want_pa, uint32_t want_fsc) {
    HvWalk w;
    hv_mmu_walk(cpu, va, acc, el, &w);
    checks++;
    if (w.fsc != want_fsc || (!want_fsc && w.pa != want_pa)) {
        printf("  FAIL %s: va %llx -> pa %llx fsc %02x, expected pa %llx fsc %02x\n", what, (unsigned long long)va,
               (unsigned long long)w.pa, w.fsc, (unsigned long long)want_pa, want_fsc);
        failures++;
    }
}

/* ---- Four CPUs at once (mmu_programs.S): CPU 0 remaps a code page X, generation after generation, with TLBIs both
   kinds (requests the others do themselves, and drops done in their TLBs), while the others call X, two of them
   switching address spaces before each call. Every CPU translates X's new code each generation, so TLBIs meet
   translating CPUs (not live for them, O8a) and process switches (O8b). A call must never run code older than the
   generation it reads (one older after a remote drop: see mmu_exec). Any guest exception fails it too. ---- */
extern const char mmu_programs_begin[], mmu_programs_finish[], mmu_remap[], mmu_exec[], mmu_exec_switch[], mmu_xcode[],
    mmu_done[], mmu_vectors[];
#define ADDR(sym) ((uint64_t)(uintptr_t)(sym))
#define RT_TABLES 32
#define RT_BITS (3ull | 1ull << 10 | 3ull << 8) /* page, accessed, inner shareable, attribute 0; EL1 read/write */
#define RT_NG (1ull << 11)                      /* not global: X's mappings are per ASID */
static uint8_t *rt_pt;
static unsigned rt_next;

static uint64_t rt_table(void) {
    if (rt_next == RT_TABLES) {
        printf("  FAIL remap test: out of page tables\n");
        exit(1);
    }
    uint8_t *t = rt_pt + (size_t)rt_next++ * 16384;
    memset(t, 0, 16384);
    return ADDR(t);
}

/* va's level 3 entry (16 KB granule, 48-bit VA: levels 0-3), making the tables on the way. */
static uint64_t *rt_entry(uint64_t root, uint64_t va) {
    uint64_t table = root;
    for (int level = 0; level < 3; level++) {
        int shift = 14 + 11 * (3 - level);
        uint64_t *e = (uint64_t *)(uintptr_t)table + ((va >> shift) & (level == 0 ? 1 : 0x7ff));
        if (!(*e & 1)) *e = rt_table() | 3;
        table = *e & 0x0000ffffffffc000ull;
    }
    return (uint64_t *)(uintptr_t)table + ((va >> 14) & 0x7ff);
}

static void rt_identity(uint64_t root, uint64_t start, uint64_t end) {
    for (uint64_t va = start & ~0x3fffull; va < end; va += 16384) *rt_entry(root, va) = va | RT_BITS;
}

static void *rt_thread(void *arg) {
    return (void *)(intptr_t)hv_run(arg);
}

static void remap_test(void) {
    static HvMachine rm;
    static HvCpu rc[4];
    const uint32_t last = 3000;               /* generations a round */
    const uint64_t X = 0x0000555500000000ull; /* nowhere near the process's own addresses */
    if (hv_machine_init(&rm, 16 << 20) != 0) exit(1);
    rm.stats_interval = 3600; /* counted as on a device (HV_STATS), never printed here */
    uint8_t *data = aligned_alloc(16384, 4 * 16384); /* page 0: the generation, the code pages' addresses; then the code pages */
    rt_pt = aligned_alloc(16384, RT_TABLES * 16384);
    rt_next = 0;
    hv_machine_add_ram(&rm, ADDR(mmu_programs_begin), (uint64_t)(mmu_programs_finish - mmu_programs_begin), (void *)mmu_programs_begin, 1);
    hv_machine_add_ram(&rm, ADDR(data), 4 * 16384, data, 0);
    hv_machine_add_ram(&rm, ADDR(rt_pt), RT_TABLES * 16384, rt_pt, 0);
    uint64_t root = rt_table();
    rt_identity(root, ADDR(mmu_programs_begin), ADDR(mmu_programs_finish));
    rt_identity(root, ADDR(data), ADDR(data) + 4 * 16384);
    rt_identity(root, ADDR(rt_pt), ADDR(rt_pt) + RT_TABLES * 16384);
    uint64_t *xpte = rt_entry(root, X);
    checks++;
    if (*xpte) {
        printf("  FAIL remap test: X is mapped already\n");
        failures++;
        return;
    }
    uint32_t *gen = (uint32_t *)(void *)data;
    uint64_t *page = (uint64_t *)(void *)(data + 64);
    for (int round = 0; round < 2; round++) {
        hv_knob.sync_wait = round; /* waiting for acknowledgements: spinning, then sleeping */
        *gen = 0;
        for (int i = 0; i < 3; i++) {
            page[i] = ADDR(data) + 16384 * (uint64_t)(i + 1);
            memcpy((void *)(uintptr_t)page[i], mmu_xcode, 12);
        }
        *xpte = page[0] | RT_BITS | RT_NG;
        for (int i = 0; i < 4; i++) {
            HvCpu *c = &rc[i];
            hv_cpu_reset_index(c, &rm, (uint32_t)i);
            c->mpidr = (uint64_t)i;
            c->ttbr0_el1 = root | 1ull << 48;
            c->tcr_el1 = 16 | 2u << 14 | 1u << 23 | 5ull << 32; /* T0SZ 16, TG0 16 KB, EPD1, 48-bit PA */
            c->mair_el1 = 0xff;
            c->sctlr_el1 |= 1;
            c->vbar_el1 = ADDR(mmu_vectors);
            c->x[9] = ADDR(gen);
            c->x[10] = X;
            c->x[11] = last;
            c->x[15] = root | 1ull << 48;
            c->x[16] = root | 2ull << 48;
            c->pc = i == 0 ? ADDR(mmu_remap) : i == 1 ? ADDR(mmu_exec) : ADDR(mmu_exec_switch);
        }
        rc[0].x[12] = ADDR(page);
        rc[0].x[13] = ADDR(xpte);
        rc[0].x[14] = RT_BITS | RT_NG;
        rm.stop_pc = ADDR(mmu_done);
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, 8u << 20);
        pthread_t t[4];
        for (int i = 0; i < 4; i++) pthread_create(&t[i], &attr, rt_thread, &rc[i]);
        pthread_attr_destroy(&attr);
        for (int i = 0; i < 4; i++) {
            void *r;
            pthread_join(t[i], &r);
            if (i == 0) __atomic_store_n(gen, last, __ATOMIC_SEQ_CST); /* the callers stop even if the remapper did not finish */
            checks += 2;
            if ((intptr_t)r != HV_EXIT_HALT) printf("  FAIL remap test round %d: cpu %d left with %d at pc %llx\n", round, i, (int)(intptr_t)r, (unsigned long long)rc[i].pc), failures++;
            if (rc[i].x[20]) {
                printf("  FAIL remap test round %d: cpu %d took an exception: esr %llx far %llx elr %llx\n", round, i,
                       (unsigned long long)rc[i].x[20], (unsigned long long)rc[i].x[19], (unsigned long long)rc[i].x[18]);
                failures++;
            }
        }
        checks++;
        if ((uint32_t)rc[0].x[1] != last + 1) printf("  FAIL remap test round %d: the remapper stopped at generation %u of %u\n", round, (uint32_t)rc[0].x[1], last), failures++;
        for (int i = 1; i < 4; i++) {
            checks += 2;
            if (!rc[i].x[24]) printf("  FAIL remap test round %d: cpu %d never called X\n", round, i), failures++;
            if (rc[i].x[21]) {
                printf("  FAIL remap test round %d: cpu %d ran older code than it read %llu times (first: code %llu, generation %llu)\n",
                       round, i, (unsigned long long)rc[i].x[21], (unsigned long long)rc[i].x[22], (unsigned long long)rc[i].x[23]);
                failures++;
            }
        }
        static HvStats s;
        hv_stats_total(&rm, &s);
        printf("remap test round %d: %u generations, calls %llu %llu %llu, tlbi waits %llu, translations %llu, fetched again after one %llu\n",
               round, last, (unsigned long long)rc[1].x[24], (unsigned long long)rc[2].x[24], (unsigned long long)rc[3].x[24],
               (unsigned long long)s.syncs, (unsigned long long)s.translations, (unsigned long long)s.retranslated);
    }
    hv_knob.sync_wait = 0;
    hv_machine_free(&rm);
    free(data);
    free(rt_pt);
}

/* ---- Process switches (hv_tlb_switch_user, the stashes): address spaces of 16 KB pages, 48-bit VA (levels 0-3),
   their tables and data pages in one RAM region at their host addresses (as remap_test). ---- */
#define SW_TABLES 96
#define SW_DATA 32
#define SW_USER (3ull | 1ull << 10 | 3ull << 8 | 1ull << 6 | 1ull << 11) /* page, accessed, inner shareable, EL0 RW, nG */
static uint8_t *sw_mem;
static unsigned sw_next;

static uint64_t sw_table(void) {
    if (sw_next == SW_TABLES) {
        printf("  FAIL switch test: out of page tables\n");
        exit(1);
    }
    uint8_t *t = sw_mem + (size_t)sw_next++ * 16384;
    memset(t, 0, 16384);
    return ADDR(t);
}

static uint64_t sw_data(int k) {
    return ADDR(sw_mem) + (uint64_t)(SW_TABLES + k) * 16384;
}

/* va's descriptor at level (0-3) under root, making the tables above it. */
static uint64_t *sw_desc(uint64_t root, uint64_t va, int level) {
    uint64_t table = root;
    for (int l = 0;; l++) {
        uint64_t *e = (uint64_t *)(uintptr_t)table + ((va >> (14 + 11 * (3 - l))) & (l == 0 ? 1 : 0x7ff));
        if (l == level) return e;
        if (!(*e & 1)) *e = sw_table() | 3;
        table = *e & 0x0000ffffffffc000ull;
    }
}

static void sw_cpu(HvCpu *c, HvMachine *m, uint32_t index, uint64_t ttbr0) {
    hv_cpu_reset_index(c, m, index);
    c->tcr_el1 = 16 | 2u << 14 | 1u << 23 | 5ull << 32; /* T0SZ 16, TG0 16 KB, EPD1, 48-bit PA */
    c->mair_el1 = 0xff;
    c->sctlr_el1 |= 1;
    c->ttbr0_el1 = ttbr0;
    hv_ijc_switch(c);
}

static void sw_switch(HvCpu *c, uint64_t ttbr0) {
    c->el = 1;
    c->x[3] = ttbr0;
    hv_sysreg_msr(c, 0xd5182003u, 0); /* msr ttbr0_el1, x3 */
}

static void sw_tlbi(HvCpu *c, uint32_t insn, uint64_t xt) {
    c->el = 1;
    c->x[1] = xt;
    hv_sysreg_sys(c, insn | 1, 0); /* tlbi ..., x1 */
}
#define TLBI_VAE1 0xd5088720u    /* this CPU */
#define TLBI_VAE1IS 0xd5088320u  /* every CPU */
#define TLBI_VAAE1IS 0xd5088360u /* every CPU, every ASID */
#define TLBI_ASIDE1IS 0xd5088340u
#define TLBI_VA(va, asid) ((uint64_t)(asid) << 48 | ((va) >> 12 & 0xfffffffffffull))

static void sw_fill(HvCpu *c, uint64_t va) {
    uint64_t pa;
    hv_mmu_access(c, va, HV_ACC_READ, 0, &pa);
}

/* The host page c's EL0 TLB entry for va leads to, 0 if it has none for va. */
static uint64_t sw_live(HvCpu *c, uint64_t va) {
    const HvTlbEntry *e = hv_tlb_ent(c, (uint32_t)(va >> 14) & (HV_TLB_SIZE - 1), 0);
    if (e->read_tag == HV_TLB_INVALID || e->read_tag + HV_TLB_ADJ != (va & ~0x3fffull)) return 0;
    return (va & ~0x3fffull) + (uint64_t)e->addend;
}

static void sw_expect(const char *what, HvCpu *c, uint64_t va, uint64_t want) {
    uint64_t got = sw_live(c, va);
    checks++;
    if (got != want) {
        printf("  FAIL %s: va %llx leads to %llx, expected %llx\n", what, (unsigned long long)va, (unsigned long long)got,
               (unsigned long long)want);
        failures++;
    }
}

#define SW_SPACES 12
#define SW_P(i) (0x100000000ull + ((uint64_t)(i) << 14)) /* a process's own pages: each space maps them elsewhere */

/* Twelve address spaces (ASIDs 1-12), each with its own tables, page SW_P(i) of space k at data page (k + i) % SW_DATA. */
static uint64_t sw_space(int k) {
    uint64_t root = sw_table();
    for (int i = 0; i < 8; i++) *sw_desc(root, SW_P(i), 3) = sw_data((k + i) % SW_DATA) | SW_USER;
    return root | (uint64_t)(k + 1) << 48;
}

static void stash_test(void) {
    static HvMachine sm;
    static HvCpu c0, c1;
    if (hv_machine_init(&sm, 1 << 20) != 0) exit(1);
    sm.stats_interval = 3600; /* counted as on a device, never printed here */
    sw_mem = aligned_alloc(16384, (SW_TABLES + SW_DATA) * 16384);
    sw_next = 0;
    hv_machine_add_ram(&sm, ADDR(sw_mem), (SW_TABLES + SW_DATA) * 16384, sw_mem, 0);
    uint64_t sp[SW_SPACES];
    for (int k = 0; k < SW_SPACES; k++) sp[k] = sw_space(k);
    sw_cpu(&c0, &sm, 0, sp[0]);
    sw_cpu(&c1, &sm, 1, sp[1]);
    HvStats *st = &c0.pc_state->own.stats;
#define PG(k, i) sw_data(((k) + (i)) % SW_DATA)

    /* Refills by what the slot held: empty, then another page (128 MB on: the same slot). */
    {
        const uint64_t q = SW_P(0) + ((uint64_t)HV_TLB_SIZE << 14);
        *sw_desc(sp[0] & 0x0000fffffffffffeull, q, 3) = sw_data(31) | SW_USER;
        uint64_t e0 = st->refill_kind[0], t0 = st->refill_kind[1];
        int r1 = hv_tlb_refill(&c0, SW_P(0), 0), r2 = hv_tlb_refill(&c0, q, 0);
        checks += 2;
        if (r1 || r2) printf("  FAIL refills of mapped pages: %d %d\n", r1, r2), failures++;
        if (st->refill_kind[0] != e0 + 1 || st->refill_kind[1] != t0 + 1)
            printf("  FAIL refill kinds: empty +%llu, slot taken +%llu\n", (unsigned long long)(st->refill_kind[0] - e0),
                   (unsigned long long)(st->refill_kind[1] - t0)), failures++;
        hv_tlb_flush(&c0);
    }

    /* Out and back: the entries come back; the second time out only what was filled since is copied. */
    for (int i = 0; i < 4; i++) sw_fill(&c0, SW_P(i));
    uint64_t miss0 = st->stash_miss, out0 = st->stash_out, hits0 = st->stash_hits;
    sw_switch(&c0, sp[1]);
    checks += 3;
    if (st->stash_miss != miss0 + 1) printf("  FAIL a first switch to a space found a stash\n"), failures++;
    if (st->stash_out != out0 + 4) printf("  FAIL switch out copied %llu entries, want 4\n", (unsigned long long)(st->stash_out - out0)), failures++;
    sw_expect("switched out", &c0, SW_P(0), 0);
    sw_fill(&c0, SW_P(0));
    sw_expect("the other space's own page", &c0, SW_P(0), PG(1, 0));
    sw_switch(&c0, sp[0]);
    if (st->stash_hits != hits0 + 1) printf("  FAIL switching back found no stash\n"), failures++;
    for (int i = 0; i < 4; i++) sw_expect("switched back", &c0, SW_P(i), PG(0, i));
    sw_fill(&c0, SW_P(4));
    out0 = st->stash_out;
    sw_switch(&c0, sp[1]);
    checks++;
    if (st->stash_out != out0 + 1) printf("  FAIL switch out again copied %llu entries, want 1 (the one filled since)\n", (unsigned long long)(st->stash_out - out0)), failures++;
    sw_expect("its own entry back", &c0, SW_P(0), PG(1, 0));
    sw_switch(&c0, sp[0]);
    for (int i = 0; i < 5; i++) sw_expect("back with the new one", &c0, SW_P(i), PG(0, i));

    /* TLBIs reach the entries put back, live and in the stash: here, from another CPU, by ASID. */
    sw_tlbi(&c0, TLBI_VAE1, TLBI_VA(SW_P(1), 1));
    sw_expect("TLBI here", &c0, SW_P(1), 0);
    sw_tlbi(&c1, TLBI_VAE1IS, TLBI_VA(SW_P(2), 1));
    hv_cpu_process_requests(&c0);
    sw_expect("TLBI from another CPU", &c0, SW_P(2), 0);
    sw_switch(&c0, sp[1]);
    sw_switch(&c0, sp[0]);
    sw_expect("TLBI here, out and back", &c0, SW_P(1), 0);
    sw_expect("TLBI from another CPU, out and back", &c0, SW_P(2), 0);
    sw_expect("untouched, out and back", &c0, SW_P(3), PG(0, 3));
    sw_tlbi(&c1, TLBI_VAE1IS, TLBI_VA(SW_P(3), 1));
    sw_switch(&c0, sp[1]); /* the other CPU's TLBI while switched out */
    hv_cpu_process_requests(&c0);
    sw_switch(&c0, sp[0]);
    sw_expect("TLBI from another CPU while out", &c0, SW_P(3), 0);
    sw_expect("its neighbour", &c0, SW_P(4), PG(0, 4));
    sw_tlbi(&c1, TLBI_ASIDE1IS, 1ull << 48);
    hv_cpu_process_requests(&c0);
    sw_expect("TLBI by ASID", &c0, SW_P(4), 0);
    sw_fill(&c0, SW_P(5));
    sw_switch(&c0, sp[1]);
    sw_switch(&c0, sp[0]);
    sw_expect("TLBI by ASID, out and back", &c0, SW_P(4), 0);
    sw_expect("filled after the TLBI by ASID", &c0, SW_P(5), PG(0, 5));

    /* Twelve processes in turn, then back to each: all twelve were kept. Then an all-ASID TLBI of one page from
       another CPU drops it from every stash, and one of a page no stash holds drops nothing. */
    for (int k = 0; k < SW_SPACES; k++) sw_switch(&c0, sp[k]), sw_fill(&c0, SW_P(6)), sw_fill(&c0, SW_P(7));
    hits0 = st->stash_hits;
    for (int k = 0; k < SW_SPACES; k++) sw_switch(&c0, sp[k]), sw_expect("one of twelve", &c0, SW_P(6), PG(k, 6));
    checks++;
    if (st->stash_hits != hits0 + SW_SPACES) printf("  FAIL twelve processes: %llu stashes found\n", (unsigned long long)(st->stash_hits - hits0)), failures++;
    sw_tlbi(&c1, TLBI_VAAE1IS, TLBI_VA(SW_P(6), 0));
    sw_tlbi(&c1, TLBI_VAAE1IS, TLBI_VA(SW_P(0) + (40ull << 14), 0));
    hv_cpu_process_requests(&c0);
    for (int k = 0; k < SW_SPACES; k++) {
        sw_switch(&c0, sp[k]);
        sw_expect("all-ASID TLBI, every stash", &c0, SW_P(6), 0);
        sw_expect("all-ASID TLBI of another page", &c0, SW_P(7), PG(k, 7));
    }
#undef PG
    free(sw_mem);
}

/* Entries that stay across a switch: processes A (ASID 20) and B (ASID 21) share the level 3 table of the twig at
   SW_S (as every process shares the shared region's) and each has its own at SW_P. What B's tables map the same as A's
   stays live when A switches to B, and only that: a twig remapped, a descriptor changed (TLBI or not yet), fewer rights
   all make it go; and what stayed dies on TLBIs from either CPU. */
#define SW_S(i) (0x180000000ull + (((uint64_t)(i) + 64) << 14)) /* TLB slots 64 on: not SW_P's */

static void keep_test(void) {
    static HvMachine km;
    static HvCpu c0, c1;
    if (hv_machine_init(&km, 1 << 20) != 0) exit(1);
    km.stats_interval = 3600;
    sw_mem = aligned_alloc(16384, (SW_TABLES + SW_DATA) * 16384);
    sw_next = 0;
    hv_machine_add_ram(&km, ADDR(sw_mem), (SW_TABLES + SW_DATA) * 16384, sw_mem, 0);
    uint64_t ra = sw_table(), rb = sw_table(), shared = sw_table(), other = sw_table();
    for (int i = 0; i < 8; i++) {
        ((uint64_t *)(uintptr_t)shared)[(SW_S(i) >> 14) & 0x7ff] = sw_data(i) | SW_USER;
        ((uint64_t *)(uintptr_t)other)[(SW_S(i) >> 14) & 0x7ff] = sw_data(16 + i) | SW_USER;
        *sw_desc(ra, SW_P(i), 3) = sw_data(8 + i) | SW_USER;
        *sw_desc(rb, SW_P(i), 3) = sw_data(24 + i) | SW_USER;
    }
    uint64_t *la = sw_desc(ra, SW_S(0), 2), *lb = sw_desc(rb, SW_S(0), 2);
    *la = shared | 3, *lb = shared | 3;
    const uint64_t A = ra | 20ull << 48, B = rb | 21ull << 48;
    sw_cpu(&c0, &km, 0, A);
    sw_cpu(&c1, &km, 1, B);
    HvStats *st = &c0.pc_state->own.stats;

    /* A to B and back: the shared twig's entries stay, the own twig's do not (each gets its own back from its stash). */
    sw_fill(&c0, SW_S(0)), sw_fill(&c0, SW_S(1)), sw_fill(&c0, SW_P(0));
    uint64_t kept0 = st->switch_kept;
    sw_switch(&c0, B);
    checks++;
    if (st->switch_kept != kept0 + 2) printf("  FAIL A to B kept %llu entries, want 2\n", (unsigned long long)(st->switch_kept - kept0)), failures++;
    sw_expect("shared twig, kept", &c0, SW_S(0), sw_data(0));
    sw_expect("shared twig, kept too", &c0, SW_S(1), sw_data(1));
    sw_expect("own twig, not kept", &c0, SW_P(0), 0);
    sw_fill(&c0, SW_P(0));
    sw_switch(&c0, A);
    sw_expect("shared twig, kept back", &c0, SW_S(0), sw_data(0));
    sw_expect("own twig, from the stash", &c0, SW_P(0), sw_data(8));
    sw_switch(&c0, B);
    sw_expect("own twig, B's from its stash", &c0, SW_P(0), sw_data(24));
    sw_switch(&c0, A);

    /* What stayed dies on TLBIs: another CPU's of the page under the other ASID (the live TLB does not tell ASIDs
       apart), this CPU's own, another CPU's all-ASID one after a switch, and by ASID. */
    sw_tlbi(&c1, TLBI_VAE1IS, TLBI_VA(SW_S(0), 21));
    hv_cpu_process_requests(&c0);
    sw_expect("kept, then another CPU's TLBI under the other ASID", &c0, SW_S(0), 0);
    sw_tlbi(&c0, TLBI_VAE1, TLBI_VA(SW_S(1), 20));
    sw_expect("kept, then a TLBI here", &c0, SW_S(1), 0);
    sw_fill(&c0, SW_S(2)), sw_fill(&c0, SW_S(3));
    sw_switch(&c0, B);
    sw_expect("kept into B", &c0, SW_S(2), sw_data(2));
    sw_tlbi(&c1, TLBI_VAAE1IS, TLBI_VA(SW_S(2), 0));
    hv_cpu_process_requests(&c0);
    sw_expect("kept into B, then another CPU's all-ASID TLBI", &c0, SW_S(2), 0);
    sw_tlbi(&c1, TLBI_ASIDE1IS, 21ull << 48);
    hv_cpu_process_requests(&c0);
    sw_expect("kept into B, then B's TLBI by ASID", &c0, SW_S(3), 0);
    sw_switch(&c0, A);
    sw_expect("dropped in B, not back in A from A's stash", &c0, SW_S(2), 0);

    /* A twig remapped in B while A runs (break, TLBI by B's ASID, make): what A has there does not go into B. */
    *lb = 0;
    sw_tlbi(&c1, TLBI_ASIDE1IS, 21ull << 48); /* drops all of this CPU's live user entries too */
    hv_cpu_process_requests(&c0);
    *lb = other | 3;
    sw_fill(&c0, SW_S(4));
    sw_switch(&c0, B);
    sw_expect("twig remapped: not kept", &c0, SW_S(4), 0);
    sw_fill(&c0, SW_S(4));
    sw_expect("twig remapped: B's own page", &c0, SW_S(4), sw_data(20));
    sw_switch(&c0, A);
    sw_expect("twig remapped: not kept back into A", &c0, SW_S(4), sw_data(4)); /* A's stash has its own */
    *lb = shared | 3;
    sw_tlbi(&c1, TLBI_ASIDE1IS, 21ull << 48);
    hv_cpu_process_requests(&c0);

    /* A shared descriptor changed and not yet TLBI'd: what A has of it does not go into B (B walks it anew), and
       neither does an entry with more rights than the descriptor now gives. */
    sw_fill(&c0, SW_S(5));
    uint64_t pa = 0;
    hv_mmu_access(&c0, SW_S(6), HV_ACC_WRITE, 0, &pa);
    ((uint64_t *)(uintptr_t)shared)[(SW_S(5) >> 14) & 0x7ff] = sw_data(30) | SW_USER;
    ((uint64_t *)(uintptr_t)shared)[(SW_S(6) >> 14) & 0x7ff] = sw_data(6) | SW_USER | 2ull << 6; /* EL0 read-only */
    sw_switch(&c0, B);
    sw_expect("descriptor changed: not kept", &c0, SW_S(5), 0);
    sw_expect("fewer rights: not kept", &c0, SW_S(6), 0);
    checks++;
    if (hv_tlb_ent(&c0, (uint32_t)(SW_S(6) >> 14) & (HV_TLB_SIZE - 1), 0)->write_tag != HV_TLB_INVALID)
        printf("  FAIL a writable entry stayed over a read-only descriptor\n"), failures++;
    ((uint64_t *)(uintptr_t)shared)[(SW_S(5) >> 14) & 0x7ff] = sw_data(5) | SW_USER;
    ((uint64_t *)(uintptr_t)shared)[(SW_S(6) >> 14) & 0x7ff] = sw_data(6) | SW_USER;
    sw_tlbi(&c1, TLBI_VAAE1IS, TLBI_VA(SW_S(5), 0));
    sw_tlbi(&c1, TLBI_VAAE1IS, TLBI_VA(SW_S(6), 0));
    hv_cpu_process_requests(&c0);

    /* Many switches both ways with the shared pages in use: they stay, and each process's own pages are its own. */
    for (int k = 0; k < 20; k++) {
        uint64_t to = k & 1 ? A : B;
        sw_switch(&c0, to);
        for (int i = 0; i < 4; i++) sw_fill(&c0, SW_S(i)), sw_fill(&c0, SW_P(i));
        for (int i = 0; i < 4; i++) {
            sw_expect("back and forth, shared", &c0, SW_S(i), sw_data(i));
            sw_expect("back and forth, own", &c0, SW_P(i), sw_data((k & 1 ? 8 : 24) + i));
        }
    }
    free(sw_mem);
}

/* A busy process keeps its stash: switching to B brings back B's whole stash while 1500 of A's shared entries could
   stay, then B fills 400 more (a device: 31-94 a switch). Kept and brought-back entries leave room for those, so the
   next switch away still saves B's stash and B gets its entries back. */
#define SW_RS(i) (0x180000000ull + ((uint64_t)(i) << 14))          /* shared twig: TLB slots 0-2047 */
#define SW_RP(i) (0x100000000ull + (((uint64_t)(i) + 2048) << 14)) /* B's own twig: slots 2048-4095 */

static void room_test(void) {
    static HvMachine rm;
    static HvCpu c0;
    if (hv_machine_init(&rm, 1 << 20) != 0) exit(1);
    rm.stats_interval = 3600;
    sw_mem = aligned_alloc(16384, (SW_TABLES + SW_DATA) * 16384);
    sw_next = 0;
    hv_machine_add_ram(&rm, ADDR(sw_mem), (SW_TABLES + SW_DATA) * 16384, sw_mem, 0);
    uint64_t ra = sw_table(), rb = sw_table(), shared = sw_table();
    for (int i = 0; i < 2048; i++) ((uint64_t *)(uintptr_t)shared)[i] = sw_data(i % SW_DATA) | SW_USER;
    *sw_desc(ra, SW_RS(0), 2) = shared | 3, *sw_desc(rb, SW_RS(0), 2) = shared | 3;
    const int own = HV_STASH_CAP + 400;
    for (int i = 0; i < own; i++) *sw_desc(rb, SW_RP(i), 3) = sw_data(i % SW_DATA) | SW_USER;
    const uint64_t A = ra | 30ull << 48, B = rb | 31ull << 48;
    sw_cpu(&c0, &rm, 0, A);
    HvStats *st = &c0.pc_state->own.stats;

    sw_switch(&c0, B);
    for (int i = 0; i < HV_STASH_CAP; i++) sw_fill(&c0, SW_RP(i));
    sw_switch(&c0, A); /* B's stash: full */
    for (int i = 0; i < 1500; i++) sw_fill(&c0, SW_RS(i));
    sw_switch(&c0, B); /* A's shared entries may stay, B's stash comes back */
    for (int i = HV_STASH_CAP; i < own; i++) sw_fill(&c0, SW_RP(i));
    checks++;
    if (c0.nuser_fills > HV_USER_FILLS)
        printf("  FAIL kept and brought-back entries left no room for 400 fills: %u listed\n", c0.nuser_fills), failures++;
    sw_switch(&c0, A);
    uint64_t hits0 = st->stash_hits;
    sw_switch(&c0, B);
    checks++;
    if (st->stash_hits != hits0 + 1) printf("  FAIL a busy process lost its stash\n"), failures++;
    sw_expect("busy process: its first entry back", &c0, SW_RP(0), sw_data(0));
    sw_expect("busy process: its last stashed entry back", &c0, SW_RP(HV_STASH_CAP - 1), sw_data((HV_STASH_CAP - 1) % SW_DATA));
    free(sw_mem);
}

/* O8b: a TTBR0 write (a process switch) does the TLBIs other CPUs asked of this one first. */
static void switch_does_requests(HvMachine *m) {
    static HvCpu c;
    hv_cpu_reset_index(&c, m, 2);
    HvPerCpu *p = c.pc_state;
    uint64_t seq = hv_cpu_post_tlbi(&c, 0, 8, 3, 0, 0); /* TLBI VMALLE1IS */
    checks += 2;
    if (__atomic_load_n(&p->ack_seq, __ATOMIC_ACQUIRE) >= seq) printf("  FAIL a request was done before its CPU ran\n"), failures++;
    c.el = 1;
    c.x[3] = 0x4000 | 3ull << 48;
    hv_sysreg_msr(&c, 0xd5182003u, 0); /* msr ttbr0_el1, x3 */
    if (__atomic_load_n(&p->ack_seq, __ATOMIC_ACQUIRE) < seq) printf("  FAIL a process switch left a TLBI request for later\n"), failures++;
}

int main(void) {
    alarm(300); /* a multi-CPU test that hangs fails */
    static HvMachine m;
    static HvCpu cpu;
    hv_machine_init(&m, 1 << 20);
    pt = aligned_alloc(65536, PT_SIZE);
    hv_machine_add_ram(&m, PT_PA, PT_SIZE, pt, 0);
    hv_cpu_reset(&cpu, &m);

    expect("mmu off", &cpu, 0x12345678, HV_ACC_WRITE, 1, 0x12345678, 0);

    /* 16 KB granule, 48-bit TTBR0 (four levels), 39-bit TTBR1 (three levels). */
    uint64_t r0 = alloc_table(), r1 = alloc_table();
    cpu.ttbr0_el1 = r0 | 0x1234ull << 48; /* an ASID must not leak into the table address */
    cpu.ttbr1_el1 = r1;
    cpu.mair_el1 = 0x00ff;
    cpu.tcr_el1 = 16 | 2u << 14 | 25u << 16 | 1u << 30 | 5ull << 32 | 1ull << 37; /* T0SZ 16, TG0 16K, T1SZ 25, TG1 16K, TBI0 */
    cpu.sctlr_el1 |= 1;

    map(r0, 14, 48, 0x100004000, 3, 0x40008000 | PAGE | AF | AP(0), 0);
    expect("16K page", &cpu, 0x100004abc, HV_ACC_READ, 1, 0x40008abc, 0);
    expect("16K page, next page unmapped", &cpu, 0x100008000, HV_ACC_READ, 1, 0, HV_FSC_TRANSLATION(3));
    expect("16K, no level 1 table", &cpu, 0x7f0000000000, HV_ACC_READ, 1, 0, HV_FSC_TRANSLATION(1));
    expect("16K, VA above T0SZ", &cpu, 0x0001000000000000, HV_ACC_READ, 1, 0, HV_FSC_TRANSLATION(0));
    expect("TBI0 ignores the top byte", &cpu, 0x5a00000100004010, HV_ACC_READ, 1, 0x40008010, 0);
    cpu.tcr_el1 &= ~(1ull << 37);
    expect("without TBI0 a tag faults", &cpu, 0x5a00000100004010, HV_ACC_READ, 1, 0, HV_FSC_TRANSLATION(0));
    cpu.tcr_el1 |= 1ull << 37;

    map(r0, 14, 48, 0x200000000, 2, 0x82000000 | BLOCK | AF, 0);
    expect("16K: 32 MB block", &cpu, 0x201234560, HV_ACC_WRITE, 1, 0x83234560, 0);
    map(r0, 14, 48, 0x300000000, 3, 0x40010000 | PAGE, 0);
    expect("access flag clear", &cpu, 0x300000000, HV_ACC_READ, 1, 0, HV_FSC_ACCESS(3));

    /* Permissions. */
    map(r0, 14, 48, 0x100010000, 3, 0x40010000 | PAGE | AF | AP(2), 0); /* EL1 RO */
    expect("EL1 RO: read", &cpu, 0x100010000, HV_ACC_READ, 1, 0x40010000, 0);
    expect("EL1 RO: write", &cpu, 0x100010000, HV_ACC_WRITE, 1, 0, HV_FSC_PERMISSION(3));
    expect("EL1 only: EL0 read", &cpu, 0x100004000, HV_ACC_READ, 0, 0, HV_FSC_PERMISSION(3));
    map(r0, 14, 48, 0x100014000, 3, 0x40014000 | PAGE | AF | AP(1), 0); /* EL0 and EL1 RW */
    expect("EL0 RW: EL0 write", &cpu, 0x100014000, HV_ACC_WRITE, 0, 0x40014000, 0);
    expect("EL0 RW: EL1 cannot execute", &cpu, 0x100014000, HV_ACC_EXEC, 1, 0, HV_FSC_PERMISSION(3));
    expect("EL0 RW: EL0 executes", &cpu, 0x100014000, HV_ACC_EXEC, 0, 0x40014000, 0);
    cpu.pstate_extra |= HV_PSTATE_PAN;
    expect("PAN: EL1 read of an EL0 page", &cpu, 0x100014000, HV_ACC_READ, 1, 0, HV_FSC_PERMISSION(3));
    expect("PAN: EL1 page unaffected", &cpu, 0x100004000, HV_ACC_READ, 1, 0x40008000, 0);
    expect("PAN: LDTR uses EL0 rights", &cpu, 0x100014000, HV_ACC_READ, 0, 0x40014000, 0);
    cpu.pstate_extra &= ~(uint64_t)HV_PSTATE_PAN;
    map(r0, 14, 48, 0x100018000, 3, 0x40018000 | PAGE | AF | AP(3) | UXN, 0); /* RO both, EL0 XN */
    expect("UXN: EL0 exec", &cpu, 0x100018000, HV_ACC_EXEC, 0, 0, HV_FSC_PERMISSION(3));
    expect("UXN: EL1 exec", &cpu, 0x100018000, HV_ACC_EXEC, 1, 0x40018000, 0);
    map(r0, 14, 48, 0x10001c000, 3, 0x4001c000 | PAGE | AF | PXN, 0);
    expect("PXN: EL1 exec", &cpu, 0x10001c000, HV_ACC_EXEC, 1, 0, HV_FSC_PERMISSION(3));
    cpu.sctlr_el1 |= 1u << 19;
    expect("WXN: writable is not executable", &cpu, 0x100004000, HV_ACC_EXEC, 1, 0, HV_FSC_PERMISSION(3));
    cpu.sctlr_el1 &= ~(1ull << 19);
    expect("no WXN: executable", &cpu, 0x100004000, HV_ACC_EXEC, 1, 0x40008000, 0);

    /* APTable on a new level 1 table: bit 61 = no EL0, bit 62 = no writes. */
    map(r0, 14, 48, 0x500000000000, 3, 0x40020000 | PAGE | AF | AP(1), 1ull << 61);
    expect("APTable no-EL0", &cpu, 0x500000000000, HV_ACC_READ, 0, 0, HV_FSC_PERMISSION(3));
    map(r0, 14, 48, 0x600000000000, 3, 0x40024000 | PAGE | AF | AP(0), 1ull << 62);
    expect("APTable read-only", &cpu, 0x600000000000, HV_ACC_WRITE, 1, 0, HV_FSC_PERMISSION(3));
    expect("APTable read-only: read", &cpu, 0x600000000000, HV_ACC_READ, 1, 0x40024000, 0);

    /* TTBR1, 39-bit: starts at level 1. */
    map(r1, 14, 39, 0xffffffc012340000, 3, 0x40028000 | PAGE | AF, 0);
    expect("TTBR1 page", &cpu, 0xffffffc012343210, HV_ACC_READ, 1, 0x4002b210, 0);
    expect("TTBR1: hole between ranges", &cpu, 0xffff000012340000, HV_ACC_READ, 1, 0, HV_FSC_TRANSLATION(0));
    cpu.tcr_el1 |= 1u << 23;
    expect("EPD1 disables TTBR1 walks", &cpu, 0xffffffc012343210, HV_ACC_READ, 1, 0, HV_FSC_TRANSLATION(0));
    cpu.tcr_el1 &= ~(1ull << 23);

    /* The TLB only takes 16 KB or larger mappings. */
    uint64_t pa;
    hv_tlb_flush(&cpu);
    hv_mmu_access(&cpu, 0x100004000, HV_ACC_READ, 1, &pa);
    checks++;
    /* 0x40008000 is not RAM here, so nothing may be filled */
    if ((*hv_tlb_ent(&cpu, (0x100004000 >> 14) & (HV_TLB_SIZE - 1), 1)).read_tag != HV_TLB_INVALID) {
        printf("  FAIL TLB filled for non-RAM\n");
        failures++;
    }

    /* 4 KB granule, 39-bit TTBR0 (levels 1-3): pages, 2 MB and 1 GB blocks. */
    pt_next = 2 * 65536;
    uint64_t r4 = alloc_table();
    cpu.ttbr0_el1 = r4;
    cpu.tcr_el1 = 25 | 0u << 14 | 1u << 23 | 5ull << 32;
    map(r4, 12, 39, 0x12345000, 3, 0x40001000 | PAGE | AF, 0);
    expect("4K page", &cpu, 0x12345678, HV_ACC_READ, 1, 0x40001678, 0);
    map(r4, 12, 39, 0x40200000, 2, 0x80400000 | BLOCK | AF, 0);
    expect("4K: 2 MB block", &cpu, 0x40212345, HV_ACC_READ, 1, 0x80412345, 0);
    map(r4, 12, 39, 0x4000000000 - 0x40000000, 1, 0xc0000000 | BLOCK | AF, 0);
    expect("4K: 1 GB block", &cpu, 0x3fc0123456, HV_ACC_READ, 1, 0xc0123456, 0);
    hv_tlb_flush(&cpu);
    hv_mmu_access(&cpu, 0x12345678, HV_ACC_READ, 1, &pa);
    checks++;
    if ((*hv_tlb_ent(&cpu, (0x12345678 >> 14) & (HV_TLB_SIZE - 1), 1)).read_tag != HV_TLB_INVALID) {
        printf("  FAIL a 4K mapping went into the 16K TLB\n");
        failures++;
    }

    /* 64 KB granule, 42-bit TTBR0 (levels 2-3): pages and 512 MB blocks. */
    uint64_t r6 = alloc_table();
    cpu.ttbr0_el1 = r6;
    cpu.tcr_el1 = 22 | 1u << 14 | 1u << 23 | 5ull << 32;
    map(r6, 16, 42, 0x123450000, 3, 0x40050000 | PAGE | AF, 0);
    expect("64K page", &cpu, 0x12345abcd, HV_ACC_READ, 1, 0x4005abcd, 0);
    map(r6, 16, 42, 0x200000000, 2, 0x60000000 | BLOCK | AF, 0);
    expect("64K: 512 MB block", &cpu, 0x21234abcd, HV_ACC_READ, 1, 0x7234abcd, 0);
    map(r6, 16, 42, 0x300000000, 3, 0x40060000 | BLOCK | AF, 0);
    expect("block descriptor at level 3 is invalid", &cpu, 0x300000000, HV_ACC_READ, 1, 0, HV_FSC_TRANSLATION(3));

    /* TLBI RVAE1IS: 6 pages of 16 KB from the base drop, the ones after stay; also for a kernel range. */
    {
        static const uint64_t bases[2] = {0x100000000ull, 0xfffffe0012340000ull};
        for (int b = 0; b < 2; b++) {
            hv_tlb_flush(&cpu);
            int table = (bases[b] >> 55) & 1 ? 1 : 0;
            for (int k = 0; k < 8; k++) {
                uint64_t va = bases[b] + ((uint64_t)k << 14);
                HvTlbEntry *t = &(*hv_tlb_ent(&cpu, (va >> 14) & (HV_TLB_SIZE - 1), table));
                t->read_tag = va - HV_TLB_ADJ;
                t->addend = 0;
            }
            cpu.el = 1;
            cpu.x[1] = 5ull << 48 | 2ull << 46 | 0ull << 44 | 2ull << 39 | ((bases[b] >> 14) & 0x1fffffffffull);
            hv_sysreg_sys(&cpu, 0xd5088221u, 0); /* tlbi rvae1is, x1 */
            for (int k = 0; k < 8; k++) {
                uint64_t va = bases[b] + ((uint64_t)k << 14);
                int dropped = (*hv_tlb_ent(&cpu, (va >> 14) & (HV_TLB_SIZE - 1), table)).read_tag == HV_TLB_INVALID;
                checks++;
                if (dropped != (k < 6)) {
                    printf("  FAIL range TLBI, base %llx page %d: %s\n", (unsigned long long)bases[b], k,
                           dropped ? "dropped" : "kept");
                    failures++;
                }
            }
        }
    }

    /* A big kernel-range TLBI drops the kernel pages in the range and keeps the rest, the processes' entries included
       (it used to flush everything). 512 pages goes page by page, 6144 pages by a scan. */
    {
        static const struct { uint32_t scale, num, pages; } ranges[2] = {{1, 7, 512}, {2, 2, 6144}};
        const uint64_t base = 0xfffffe0040000000ull;
        for (int r = 0; r < 2; r++) {
            hv_tlb_flush(&cpu);
            const int32_t ks[6] = {0, 1, (int32_t)ranges[r].pages / 2, (int32_t)ranges[r].pages - 1, (int32_t)ranges[r].pages, (int32_t)ranges[r].pages + 300};
            for (int k = 0; k < 6; k++) {
                uint64_t va = base + ((uint64_t)ks[k] << 14);
                HvTlbEntry *t = hv_tlb_ent(&cpu, (va >> 14) & (HV_TLB_SIZE - 1), 1);
                t->read_tag = va - HV_TLB_ADJ;
                t->addend = 0;
            }
            uint64_t uva = 0x100000000ull + ((uint64_t)7000 << 14); /* a process's page, in a slot outside the range's */
            HvTlbEntry *u = hv_tlb_ent(&cpu, (uva >> 14) & (HV_TLB_SIZE - 1), 0);
            u->read_tag = uva - HV_TLB_ADJ;
            u->addend = 0;
            cpu.el = 1;
            cpu.x[1] = 0ull << 48 | 2ull << 46 | (uint64_t)ranges[r].scale << 44 | (uint64_t)ranges[r].num << 39 | ((base >> 14) & 0x1fffffffffull);
            hv_sysreg_sys(&cpu, 0xd5088221u, 0); /* tlbi rvae1is, x1 */
            for (int k = 0; k < 6; k++) {
                uint64_t va = base + ((uint64_t)ks[k] << 14);
                int dropped = hv_tlb_ent(&cpu, (va >> 14) & (HV_TLB_SIZE - 1), 1)->read_tag == HV_TLB_INVALID;
                checks++;
                if (dropped != (ks[k] < (int32_t)ranges[r].pages)) {
                    printf("  FAIL big kernel range %u pages, page %d: %s\n", ranges[r].pages, ks[k], dropped ? "dropped" : "kept");
                    failures++;
                }
            }
            checks++;
            if (hv_tlb_ent(&cpu, (uva >> 14) & (HV_TLB_SIZE - 1), 0)->read_tag == HV_TLB_INVALID) {
                printf("  FAIL big kernel range %u pages dropped a process's entry\n", ranges[r].pages);
                failures++;
            }
        }
    }

    /* A TLBI by VA and ASID forgets the indirect-branch cache entries of that page
       for that address space, and nothing else. Entries are filled the way the dispatcher does it. */
    {
        hv_cpu_reset(&cpu, &m);
        cpu.tcr_el1 = 0;
        cpu.ttbr0_el1 = 7ull << 48;
        hv_ijc_switch(&cpu);
        uint64_t salt = cpu.ijc_salt[0];
        static const uint64_t vas[3] = {0x100004010ull, 0x100007ffcull, 0x100008010ull}; /* page P twice, then page Q */
        uint64_t *ents[3];
        static HvBlock fake[3];
        for (int i = 0; i < 3; i++) {
            fake[i] = (HvBlock){.va = vas[i], .flags = 0, .code_off = 0x1234};
            hv_ijc_fill(&cpu, &fake[i]);
            ents[i] = m.percpu[0].ijc + (size_t)hv_ijc_index(vas[i] ^ salt) * 2;
        }
        hv_tlb_flush_va_asid(&cpu, 0x100004000ull, 7);
        int want[3] = {0, 0, 1};
        for (int i = 0; i < 3; i++) {
            checks++;
            if ((ents[i][0] != 0) != want[i]) {
                printf("  FAIL branch cache after TLBI of page P: entry %d %s\n", i, ents[i][0] ? "kept" : "dropped");
                failures++;
            }
        }
        /* Another address space's TLBI of page Q leaves this one's entry alone. */
        hv_tlb_flush_va_asid(&cpu, 0x100008000ull, 9);
        checks++;
        if (!ents[2][0]) {
            printf("  FAIL another ASID's TLBI dropped our entry\n");
            failures++;
        }
        /* Every address space's TLBI of page Q: that page's targets go under every live id (ASID 9's too), the rest
           stay, and no process loses its id (the whole user half used to start over). */
        static HvBlock other[2];
        cpu.ttbr0_el1 = 9ull << 48;
        hv_ijc_switch(&cpu);
        uint64_t salt9 = cpu.ijc_salt[0];
        other[0] = (HvBlock){.va = vas[2] + 0x40, .flags = 0, .code_off = 0x1234}; /* ASID 9's, in Q */
        hv_ijc_fill(&cpu, &other[0]);
        cpu.ttbr0_el1 = 7ull << 48;
        hv_ijc_switch(&cpu);
        other[1] = (HvBlock){.va = 0x10000c020ull, .flags = 0, .code_off = 0x1234}; /* ASID 7's, in page R */
        hv_ijc_fill(&cpu, &other[1]);
        uint16_t cid7 = cpu.asid_cid[7], cid9 = cpu.asid_cid[9];
        hv_tlb_flush_va_asid(&cpu, 0x100008000ull, -1); /* all address spaces */
        checks += 4;
        uint64_t now = vas[2] ^ cpu.ijc_salt[0]; /* what a lookup would compare against now */
        if (m.percpu[0].ijc[(size_t)hv_ijc_index(now) * 2] == now) {
            printf("  FAIL an all-ASID TLBI kept the entry\n");
            failures++;
        }
        uint64_t t9 = other[0].va ^ salt9, tr = other[1].va ^ salt;
        if (m.percpu[0].ijc[(size_t)hv_ijc_index(t9) * 2] == t9) printf("  FAIL an all-ASID TLBI kept another process's entry in the page\n"), failures++;
        if (m.percpu[0].ijc[(size_t)hv_ijc_index(tr) * 2] != tr) printf("  FAIL an all-ASID TLBI dropped an entry in another page\n"), failures++;
        if (cpu.asid_cid[7] != cid7 || cpu.asid_cid[9] != cid9) printf("  FAIL an all-ASID TLBI of one page gave processes new ids\n"), failures++;
    }

    /* A big range TLBI (128 MB) of one address space: only the cached targets in it go, found through the 32 MB chunks
       that hold any; the address space keeps its id (and so its other targets). */
    {
        hv_cpu_reset(&cpu, &m);
        cpu.tcr_el1 = 0;
        cpu.ttbr0_el1 = 7ull << 48;
        hv_ijc_switch(&cpu);
        uint64_t salt = cpu.ijc_salt[0];
        uint16_t cid = cpu.asid_cid[7];
        static const uint64_t vas[2] = {0x203004010ull, 0x210000020ull}; /* in the range (its 3rd chunk), past it */
        uint64_t *ents[2];
        static HvBlock fake[2];
        for (int i = 0; i < 2; i++) {
            fake[i] = (HvBlock){.va = vas[i], .flags = 0, .code_off = 0x1234};
            hv_ijc_fill(&cpu, &fake[i]);
            ents[i] = m.percpu[0].ijc + (size_t)hv_ijc_index(vas[i] ^ salt) * 2;
        }
        hv_ijc_drop_range(&cpu, 0x200000000ull, 128ull << 20, 7);
        checks += 3;
        if (ents[0][0] == (vas[0] ^ salt)) printf("  FAIL big range kept a target in it\n"), failures++;
        if (ents[1][0] != (vas[1] ^ salt)) printf("  FAIL big range dropped a target past it\n"), failures++;
        if (cpu.asid_cid[7] != cid) printf("  FAIL big range dropped the whole address space\n"), failures++;
    }

    /* A code change drops the cached branch targets into its page (HV_IJC_PAGES): noted under one VA page when they
       were cached, just that page's; noted under none, none (only the return predictions); under several, all. */
    {
        hv_cpu_reset(&cpu, &m);
        cpu.tcr_el1 = 0;
        cpu.ttbr0_el1 = 7ull << 48;
        hv_ijc_switch(&cpu);
        HvCpu *self = hv_self;
        hv_self = &cpu;
        int knob = hv_knob.ijc_pages;
        hv_knob.ijc_pages = 1;
        HvRam *r = &m.ram[0];
        const uint64_t P = 0x100004000ull, Q = 0x100008000ull, R = 0x10000c000ull;
        static HvBlock fb[3];
        struct { uint64_t note[2]; int kept[3]; const char *what; } cases[] = {
            {{P | 2, 0}, {0, 1, 1}, "noted at P"}, {{0, 0}, {1, 1, 1}, "noted nowhere"},
            {{P | 2, Q | 2}, {0, 0, 1}, "noted at P and Q"}, {{~0ull, 0}, {0, 0, 0}, "noted at more than fit"}};
        for (int c = 0; c < 4; c++) {
            uint64_t salt = cpu.ijc_salt[0];
            uint64_t *ents[3];
            for (int i = 0; i < 3; i++) {
                fb[i] = (HvBlock){.va = (i == 0 ? P : i == 1 ? Q : R) + 0x10 * (uint64_t)(i + 1), .flags = 0, .code_off = 0x1234};
                hv_ijc_fill(&cpu, &fb[i]);
                ents[i] = m.percpu[0].ijc + (size_t)hv_ijc_index(fb[i].va ^ salt) * 2;
            }
            r->code_pages[10] = 1;
            r->ijc_va[10 * HV_IJC_VAS] = cases[c].note[0];
            r->ijc_va[10 * HV_IJC_VAS + 1] = cases[c].note[1];
            hv_invalidate_code(&m, r->pa + (10ull << 14));
            for (int i = 0; i < 3; i++) {
                int kept = ents[i][0] == (fb[i].va ^ salt) && cpu.ijc_salt[0] == salt;
                checks++;
                if (kept != cases[c].kept[i]) {
                    printf("  FAIL code change %s: the target in %c %s\n", cases[c].what, "PQR"[i], kept ? "kept" : "dropped");
                    failures++;
                }
            }
            for (int j = 0; j < HV_IJC_VAS; j++) {
                checks++;
                if (r->ijc_va[10 * HV_IJC_VAS + j] != 0) printf("  FAIL code change left the page's note %d\n", j), failures++;
            }
        }
        /* Caching notes the VA pages: the first HV_IJC_VAS each in a slot, one more makes it "more than fit". */
        {
            r->code_pages[12] = 1;
            uint64_t pa = r->pa + (12ull << 14), host = (uint64_t)(uintptr_t)r->host + (12ull << 14);
            static HvBlock nb[HV_IJC_VAS + 1];
            for (int i = 0; i <= HV_IJC_VAS; i++) {
                uint64_t va = 0x100100000ull + ((uint64_t)i << 14);
                HvTlbEntry *e = hv_tlb_ent(&cpu, (uint32_t)(va >> 14) & (HV_TLB_SIZE - 1), 0);
                e->addend = (int64_t)(host - va);
                e->exec_tag = hv_exec_key(va, e->addend);
                nb[i] = (HvBlock){.va = va + 0x40, .pa = pa + 0x40, .gen = r->page_gen[12], .flags = 0, .code_off = 0x1234, .ram = 0};
                checks++;
                if (!hv_ijc_fill_checked(&cpu, &nb[i])) printf("  FAIL a block on a mapped page was not cached\n"), failures++;
                checks++;
                uint64_t want = i < HV_IJC_VAS ? (va | 2) : ~0ull, got = r->ijc_va[12 * HV_IJC_VAS + (i < HV_IJC_VAS ? i : 0)];
                if (got != want) printf("  FAIL note %d: %llx, want %llx\n", i, (unsigned long long)got, (unsigned long long)want), failures++;
            }
            hv_invalidate_code(&m, pa);
        }
        hv_knob.ijc_pages = knob;
        hv_self = self;
    }

    /* A code change unchains the exits from other pages chained into its page, and only those: each page's are a list
       (HvRam.xhead through slot_xnext), as chain() in dispatch.c makes it. */
    {
        HvRam *r = &m.ram[0];
        uint32_t base = m.nslots + 16, pages[4] = {10, 11, 10, 10}, n0 = m.nxchained;
        for (uint32_t i = 0; i < 4; i++) {
            uint32_t idx = base + i, pg = pages[i];
            *HV_SLOT(&m, idx) = 0x1000 + i;
            m.slot_site[idx] = 0;
            m.slot_xpa[idx] = hv_xpa(0, pg); /* r is m.ram[0] */
            m.slot_xnext[idx] = r->xhead[pg];
            r->xhead[pg] = idx + 1;
            m.nxchained++;
        }
        r->code_pages[10] = 1;
        hv_invalidate_code(&m, r->pa + (10ull << 14) + 0x40);
        for (uint32_t i = 0; i < 4; i++) {
            int gone = *HV_SLOT(&m, base + i) == 0 && m.slot_xpa[base + i] == 0;
            checks++;
            if (gone != (pages[i] == 10)) printf("  FAIL code change %s an exit chained into page %u\n", gone ? "unchained" : "kept", pages[i]), failures++;
        }
        checks += 3;
        if (r->xhead[10]) printf("  FAIL the changed page's list is not empty\n"), failures++;
        if (r->xhead[11] != base + 2) printf("  FAIL the other page's list changed\n"), failures++;
        if (m.nxchained != n0 + 1) printf("  FAIL chained count %u, want %u\n", m.nxchained, n0 + 1), failures++;
        r->code_pages[11] = 1;
        hv_invalidate_code(&m, r->pa + (11ull << 14));
        checks++;
        if (*HV_SLOT(&m, base + 1) || r->xhead[11] || m.nxchained != n0) printf("  FAIL the second page's exit stayed chained\n"), failures++;
    }

    /* Another CPU's big range TLBI (64 user pages of ASID 5: over the 32 done from here by default). With HV_RANGE_DROP it is done from here in one pass:
       the second CPU's TLB slots and stashed entries in the range go, the rest stay, nothing is queued for it.
       Without, it is queued for that CPU to do (as before) and only happens when it does. */
    {
        static HvCpu cpu2;
        hv_cpu_reset_index(&cpu2, &m, 1);
        cpu2.sctlr_el1 = cpu.sctlr_el1, cpu2.tcr_el1 = cpu.tcr_el1, cpu2.mair_el1 = cpu.mair_el1;
        cpu2.ttbr0_el1 = 5ull << 48 | (cpu.ttbr0_el1 & 0x0000fffffffffffeull); /* running ASID 5: its live entries are that one's */
        HvPerCpu *p2 = cpu2.pc_state;
        const uint64_t base = 0x100000000ull;
        const int32_t ks[6] = {0, 1, 32, 63, 64, 100};
        for (int knob = 1; knob >= 0; knob--) {
            hv_knob.range_drop = knob ? 1024 : 0;
            hv_tlb_flush(&cpu2);
            for (int k = 0; k < 6; k++) {
                uint64_t va = base + ((uint64_t)ks[k] << 14);
                HvTlbEntry *t = hv_tlb_ent(&cpu2, (va >> 14) & (HV_TLB_SIZE - 1), 0);
                t->read_tag = va - HV_TLB_ADJ;
                t->addend = 0;
            }
            /* a stashed (switched-out) address space of ASID 5: one page inside the range, one past it */
            HvTlbStash *st = &p2->stash[0];
            st->ttbr0 = 5ull << 48 | 0x4000;
            st->n = 2;
            memset(st->filter, 0xff, sizeof st->filter); /* any page may be in it */
            st->ent[0] = (HvTlbEntry){.read_tag = base + (40ull << 14) - HV_TLB_ADJ, .write_tag = HV_TLB_INVALID, .exec_tag = HV_TLB_INVALID};
            st->ent[1] = (HvTlbEntry){.read_tag = base + (200ull << 14) - HV_TLB_ADJ, .write_tag = HV_TLB_INVALID, .exec_tag = HV_TLB_INVALID};
            p2->nreq = 0, p2->req_flags = 0;
            cpu.el = 1;
            cpu.x[1] = 5ull << 48 | 2ull << 46 | 0ull << 44 | 31ull << 39 | ((base >> 14) & 0x1fffffffffull); /* (31+1) << 1 = 64 pages */
            hv_sysreg_sys(&cpu, 0xd5088221u, 0); /* tlbi rvae1is, x1 */
            int queued = p2->nreq != 0 || p2->req_flags != 0;
            checks++;
            if (queued == knob) {
                printf("  FAIL remote range, HV_RANGE_DROP %d: %s\n", knob ? 1024 : 0, queued ? "queued for the other CPU" : "not queued");
                failures++;
            }
            if (!knob) hv_cpu_process_requests(&cpu2); /* what it does when it next runs */
            for (int k = 0; k < 6; k++) {
                uint64_t va = base + ((uint64_t)ks[k] << 14);
                int dropped = hv_tlb_ent(&cpu2, (va >> 14) & (HV_TLB_SIZE - 1), 0)->read_tag == HV_TLB_INVALID;
                checks++;
                if (dropped != (ks[k] < 64)) {
                    printf("  FAIL remote range (knob %d), page %d: %s\n", knob, ks[k], dropped ? "dropped" : "kept");
                    failures++;
                }
            }
            if (knob) { /* the stash is the dropping CPU's job only on this path; the target's own TLBI handles it otherwise */
                checks += 2;
                if (st->ent[0].read_tag != HV_TLB_INVALID) printf("  FAIL remote range kept a stashed page in the range\n"), failures++;
                if (st->ent[1].read_tag == HV_TLB_INVALID) printf("  FAIL remote range dropped a stashed page past the range\n"), failures++;
            }
            st->ttbr0 = 0, st->n = 0;
        }
        hv_knob.range_drop = 0;
        /* A target in the middle of a page walk (of a page in the range): raced, so it is queued instead. */
        hv_tlb_flush(&cpu2);
        p2->walk_page[(p2->walk_seq >> 1) & 7] = base + (3ull << 14);
        __atomic_store_n(&p2->walk_seq, p2->walk_seq | 1, __ATOMIC_SEQ_CST);
        checks++;
        if (hv_tlbi_drop_remote_range(&cpu2, base, 64, 5) != 0) printf("  FAIL remote range ignored a page walk in progress\n"), failures++;
        __atomic_store_n(&p2->walk_seq, p2->walk_seq + 1, __ATOMIC_SEQ_CST);
    }

    /* HV_WALK_LOG: a drop races only a walk of one of its pages, or a process switch's (any page); a walk of another
       page is let through. Walks under way, set up as walk_begin does (the page logged, then walk_seq odd). */
    {
        static HvCpu cpu3;
        hv_cpu_reset_index(&cpu3, &m, 1);
        HvPerCpu *p3 = cpu3.pc_state;
        const uint64_t P = 0x100004000ull, Q = 0x100008000ull;
        struct { const char *what; uint64_t walked; int knob, range, want; } cases[] = {
            {"a walk of another page", Q, 1, 0, 1},       {"a walk of the page", P + 0x10, 1, 0, 0},
            {"a process switch", ~0ull, 1, 0, 0},         {"a walk of another page, knob off", Q, 0, 0, 0},
            {"a range with the walked page in it", Q, 1, 1, 0}, {"a range without it", Q + (8ull << 14), 1, 1, 1},
            {"a tagged walk of another page", 0x5a00000000000000ull | Q, 1, 0, 1},
            {"a tagged walk of the page", 0x5a00000000000000ull | P, 1, 0, 0},
        };
        for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
            hv_knob.walk_log = cases[c].knob;
            uint32_t seq = __atomic_load_n(&p3->walk_seq, __ATOMIC_SEQ_CST) & ~1u;
            uint64_t pg = cases[c].walked == ~0ull ? ~0ull : cases[c].walked & 0x00ffffffffffc000ull;
            p3->walk_page[(seq >> 1) & 7] = pg;
            __atomic_store_n(&p3->walk_seq, seq + 1, __ATOMIC_SEQ_CST);
            int r = cases[c].range ? hv_tlbi_drop_remote_range(&cpu3, P, 2, 5) : hv_tlbi_drop_remote_va(&cpu3, P, 5);
            __atomic_store_n(&p3->walk_seq, seq + 2, __ATOMIC_SEQ_CST);
            checks++;
            if ((r == 1) != cases[c].want) {
                printf("  FAIL remote drop during %s: %s\n", cases[c].what, r == 1 ? "done" : "raced");
                failures++;
            }
        }
        hv_knob.walk_log = 1;
    }

    switch_does_requests(&m);
    stash_test();
    keep_test();
    room_test();
    remap_test();

    printf("%d checks, %d failures\n", checks, failures);
    return failures != 0;
}
