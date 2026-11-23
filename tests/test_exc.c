#include "harness.h"

#include <mach/mach_time.h>
#include <stdlib.h>

#include "light.h"
#include "mmu.h"

DECLARE_PROGRAM(p_svc);
DECLARE_PROGRAM(p_brk_undef);
DECLARE_PROGRAM(p_dabt);
DECLARE_PROGRAM(p_el0);
DECLARE_PROGRAM(p_sysregs);
DECLARE_PROGRAM(p_sysregs2);
DECLARE_PROGRAM(p_irq);
DECLARE_PROGRAM(p_fptrap);
DECLARE_PROGRAM(p_psci);
DECLARE_PROGRAM(p_smc);
DECLARE_PROGRAM(p_smc_nomaint);
DECLARE_PROGRAM(p_el0_svc);
extern const char exc_programs_begin[], exc_programs_finish[];

#define ACK_PA 0x20000000ull

static HvMachine m;
static uint8_t *stack;
static int failures, checks;

static void ack_write(void *opaque, uint64_t off, uint64_t val, unsigned size) {
    (void)off, (void)val, (void)size;
    ((HvMachine *)opaque)->percpu[0].irq_line = 0;
}

static void check(const char *prog, const char *what, uint64_t got, uint64_t want) {
    checks++;
    if (got != want) {
        printf("  %s: %s = %llx, expected %llx\n", prog, what, (unsigned long long)got, (unsigned long long)want);
        failures++;
    }
}

static int run(const TestProgram *p, HvCpu *cpu, uint64_t x9) {
    static HvCpu init;
    memset(&init, 0, sizeof init);
    seed_cpu(&init, 5, (uint64_t)(uintptr_t)stack + 32768);
    init.x[9] = x9;
    init.x[19] = ACK_PA;
    int before = failures;
    if (run_jit(&m, p, &init, cpu, NULL)) failures++;
    return failures != before;
}

#define ADDR(sym) ((uint64_t)(uintptr_t)(sym))

/* Page tables for p_el0_svc (16 KB granule, 48-bit VAs in both halves): the programs where they are (TTBR0, read-only
   and executable at EL0 and EL1), the stack (TTBR0, read/write at both) and the programs again at KVA + their
   address (TTBR1, EL1 only), so its vectors are at a kernel address, as xnu's. */
#define KVA 0xffff000000000000ull
#define PT_BYTES (16u * 16384)
static uint8_t *pt;
static uint32_t pt_used;
static uint64_t root0, root1;

static uint64_t pt_alloc(void) {
    uint8_t *t = pt + pt_used;
    pt_used += 16384;
    memset(t, 0, 16384);
    return ADDR(t);
}

static void map_page(uint64_t root, uint64_t va, uint64_t pa, uint64_t ap) {
    uint64_t table = root, v = va & ((1ull << 48) - 1);
    for (int level = 0; level < 3; level++) {
        uint64_t *e = (uint64_t *)(uintptr_t)table + ((v >> (14 + 11 * (3 - level))) & 0x7ff);
        if (!(*e & 1)) *e = pt_alloc() | 3;
        table = *e & 0x0000ffffffffc000ull;
    }
    ((uint64_t *)(uintptr_t)table)[(v >> 14) & 0x7ff] = pa | 3 | 3u << 8 | 1u << 10 | ap << 6;
}

static uint64_t el0_sp;
static void mmu_on(HvCpu *cpu) {
    cpu->mair_el1 = 0xff;
    cpu->tcr_el1 = 16 | 2u << 14 | 16u << 16 | 1u << 30 | 5ull << 32; /* T0SZ, T1SZ 16; TG0, TG1 16K; 48-bit PAs */
    cpu->ttbr0_el1 = root0;
    cpu->ttbr1_el1 = root1;
    cpu->sctlr_el1 |= 1 | 1u << 2 | 1u << 12;
    cpu->x[9] = el0_sp;
    hv_tlb_flush(cpu);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    hv_machine_init(&m, 4 << 20);
    stack = aligned_alloc(16384, 65536);
    hv_machine_add_ram(&m, ADDR(exc_programs_begin), exc_programs_finish - exc_programs_begin,
                       (void *)exc_programs_begin, 1);
    hv_machine_add_ram(&m, ADDR(stack), 65536, stack, 0);
    hv_machine_add_mmio(&m, ACK_PA, 0x1000, &m, NULL, ack_write, "irq ack");
    m.trace = getenv("HV_TRACE") != NULL;
    static HvCpu c;

    static const TestProgram svc = TEST_PROGRAM(p_svc);
    if (!run(&svc, &c, 0)) {
        check("svc", "ESR", c.x[1], 0x56000042);
        check("svc", "ELR", c.x[2], c.x[6]);
        check("svc", "SPSR", c.x[3], 0x800003c5);
        check("svc", "NZCV after ERET", c.x[4], 0x80000000);
        check("svc", "vector", c.x[7], 0x200);
        check("svc", "count", c.x[24], 1);
    }

    static const TestProgram bu = TEST_PROGRAM(p_brk_undef);
    if (!run(&bu, &c, 0)) {
        check("brk", "ESR", c.x[1], 0xf2000007);
        check("brk", "ELR", c.x[2], c.x[3]);
        check("udf", "ESR", c.x[4], 0x02000000);
        check("udf", "ELR", c.x[5], c.x[6]);
    }

    static const TestProgram da = TEST_PROGRAM(p_dabt);
    if (!run(&da, &c, 0)) {
        check("dabt", "load ESR", c.x[1], 0x96000010);
        check("dabt", "load FAR", c.x[2], 0x10000);
        check("dabt", "ELR", c.x[3], c.x[4]);
        check("dabt", "store ESR (WnR)", c.x[5], 0x96000050);
        check("dabt", "store FAR", c.x[6], 0x10010);
        check("dabt", "no writeback on a fault", c.x[10], 0x10000);
    }

    static const TestProgram el0 = TEST_PROGRAM(p_el0);
    uint64_t sp0 = ADDR(stack) + 8192;
    uint64_t sp1 = ADDR(stack) + 32768;
    if (!run(&el0, &c, sp0)) {
        check("el0", "SP at EL0", c.x[10], sp0);
        check("el0", "SVC vector (lower EL)", c.x[13], 0x400);
        check("el0", "MRS SCTLR_EL1 at EL0: ESR", c.x[14], 0x02000000);
        check("el0", "MRS SCTLR_EL1 at EL0: vector", c.x[15], 0x400);
        check("el0", "TPIDR_EL0 write/read", c.x[18], 0x55);
        check("el0", "still at EL0", c.el, 0);
        check("el0", "SP_EL1 banked", c.sp_el1, sp1);
        check("el0", "exceptions", c.x[24], 2);
    }

    static const TestProgram sr = TEST_PROGRAM(p_sysregs);
    static HvCpu seeded;
    seed_cpu(&seeded, 5, 0);
    if (!run(&sr, &c, 0)) {
        check("sysregs", "TPIDR_EL1", c.x[2], seeded.x[1]);
        check("sysregs", "CurrentEL", c.x[3], 4);
        check("sysregs", "DAIF after set", c.x[4], 0x3c0);
        check("sysregs", "DAIF after clr", c.x[5], 0x300);
        check("sysregs", "NZCV", c.x[7], 0x60000000);
        check("sysregs", "CNTVCT advances", c.x[9] > c.x[8], 1);
        check("sysregs", "CNTFRQ", c.x[10], 24000000);
        check("sysregs", "16K granule advertised", (c.x[11] >> 20) & 0xf, 1);
        check("sysregs", "SP_EL0 via SPSel", c.x[12], 0);
        check("sysregs", "SP_EL1 via SPSel", c.x[13], sp1);
        check("sysregs", "MIDR implementer", c.x[14] >> 24, 0x61);
        check("sysregs", "FPCR", c.x[17], 1u << 24);
        check("sysregs", "VBAR", c.x[18], c.vbar_el1);
        check("sysregs", "CNTV_CVAL", c.x[21], 0x123);
        check("sysregs", "CNTV_CTL ISTATUS", c.x[23], 5);
    }
    static const TestProgram sr2 = TEST_PROGRAM(p_sysregs2);
    m.stats_interval = 1000000; /* count helper calls (never prints) */
    HvStats t0, t1;
    hv_stats_total(&m, &t0);
    if (!run(&sr2, &c, 0)) {
        hv_stats_total(&m, &t1);
        check("sysregs2", "SCTLR EnIA written inline", c.x[3], c.x[2]);
        check("sysregs2", "SCTLR fixups (ITD set, CP15BEN clear)", c.x[5], c.x[1]);
        check("sysregs2", "SCTLR WXN through the helper", c.x[6], c.x[1] | 1u << 19);
        check("sysregs2", "SCTLR back", c.x[7], c.x[1]);
        check("sysregs2", "CONTEXTIDR", c.x[10], 0x1234);
        check("sysregs2", "CONTEXTIDR from and to stolen registers", c.x[28], seeded.x[18]);
        check("sysregs2", "TTBR0 read", c.x[12], 0x4000);
        check("sysregs2", "DCZID", c.x[13], 4);
        check("sysregs2", "CNTKCTL", c.x[15], 2);
        check("sysregs2", "CNTKCTL's EL0 enables for translated counter reads", c.el0_cnt, 2);
        check("sysregs2", "MDSCR", c.x[16], 0x1234);
        check("sysregs2", "CNTV_CVAL read", c.x[27], 0x777);
        check("sysregs2", "MSRs through the helper (VBAR, SCTLR twice, TTBR0 twice, CNTV_CVAL)", t1.helper[HV_OP_MSR] - t0.helper[HV_OP_MSR], 6);
        check("sysregs2", "MRSs through the helper", t1.helper[HV_OP_MRS] - t0.helper[HV_OP_MRS], 0);
    }
    m.stats_interval = 0;

    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    check("host", "mach_absolute_time is 24 MHz (timebase 125/3)", (uint64_t)tb.numer * 1000 + tb.denom, 125003);

    static const TestProgram irq = TEST_PROGRAM(p_irq);
    m.percpu[0].irq_line = 1;
    if (!run(&irq, &c, 0)) {
        check("irq", "masked IRQ not taken across WFI", c.x[1], 0);
        check("irq", "taken after DAIFClr", c.x[2], 1);
        check("irq", "vector", c.x[3], 0x280);
        check("irq", "ELR = next instruction", c.x[4], c.x[5]);
        check("irq", "line acknowledged", m.percpu[0].irq_line, 0);
    }
    m.percpu[0].irq_line = 0;

    static const TestProgram fp = TEST_PROGRAM(p_fptrap);
    if (!run(&fp, &c, 0)) {
        check("fptrap", "ESR", c.x[1], 0x1fe00000);
        check("fptrap", "one trap", c.x[2], 1);
        double d1, d2, d0;
        memcpy(&d1, &seeded.v[1], 8);
        memcpy(&d2, &seeded.v[2], 8);
        d0 = d1 + d2;
        uint64_t want;
        memcpy(&want, &d0, 8);
        check("fptrap", "FADD retried", c.x[3], want);
    }

    static const TestProgram ps = TEST_PROGRAM(p_psci);
    if (!run(&ps, &c, 0)) {
        check("psci", "PSCI_VERSION", c.x[3], 0x10000);
        check("psci", "PSCI_FEATURES(CPU_ON)", c.x[2], 0);
    }

    /* Self-modifying code runs from a writable copy. */
    const TestProgram *smc_progs[2];
    static const TestProgram smc1 = TEST_PROGRAM(p_smc), smc2 = TEST_PROGRAM(p_smc_nomaint);
    smc_progs[0] = &smc1;
    smc_progs[1] = &smc2;
    uint8_t *code = aligned_alloc(16384, 16384);
    hv_machine_add_ram(&m, ADDR(code), 16384, code, 0);
    for (int i = 0; i < 2; i++) {
        const TestProgram *p = smc_progs[i];
        size_t len = (const char *)p->end - (const char *)p->start + 4;
        memcpy(code, p->start, len);
        TestProgram copy = {p->name, NULL, code, code + ((const char *)p->end - (const char *)p->start)};
        if (!run(&copy, &c, 0)) check(p->name, "1 then 2 after patching", c.x[1], 3);
    }

    /* EL0 SVCs into a kernel at a kernel address and ERETs back (A1): both take the light path, straight to the next
       block (no full helper, no dispatcher), and the guest sees what the full path gave it: ESR, ELR, SPSR, its NZCV and
       registers back, SIMD registers untouched (the light path never saves them). */
    pt = aligned_alloc(16384, PT_BYTES);
    hv_machine_add_ram(&m, ADDR(pt), PT_BYTES, pt, 0);
    root0 = pt_alloc();
    root1 = pt_alloc();
    for (uint64_t pa = ADDR(exc_programs_begin); pa < ADDR(exc_programs_finish); pa += 16384) {
        map_page(root0, pa, pa, 3); /* read-only at EL0 and EL1 */
        map_page(root1, KVA | pa, pa, 0);
    }
    for (uint64_t pa = ADDR(stack); pa < ADDR(stack) + 65536; pa += 16384) map_page(root0, pa, pa, 1);
    el0_sp = ADDR(stack) + 8192;
    const uint64_t svcs = 2000;
    static const TestProgram es = TEST_PROGRAM(p_el0_svc);
    static HvCpu esi;
    seed_cpu(&esi, 7, ADDR(stack) + 32768);
    esi.x[7] = svcs;
    esi.x[19] = ACK_PA;
    m.stats_interval = 1000000;
    HvStats e0, e1;
    hv_stats_total(&m, &e0);
    uint32_t rings0 = m.percpu[0].own.stats.nelchg;
    if (run_jit(&m, &es, &esi, &c, mmu_on)) failures++;
    else {
        hv_stats_total(&m, &e1);
        check("el0 svc", "SVCs taken", c.x[24], svcs);
        check("el0 svc", "times NZCV or x13 came back changed", c.x[14], 0);
        check("el0 svc", "ESR", c.x[20], 0x56000077);
        check("el0 svc", "ELR", c.x[22], c.x[17]);
        check("el0 svc", "SPSR: the last SVC's NZCV, EL0t", c.x[23], 1u << 28);
        check("el0 svc", "vector (lower EL)", c.x[25], 0x400);
        check("el0 svc", "still at EL0", c.el, 0);
        check("el0 svc", "SP at EL0", c.x[10], el0_sp);
        check("el0 svc", "SP_EL1 banked", c.sp_el1, esi.sp);
        static const int kept[] = {1, 2, 3, 4, 5, 6, 15, 18, 19, 27, 28, 29, 30};
        uint64_t changed = 0;
        for (size_t i = 0; i < sizeof kept / sizeof kept[0]; i++) changed += c.x[kept[i]] != esi.x[kept[i]];
        for (int i = 0; i < 32; i++) changed += c.v[i] != esi.v[i];
        check("el0 svc", "registers the programs leave alone, q0-q31 too, changed", changed, 0);
        check("el0 svc", "exceptions counted", e1.exceptions - e0.exceptions, svcs);
        check("el0 svc", "exception entries and returns in the CPU's ring", (uint32_t)(m.percpu[0].own.stats.nelchg - rings0), 2 * svcs + 1);
        uint64_t fast = e1.fast_resumes - e0.fast_resumes, entries = e1.blocks - e0.blocks;
        printf("el0 svc: %llu SVCs, %llu went straight to their block, %llu dispatcher entries (host clock %u, light flags %x)\n",
               (unsigned long long)svcs, (unsigned long long)fast, (unsigned long long)entries, hv_light_clock, hv_light_flags);
        /* The first SVC and ERET find their block not made yet: they leave, and the dispatcher makes and caches it. */
        check("el0 svc", "SVCs and ERETs straight to their block", fast >= 2 * svcs - 4, 1);
        check("el0 svc", "none of them through the full helper",
              e1.helper[HV_OP_EXCEPTION] - e0.helper[HV_OP_EXCEPTION] + e1.helper[HV_OP_ERET] - e0.helper[HV_OP_ERET], 0);
        check("el0 svc", "nor through the dispatcher", entries < 32, 1);
    }
    m.stats_interval = 0;

    printf("%d checks, %d failures\n", checks, failures);
    return failures != 0;
}
