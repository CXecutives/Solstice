// The engine's host memory (core/machine.c): its tables cost what is used, and a paused machine gives them back.
// Machines of 1 to 4 CPUs run the code-cache stress program (codecache_programs.S) on their own threads, each run's x0
// checked against the native run's; then, on each machine:
//  - block records and exit slots round-trip through their compact layout: every block in the hash is found again,
//    its code is in the JIT region, its page in its RAM; every placed exit's words are in the region, and a chained
//    exit's target page decodes to a list that holds it;
//  - only the CPUs reset have tables; the pages of the others are never touched;
//  - hv_machine_trim leaves nothing of the records, slots, hash and branch caches resident, keeps the JIT region's
//    pages, and the CPUs run the program again to the native result.
// And on one CPU: a branch cache emptied for a new round of user ids (fresh_cid running out) gives back the pages of
// the user tables a fill used, never touches the six a user's flags cannot reach, and keeps the kernel's.
#include "harness.h"

#include <pthread.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#include "mmu.h"

DECLARE_PROGRAM(ccstress);
extern const char codecache_programs_begin[], codecache_programs_finish[];

static const TestProgram prog = TEST_PROGRAM(ccstress);
static HvMachine m;
static int failures, checks;

static void check(const char *what, int ok) {
    checks++;
    if (!ok) printf("  FAIL %s\n", what), failures++;
}

/* Resident pages of the whole pages inside [p, p + bytes) (mincore). */
static size_t resident(const void *p, size_t bytes) {
    size_t ps = (size_t)getpagesize();
    uintptr_t a = ((uintptr_t)p + ps - 1) & ~(uintptr_t)(ps - 1), e = ((uintptr_t)p + bytes) & ~(uintptr_t)(ps - 1);
    if (e <= a) return 0;
    size_t n = (e - a) / ps, count = 0;
    char *vec = malloc(n);
    if (!vec || mincore((void *)a, e - a, vec) != 0) {
        free(vec);
        return (size_t)-1;
    }
    for (size_t i = 0; i < n; i++) count += vec[i] & 1;
    free(vec);
    return count;
}

typedef struct {
    HvCpu *cpu;
    uint64_t seed, want, sp;
    int bad;
    pthread_t th;
} Worker;

static void *worker(void *arg) {
    Worker *w = arg;
    HvCpu *cpu = w->cpu;
    cpu->x[0] = w->seed;
    cpu->x[20] = 1; /* TLBIs too */
    cpu->x[21] = 1; /* one round */
    cpu->sp = w->sp;
    cpu->pc = (uint64_t)(uintptr_t)prog.start;
    int r = hv_run(cpu);
    if (r != HV_EXIT_HALT || cpu->x[0] != w->want) {
        printf("  cpu %u: dispatcher returned %d at pc %llx, x0 %016llx, native %016llx\n", cpu->index, r,
               (unsigned long long)cpu->pc, (unsigned long long)cpu->x[0], (unsigned long long)w->want);
        w->bad = 1;
    }
    return NULL;
}

/* Every worker's CPU runs the program once, all at once. 0 if every run matched the native one. */
static int run_all(Worker *w, int n) {
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 16u << 20);
    for (int i = 0; i < n; i++) pthread_create(&w[i].th, &attr, worker, &w[i]);
    int bad = 0;
    for (int i = 0; i < n; i++) {
        pthread_join(w[i].th, NULL);
        bad += w[i].bad;
    }
    pthread_attr_destroy(&attr);
    return bad;
}

/* The records and slots as the machine left them (no CPU running). */
static void check_layout(const char *name, int one_cpu) {
    char what[160];
    uint32_t seen = 0, bad_block = 0, bad_at = 0;
    for (uint32_t h = 0; h <= m.hash_mask; h++)
        for (uint32_t i = m.hash[h]; i && seen <= m.max_blocks; i = m.blocks[i].next) {
            const HvBlock *b = &m.blocks[i];
            HvRam *r = hv_block_ram(&m, b);
            seen++;
            if (i > m.max_blocks || hv_block_hash(&m, b->va, b->pa, b->flags) != h || b->code_off >= m.jit.used ||
                b->ram >= m.nram || b->pa - r->pa >= r->size || hv_block_pg(&m, b) >= r->npages ||
                !hv_block_find(&m, h, b->va, b->pa, b->flags, b->gen) || !b->ninsns || b->maker < 1 || b->maker > m.ncpus)
                bad_block++;
            const HvBlock *at = hv_block_at(&m, hv_block_code(&m, b)); /* records in code order: one CPU */
            if (one_cpu && (!at || at->code_off != b->code_off)) bad_at++;
        }
    snprintf(what, sizeof what, "%s: %u blocks in the hash, %d records (no eviction), %u of them wrong, %u not found by code",
             name, seen, m.nblocks, bad_block, bad_at);
    check(what, seen && bad_block == 0 && bad_at == 0 && (m.cc.evictions || seen == (uint32_t)m.nblocks));
    uint32_t placed = 0, bad_slot = 0, xlisted = 0;
    for (uint32_t idx = 0; idx < m.nslots && idx < m.max_slots; idx++) {
        const uint32_t *site = hv_jit_word(&m, m.slot_site[idx]), *stub = hv_jit_word(&m, m.slot_stub[idx]);
        if (!site) continue;
        placed++;
        uint64_t to = *HV_SLOT(&m, idx);
        const uint32_t *cond = hv_jit_word(&m, m.slot_cond[idx]), *end = m.jit.base + m.jit.used;
        if (site >= end || !stub || stub >= end || (cond && cond >= end) ||
            (to && ((const uint32_t *)(uintptr_t)to < m.jit.base || (const uint32_t *)(uintptr_t)to >= end)))
            bad_slot++;
        uint32_t x = m.slot_xpa[idx];
        if (!x) continue;
        uint32_t ri = hv_xpa_ram(x);
        uint64_t pg = hv_xpa_pg(x);
        int on = 0;
        if (ri < (uint32_t)m.nram && pg < m.ram[ri].npages)
            for (uint32_t k = m.ram[ri].xhead[pg], steps = 0; k && steps < m.max_slots; k = m.slot_xnext[k - 1], steps++)
                if (k == idx + 1) on = 1;
        if (!on || !m.slot_xa[idx]) bad_slot++;
        xlisted++;
    }
    snprintf(what, sizeof what, "%s: %u exits placed (%u chained to another page, %u listed), %u wrong", name, placed,
             xlisted, m.nxchained, bad_slot);
    check(what, placed && bad_slot == 0 && xlisted == m.nxchained);
}

/* The machine's tables back: resident pages of each (a partial last page may stay, zeroed). */
static void check_trimmed(const char *name, int n) {
    char what[200];
    size_t rb = resident(m.blocks, m.blocks_bytes), rh = resident(m.hash, m.hash_bytes), rs = resident(m.slots, m.slots_bytes);
    size_t rc = 0, rj = 0;
    for (int i = 0; i < n; i++) {
        rc += resident(m.percpu[i].tables, m.percpu[i].tables_bytes);
        rj += resident(m.percpu[i].jc, sizeof m.percpu[i].jc);
    }
    snprintf(what, sizeof what, "%s: after the trim, resident pages: records %zu, hash %zu, slots %zu, CPU tables %zu, "
             "front caches %zu (want 0)", name, rb, rh, rs, rc, rj);
    check(what, rb == 0 && rh == 0 && rs == 0 && rc == 0 && rj == 0 && m.nblocks == 0 && m.nslots == 0);
}

static void one_machine(int n) {
    char name[32], what[160];
    snprintf(name, sizeof name, "%d cpu%s", n, n > 1 ? "s" : "");
    if (hv_machine_init(&m, 32 << 20) != 0) {
        check("machine init", 0);
        return;
    }
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)codecache_programs_begin, codecache_programs_finish - codecache_programs_begin,
                       (void *)codecache_programs_begin, 1);
    uint8_t *stack = aligned_alloc(16384, 65536);
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)stack, 65536, stack, 0);
    m.stop_pc = (uint64_t)(uintptr_t)prog.end;
    Worker w[4];
    memset(w, 0, sizeof w);
    for (int i = 0; i < n; i++) {
        w[i].seed = 0x9e3779b97f4a7c15ull * (uint64_t)(i + 1) + (uint64_t)n;
        w[i].sp = (uint64_t)(uintptr_t)stack + 16384 * (uint64_t)(i + 1);
        static HvCpu init, native;
        memset(&init, 0, sizeof init);
        seed_cpu(&init, (uint64_t)i + 1, w[i].sp);
        init.x[0] = w[i].seed;
        init.x[20] = 0; /* natively: no TLBIs */
        init.x[21] = 1;
        run_native(&prog, &init, &native, NULL);
        w[i].want = native.x[0];
        HvCpu *cpu = aligned_alloc(16384, (sizeof(HvCpu) + 16383) & ~(size_t)16383);
        memset(cpu, 0, sizeof *cpu);
        hv_cpu_reset_index(cpu, &m, (uint32_t)i);
        memcpy(cpu->x, init.x, sizeof cpu->x);
        cpu->cpacr_el1 = 3u << 20;
        w[i].cpu = cpu;
    }
    snprintf(what, sizeof what, "%s: every run as the native one", name);
    check(what, run_all(w, n) == 0);
    int tables = 0, untouched = 1;
    for (int i = 0; i < HV_MAX_CPUS; i++) {
        tables += m.percpu[i].tables != NULL;
        if (i >= n && (m.percpu[i].tables || resident(m.percpu[i].jc, sizeof m.percpu[i].jc) != 0)) untouched = 0;
    }
    snprintf(what, sizeof what, "%s: %d CPUs with tables, the others' pages untouched", name, tables);
    check(what, m.ncpus == n && tables == n && untouched);
    check_layout(name, n == 1);
    size_t used = m.jit.used * sizeof(uint32_t), jit_before = resident(m.jit.base, used);
    check("the trim with every CPU parked", hv_machine_trim(&m) == 0);
    check_trimmed(name, n);
    size_t jit_after = resident(m.jit.base, used); /* the trim must not map over them (they could not be prepared again) */
    snprintf(what, sizeof what, "%s: the JIT region's pages stay (%zu resident before the trim, %zu after)", name, jit_before, jit_after);
    check(what, jit_before > 0 && jit_after != (size_t)-1 && jit_after * 2 >= jit_before);
    for (int i = 0; i < n; i++) w[i].bad = 0;
    snprintf(what, sizeof what, "%s: after the trim, every run as the native one again", name);
    check(what, run_all(w, n) == 0);
    check_layout(name, n == 1);
    for (int i = 0; i < n; i++) free(w[i].cpu);
    hv_machine_free(&m);
    free(stack);
}

/* fresh_cid running out of user ids empties the user half of the branch cache (ijc_clear). */
static void ijc_clear_used_only(void) {
    if (hv_machine_init(&m, 4 << 20) != 0) {
        check("machine init", 0);
        return;
    }
    static HvCpu cpu;
    hv_cpu_reset(&cpu, &m);
    HvPerCpu *p = &m.percpu[0];
    cpu.tcr_el1 = 1ull << 22; /* TCR.A1: no ASIDs, so every switch takes a new user id */
    hv_ijc_switch(&cpu);
    static HvBlock user[64], kernel;
    for (int i = 0; i < 64; i++) { /* a user page's targets spread over the table (flags 0: table 0) */
        user[i] = (HvBlock){.va = 0x100000000ull + (uint64_t)i * 0x40004, .flags = 0, .code_off = 0x40};
        hv_ijc_fill(&cpu, &user[i]);
    }
    kernel = (HvBlock){.va = 0xfffffe0000004000ull, .flags = HV_BLOCK_EL1 | HV_BLOCK_SPX, .code_off = 0x80};
    hv_ijc_fill(&cpu, &kernel);
    const size_t words = HV_IJC_TABLE_BYTES / 8;
    uint64_t ktag = kernel.va ^ cpu.ijc_salt[1];
    uint64_t *kent = p->ijc + (size_t)(kernel.flags & (HV_IJC_TABLES - 1)) * words + (size_t)hv_ijc_index(ktag) * 2;
    check("ijc: the fills note the tables they used", p->ijc_tables_used == (1u << 0 | 1u << (HV_BLOCK_EL1 | HV_BLOCK_SPX)));
    check("ijc: the user table's pages are in use", resident(p->ijc, HV_IJC_TABLE_BYTES) > 0);
    cpu.next_cid = 0x10000; /* the next switch runs out of ids */
    hv_ijc_switch(&cpu);
    size_t user_pages = 0, unused_pages = 0;
    for (int t = 0; t < HV_IJC_TABLES; t += 2) {
        size_t r = resident(p->ijc + (size_t)t * words, HV_IJC_TABLE_BYTES);
        user_pages += r;
        if (t) unused_pages += r;
    }
    char what[160];
    snprintf(what, sizeof what, "ijc: user half emptied: %zu pages of its tables resident, %zu of the ones never filled (want 0)",
             user_pages, unused_pages);
    check(what, user_pages == 0 && unused_pages == 0);
    check("ijc: the kernel's table and its entry kept", kent[0] == ktag &&
          (p->ijc_tables_used & (1u << (HV_BLOCK_EL1 | HV_BLOCK_SPX))) && !(p->ijc_tables_used & 0x5555u));
    hv_machine_free(&m);
}

/* Page tables for the program at EL0 (16 KB granule, 48-bit VA: levels 0-3), identity mapped. */
#define ADDR(sym) ((uint64_t)(uintptr_t)(sym))
#define PT_TABLES 16
#define PT_BITS (3ull | 1ull << 10 | 3ull << 8) /* page, accessed, inner shareable, attribute 0; no UXN: EL0 runs it */
static uint8_t *pt;
static unsigned pt_next;

static uint64_t pt_table(void) {
    uint8_t *t = pt + (size_t)(pt_next < PT_TABLES - 1 ? pt_next++ : pt_next) * 16384;
    memset(t, 0, 16384);
    return ADDR(t);
}

static uint64_t *pt_entry(uint64_t root, uint64_t va) {
    uint64_t table = root;
    for (int level = 0; level < 3; level++) {
        int shift = 14 + 11 * (3 - level);
        uint64_t *e = (uint64_t *)(uintptr_t)table + ((va >> shift) & (level == 0 ? 1 : 0x7ff));
        if (!(*e & 1)) *e = pt_table() | 3;
        table = *e & 0x0000ffffffffc000ull;
    }
    return (uint64_t *)(uintptr_t)table + ((va >> 14) & 0x7ff);
}

/* The branch cache's filters full and the user ids about to run out while translated code misses in it: the light
   path (hv_ijc_resolve from hv_ijc_thunk, the guest's q0-q31 live in the host's) must not start the cache over
   (that clears with libc, which uses those registers); it leaves that to the dispatcher. The program at EL0 with
   the MMU on, so its indirect branches go that way; every register must come out as the native run's. */
static void light_path_leaves_resets(void) {
    if (hv_machine_init(&m, 32 << 20) != 0) {
        check("machine init", 0);
        return;
    }
    m.stats_interval = 3600; /* counted as on a device, never printed here */
    pt = aligned_alloc(16384, PT_TABLES * 16384);
    pt_next = 0;
    uint64_t lo = ADDR(codecache_programs_begin), hi = ADDR(codecache_programs_finish);
    hv_machine_add_ram(&m, lo, hi - lo, (void *)codecache_programs_begin, 1);
    hv_machine_add_ram(&m, ADDR(pt), PT_TABLES * 16384, pt, 0);
    uint64_t root = pt_table();
    for (uint64_t va = lo & ~0x3fffull; va < hi; va += 16384) *pt_entry(root, va) = va | PT_BITS;
    static HvCpu init, native, cpu;
    static uint8_t stack[65536] __attribute__((aligned(16384))); /* the native run's epilogue pushes on it */
    memset(&init, 0, sizeof init);
    seed_cpu(&init, 77, ADDR(stack + sizeof stack)); /* q0-q31 hold the seed's values throughout: the program never touches them */
    init.x[20] = 0;          /* no TLBIs (EL0) */
    init.x[21] = 1;
    run_native(&prog, &init, &native, NULL);
    hv_cpu_reset(&cpu, &m);
    cpu.cpacr_el1 = 3u << 20;
    cpu.ttbr0_el1 = root | 1ull << 48;
    cpu.tcr_el1 = 16 | 2u << 14 | 1u << 23 | 5ull << 32; /* T0SZ 16, TG0 16 KB, EPD1, 48-bit PA */
    cpu.mair_el1 = 0xff;
    cpu.sctlr_el1 |= 1;
    hv_ijc_switch(&cpu); /* ASID 1's id */
    cpu.el = 0;
    m.stop_pc = ADDR(prog.end);
    HvPerCpu *p = cpu.pc_state;
    const HvStats *st = &p->own.stats;
    const uint32_t keyed0 = (1u << 17) - 1, ucode0 = (1u << HV_UCODE_BITS) / 2 - 2; /* one fill from full, both */
    uint64_t light0 = 0, restarts0 = 0;
    char what[200];
    for (int run = 0; run < 2; run++) {
        if (run) { /* the blocks are made: the user half emptied, so every indirect branch misses into the light path */
            hv_ijc_reset(&cpu, 0);
            memset(p->ijc_keyed, 0, sizeof p->ijc_keyed); /* so the next fill sets a new bit */
            p->ijc_keyed_count = keyed0; /* and its filters a fill from full */
            p->ucode_count = ucode0;
            cpu.next_cid = 0xffff; /* the second user-half restart runs out of ids (fresh_cid) */
            light0 = st->ijc_light, restarts0 = st->reset_why[6];
        }
        memcpy(cpu.x, init.x, sizeof cpu.x);
        memcpy(cpu.v, init.v, sizeof cpu.v);
        cpu.sp = init.sp, cpu.nzcv = init.nzcv, cpu.fpcr = init.fpcr, cpu.fpsr = init.fpsr;
        cpu.pc = ADDR(prog.start);
        int r = hv_run(&cpu);
        snprintf(what, sizeof what, "light path: run %d at EL0 ends at the program's end (%d at pc %llx)", run, r, (unsigned long long)cpu.pc);
        check(what, r == HV_EXIT_HALT);
        snprintf(what, sizeof what, "light path: run %d: every register as the native run's, q0-q31 too", run);
        check(what, compare_cpus("ccstress at EL0", &native, &cpu) == 0);
    }
    snprintf(what, sizeof what, "light path: %llu fills by it, %llu filter-full restarts (the dispatcher's), counts now keyed %u ucode %u, next id %u",
             (unsigned long long)(st->ijc_light - light0), (unsigned long long)(st->reset_why[6] - restarts0), p->ijc_keyed_count,
             p->ucode_count, cpu.next_cid);
    check(what, st->ijc_light > light0 && st->reset_why[6] > restarts0 && p->ijc_keyed_count < keyed0 && p->ucode_count < ucode0 &&
                    cpu.next_cid < 0xffff);
    hv_machine_free(&m);
    free(pt);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    check("a block record is 40 bytes", sizeof(HvBlock) == 40);
    check("hv_xpa round trip", hv_xpa_ram(hv_xpa(7, (1u << 28) - 1)) == 7 && hv_xpa_pg(hv_xpa(7, (1u << 28) - 1)) == (1u << 28) - 1 &&
          hv_xpa_ram(hv_xpa(0, 5)) == 0 && hv_xpa_pg(hv_xpa(0, 5)) == 5 && hv_xpa(0, 0) != 0);
    ijc_clear_used_only();
    light_path_leaves_resets();
    for (int n = 1; n <= 4; n++) one_machine(n);
    printf("%d checks, %d failures\n%s\n", checks, failures, failures ? "FAIL" : "ok");
    return failures != 0;
}
