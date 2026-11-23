/* Differential fuzzer: random sequences of loads and stores, with the branches, calls and
   flag uses around them, written at run time, run natively and through the JIT. Every
   register must come out the same (q0-q31 start as distinct sentinels, so a slow path,
   TLB refill or branch-cache thunk that touches them shows) and so must every byte of
   the memory they touch. Addresses sit mostly at 16 KB page ends (accesses that straddle
   pages, and a page's last 15 bytes), on bases in host registers and on the stolen ones
   (x6, x7, x15, x18, x28, SP); a second data area 256 MB from the first shares its TLB
   slots, so refills keep happening. Each sequence runs under one of several ways of
   translating (groups, MMU on at EL0 and EL1, the C path, a tiny JIT region, ...).
   FUZZ_SEQS=n sequences (default 20000), FUZZ_SECONDS=s at most (default 50),
   FUZZ_SEED=s, FUZZ_ONLY=k: only configuration k. */
#include "harness.h"

#include <mach/mach_time.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#include "jit_region.h"
#include "mmu.h"
#include "translate.h"

extern const uint32_t fuzz_ref[], fuzz_ref_end[];
extern uint64_t hv_native_cpu[2];
extern char hv_native_return[];

#define NEAR_SIZE 65536
#define FAR_SIZE 32768
#define FAR_OFF (1ull << 28) /* the same TLB slots as the near area's first pages */
#define STACK_SIZE 65536
#define SP0_OFF 32768        /* the guest SP starts at a page boundary */
#define CODE_SIZE 65536
#define CODE_WORDS (CODE_SIZE / 4)
#define PAGE_WORDS 4096
#define LIT_AT (3 * PAGE_WORDS + 1100)
#define LIT_WORDS 256
#define SUB_AT (3 * PAGE_WORDS + 2048)
#define EPI_AT (3 * PAGE_WORDS + 3072)
#define ALIAS_PA 0x40000000ull /* the near area again, as the MMU-on modes map it */
#define PT_PA 0x80000000ull
#define PT_SIZE (1024 * 1024)
#define MEM_TOTAL (NEAR_SIZE + FAR_SIZE + STACK_SIZE)

enum { NEAR, FAR };

static uint8_t *near_mem, *far_mem, *stack_mem, *pt;
static HvJitRegion code_region;
static uint32_t *code;               /* where the program runs (and the guest's code: PA = VA = host address) */
static uint32_t cbuf[CODE_WORDS];    /* built here, then copied there */
static uint8_t pattern[MEM_TOTAL];   /* this sequence's starting memory */

/* ---- encoders (checked against the assembler in check_encoders) ---- */

#define R5(x) ((uint32_t)(x) & 31u)
static uint32_t ldst_uimm(int size, int v, int opc, uint32_t imm12, int n, int t) {
    return (uint32_t)size << 30 | 0x39000000u | (uint32_t)v << 26 | (uint32_t)opc << 22 | (imm12 & 0xfff) << 10 | R5(n) << 5 | R5(t);
}
static uint32_t ldst_imm9(int size, int v, int opc, int imm9, int mode, int n, int t) { /* mode: 0 unscaled, 1 post, 3 pre */
    return (uint32_t)size << 30 | 0x38000000u | (uint32_t)v << 26 | (uint32_t)opc << 22 | ((uint32_t)imm9 & 0x1ff) << 12 |
           (uint32_t)mode << 10 | R5(n) << 5 | R5(t);
}
static uint32_t ldst_reg(int size, int v, int opc, int m, int option, int s, int n, int t) {
    return (uint32_t)size << 30 | 0x38200800u | (uint32_t)v << 26 | (uint32_t)opc << 22 | R5(m) << 16 | (uint32_t)option << 13 |
           (uint32_t)s << 12 | R5(n) << 5 | R5(t);
}
static uint32_t ldstp(int opc, int v, int mode, int l, int imm7, int t2, int n, int t) { /* mode: 1 post, 2 offset, 3 pre */
    return (uint32_t)opc << 30 | 0x28000000u | (uint32_t)v << 26 | (uint32_t)mode << 23 | (uint32_t)l << 22 |
           ((uint32_t)imm7 & 0x7f) << 15 | R5(t2) << 10 | R5(n) << 5 | R5(t);
}
static uint32_t vmulti(int q, int l, int post, int m, int opcode, int size, int n, int t) {
    return (uint32_t)q << 30 | 0x0c000000u | (post ? 0x00800000u | R5(m) << 16 : 0) | (uint32_t)l << 22 | (uint32_t)opcode << 12 |
           (uint32_t)size << 10 | R5(n) << 5 | R5(t);
}
static uint32_t ld1r(int q, int size, int n, int t) { return 0x0d40c000u | (uint32_t)q << 30 | (uint32_t)size << 10 | R5(n) << 5 | R5(t); }
static uint32_t lane_s(int l, int lane, int n, int t) { /* LD1/ST1 {Vt.S}[lane] */
    return 0x0d008000u | (uint32_t)(lane >> 1) << 30 | (uint32_t)l << 22 | (uint32_t)(lane & 1) << 12 | R5(n) << 5 | R5(t);
}
static uint32_t excl(int size, int o2, int l, int o1, int s, int o0, int t2, int n, int t) {
    return (uint32_t)size << 30 | 0x08000000u | (uint32_t)o2 << 23 | (uint32_t)l << 22 | (uint32_t)o1 << 21 | R5(s) << 16 |
           (uint32_t)o0 << 15 | R5(t2) << 10 | R5(n) << 5 | R5(t);
}
static uint32_t ldapr(int size, int n, int t) { return (uint32_t)size << 30 | 0x38bfc000u | R5(n) << 5 | R5(t); }
static uint32_t atomic(int size, int a, int r, int s, int o3, int opc, int n, int t) {
    return (uint32_t)size << 30 | 0x38200000u | (uint32_t)a << 23 | (uint32_t)r << 22 | R5(s) << 16 | (uint32_t)o3 << 15 |
           (uint32_t)opc << 12 | R5(n) << 5 | R5(t);
}
static uint32_t literal(int opc, int v, int words, int t) {
    return (uint32_t)opc << 30 | 0x18000000u | (uint32_t)v << 26 | ((uint32_t)words & 0x7ffff) << 5 | R5(t);
}
static uint32_t addsub_imm(int sub, int setflags, int sh, uint32_t imm12, int n, int d) { /* 64-bit */
    return 0x91000000u | (uint32_t)sub << 30 | (uint32_t)setflags << 29 | (uint32_t)sh << 22 | (imm12 & 0xfff) << 10 | R5(n) << 5 | R5(d);
}
static uint32_t alu_reg(uint32_t base, int m, int n, int d) { return base | R5(m) << 16 | R5(n) << 5 | R5(d); }
#define ADD_R 0x8b000000u
#define ADDS_R 0xab000000u
#define SUBS_R 0xeb000000u
#define EOR_R 0xca000000u
static uint32_t cset(int cond, int d) { return 0x9a9f07e0u | (uint32_t)(cond ^ 1) << 12 | R5(d); }
static uint32_t movw(uint32_t base, int hw, uint32_t imm16, int d) { return base | (uint32_t)hw << 21 | (imm16 & 0xffff) << 5 | R5(d); }
#define MOVZ 0xd2800000u
#define MOVK 0xf2800000u
#define MOVN 0x92800000u
static uint32_t bcond(int cond, int words) { return 0x54000000u | ((uint32_t)words & 0x7ffff) << 5 | (uint32_t)cond; }
static uint32_t cbz(int sf, int nz, int words, int t) { return 0x34000000u | (uint32_t)sf << 31 | (uint32_t)nz << 24 | ((uint32_t)words & 0x7ffff) << 5 | R5(t); }
static uint32_t tbz(int nz, int bit, int words, int t) {
    return 0x36000000u | (uint32_t)(bit >> 5) << 31 | (uint32_t)nz << 24 | (uint32_t)(bit & 31) << 19 | ((uint32_t)words & 0x3fff) << 5 | R5(t);
}
static uint32_t b_imm(int link, int words) { return (link ? 0x94000000u : 0x14000000u) | ((uint32_t)words & 0x3ffffff); }
static uint32_t adr(int bytes, int d) { return 0x10000000u | ((uint32_t)bytes & 3) << 29 | (((uint32_t)bytes >> 2) & 0x7ffff) << 5 | R5(d); }
#define BR(n) (0xd61f0000u | R5(n) << 5)
#define BLR(n) (0xd63f0000u | R5(n) << 5)
#define RET(n) (0xd65f0000u | R5(n) << 5)
#define MSR_FPCR 0xd51b4400u
#define MSR_FPSR 0xd51b4420u
#define MSR_NZCV 0xd51b4200u
#define MRS_NZCV 0xd53b4200u
#define MRS_FPCR 0xd53b4400u
#define MRS_FPSR 0xd53b4420u
#define DC_ZVA 0xd50b7420u
#define CLREX 0xd5033f5fu

static int check_encoders(void) {
    const uint32_t mine[] = {
        ldst_uimm(3, 0, 1, 2, 2, 1), ldst_uimm(0, 0, 0, 5, 4, 3), ldst_uimm(1, 0, 2, 1, 6, 5), ldst_uimm(2, 0, 2, 1, 8, 7),
        ldst_uimm(0, 0, 3, 1, 10, 9), ldst_uimm(0, 1, 3, 2, 2, 1), ldst_uimm(1, 1, 0, 3, 4, 3),
        ldst_imm9(3, 0, 1, -3, 0, 2, 1), ldst_imm9(2, 0, 0, -4, 3, 2, 1), ldst_imm9(3, 0, 1, 24, 1, 4, 3), ldst_imm9(0, 1, 2, -17, 0, 31, 5),
        ldst_reg(3, 0, 1, 3, 3, 1, 2, 1), ldst_reg(1, 0, 1, 3, 2, 0, 2, 1), ldst_reg(3, 0, 0, 3, 6, 1, 2, 1), ldst_reg(3, 1, 1, 7, 7, 0, 6, 5),
        ldst_reg(0, 1, 3, 7, 3, 1, 6, 5),
        ldstp(2, 0, 2, 1, 2, 2, 3, 1), ldstp(0, 0, 3, 0, -2, 2, 3, 1), ldstp(1, 0, 1, 1, 2, 2, 3, 1), ldstp(2, 1, 2, 1, 2, 2, 3, 1),
        ldstp(1, 1, 1, 0, -2, 2, 3, 1), ldstp(2, 0, 3, 0, -4, 30, 31, 29),
        vmulti(1, 1, 0, 0, 7, 0, 2, 1), vmulti(1, 1, 1, 31, 10, 2, 2, 1), vmulti(0, 0, 1, 7, 6, 0, 6, 3), vmulti(1, 1, 1, 31, 0, 2, 1, 0),
        vmulti(1, 1, 0, 0, 8, 1, 3, 1), vmulti(0, 0, 0, 0, 2, 3, 2, 1), ld1r(1, 2, 2, 1), lane_s(1, 3, 2, 1), lane_s(0, 1, 3, 2),
        excl(3, 0, 1, 0, 31, 0, 31, 2, 1), excl(3, 0, 0, 0, 3, 0, 31, 2, 1), excl(2, 0, 1, 0, 31, 1, 31, 2, 1), excl(2, 0, 0, 0, 3, 1, 31, 2, 1),
        excl(0, 0, 1, 0, 31, 0, 31, 2, 1), excl(1, 0, 0, 0, 3, 0, 31, 2, 1), excl(3, 0, 1, 1, 31, 0, 2, 3, 1), excl(3, 0, 0, 1, 4, 0, 2, 3, 1),
        excl(3, 1, 1, 0, 31, 1, 31, 2, 1), excl(2, 1, 0, 0, 31, 1, 31, 2, 1), excl(3, 1, 0, 1, 1, 0, 31, 3, 2), excl(2, 1, 1, 1, 1, 1, 31, 3, 2),
        excl(1, 0, 0, 1, 0, 0, 31, 4, 2), ldapr(0, 2, 1),
        atomic(3, 0, 0, 1, 0, 0, 3, 2), atomic(2, 1, 1, 1, 0, 3, 3, 2), atomic(0, 0, 0, 1, 1, 0, 3, 2), atomic(3, 0, 1, 1, 0, 1, 3, 2),
        atomic(1, 1, 0, 1, 0, 6, 3, 2), DC_ZVA | 1,
        literal(1, 0, 2, 1), literal(2, 1, 4, 1), literal(2, 0, -1, 2),
        addsub_imm(0, 0, 0, 0x123, 2, 1), addsub_imm(1, 0, 1, 5, 2, 1), alu_reg(ADDS_R, 3, 2, 1), alu_reg(SUBS_R, 2, 1, 31),
        alu_reg(EOR_R, 3, 2, 1), cset(1, 1), movw(MOVZ, 1, 0x1234, 1), movw(MOVK, 2, 0x5678, 1), movw(MOVN, 0, 3, 1),
        bcond(1, 2), cbz(0, 1, -3, 1), b_imm(1, 4), adr(8, 1), BR(1), BLR(2), RET(30), RET(3),
        ldstp(2, 1, 2, 1, 20, 1, 28, 0), MSR_FPCR, MSR_FPSR, addsub_imm(0, 0, 0, 0, 0, 31), MSR_NZCV, MRS_NZCV | 2, MRS_FPCR | 2,
        MRS_FPSR | 2, addsub_imm(0, 0, 0, 0, 31, 2), addsub_imm(0, 0, 0, 32, 31, 31), addsub_imm(1, 0, 0, 48, 31, 31),
        addsub_imm(1, 1, 0, 1, 23, 23), 0x11000421u, b_imm(0, 3), cbz(1, 0, 2, 5), tbz(1, 5, 2, 3), ldst_uimm(3, 0, 1, 28, 28, 28),
        ldstp(2, 1, 2, 0, 50, 31, 0, 30), ldstp(2, 0, 1, 1, 2, 3, 31, 2), ldst_uimm(3, 0, 0, 30, 0, 30), CLREX,
    };
    size_t n = sizeof mine / sizeof mine[0], want = (size_t)(fuzz_ref_end - fuzz_ref);
    int bad = n != want;
    if (bad) printf("  encoders: %zu built, %zu in the reference\n", n, want);
    for (size_t i = 0; i < n && i < want; i++)
        if (mine[i] != fuzz_ref[i]) printf("  encoder %zu: %08x, the assembler says %08x\n", i, mine[i], fuzz_ref[i]), bad = 1;
    return bad;
}

/* ---- the program generator ---- */

static uint64_t rs;
static uint64_t rnd(void) {
    rs ^= rs >> 12, rs ^= rs << 25, rs ^= rs >> 27;
    return rs * 0x2545f4914f6cdd1dull;
}
static uint32_t rn(uint32_t n) { return (uint32_t)(rnd() >> 11) % n; }

static uint32_t pos;     /* next word of cbuf */
static int sp_off;       /* bytes the guest SP is from where it started */
static int in_sub;       /* writing a subroutine: x30 holds its return address */
static int nsub;
static char oplog[4096]; /* what the last sequence was, for a failure report */
static size_t oplen;
static int logging;

static void emit(uint32_t w) {
    if (pos < CODE_WORDS) cbuf[pos] = w;
    pos++;
}

static void note(const char *what, int a, int b, int c, int64_t off) {
    if (!logging || oplen > sizeof oplog - 64) return;
    oplen += (size_t)snprintf(oplog + oplen, sizeof oplog - oplen, "%s(%d,%d,%d)@%lld ", what, a, b, c, (long long)off);
}

/* x21: the near area, x22: the far one, x23: the loop count. Never written. */
static int reserved(int r) { return r == 21 || r == 22 || r == 23 || (in_sub && r == 30); }

static int pick_gpr(uint32_t avoid) {
    for (;;) {
        int r = (int)rn(31);
        if (!reserved(r) && !(avoid >> r & 1)) return r;
    }
}
static int pick_gpr_zr(uint32_t avoid) { return rn(8) == 0 && !(avoid >> 31 & 1) ? 31 : pick_gpr(avoid); }
/* A base register: often one of those the translator keeps in the HvCpu. */
static int pick_base(uint32_t avoid) {
    static const int stolen[] = {6, 7, 15, 18, 28};
    if (rn(3) == 0) {
        int r = stolen[rn(5)];
        if (!reserved(r) && !(avoid >> r & 1)) return r;
    }
    return pick_gpr(avoid);
}

/* d = n + v (|v| < 2^24), n and d never SP */
static void add_imm(int d, int n, int64_t v) {
    int sub = v < 0;
    uint64_t a = sub ? (uint64_t)0 - (uint64_t)v : (uint64_t)v;
    if (a >> 12) {
        emit(addsub_imm(sub, 0, 1, (uint32_t)(a >> 12), n, d));
        n = d;
    }
    if ((a & 0xfff) || !(a >> 12)) emit(addsub_imm(sub, 0, 0, (uint32_t)(a & 0xfff), n, d));
}

static void set_base(int b, int region, int64_t off) { add_imm(b, region == NEAR ? 21 : 22, off); }

static void mov64(int d, uint64_t v) {
    emit(movw(MOVZ, 0, (uint32_t)v, d));
    for (int hw = 1; hw < 4; hw++)
        if ((v >> 16 * hw) & 0xffff) emit(movw(MOVK, hw, (uint32_t)(v >> 16 * hw), d));
}

/* An offset in the area for `bytes` at `align`: mostly within 80 bytes of a page boundary. */
static int64_t pick_off(int region, uint32_t bytes, uint32_t align) {
    int64_t size = region == NEAR ? NEAR_SIZE : FAR_SIZE, off;
    if (rn(10) < 7) off = 16384 * (1 + (int64_t)rn((uint32_t)(size / 16384 - 1))) + (int64_t)rn(161) - 80;
    else off = 64 + (int64_t)rn((uint32_t)(size - 256));
    off &= ~(int64_t)(align - 1);
    if (off + bytes > size - 64) off = (size - 64 - bytes) & ~(int64_t)(align - 1);
    if (off < 64) off = 64;
    return off;
}

static int stack_room(int64_t imm, uint32_t bytes) { /* [sp + imm, + bytes) in the stack area */
    int64_t a = SP0_OFF + sp_off + imm;
    return a >= 1024 && a + bytes <= STACK_SIZE - 1024;
}
/* SP may move by imm (a multiple of 16) and stay within 4000 bytes below where it started. */
static int sp_may_move(int64_t imm) { return sp_off + imm >= -4000 && sp_off + imm <= 0; }

static void flags_before(int *cond) {
    *cond = -1;
    if (rn(3)) return;
    emit(alu_reg(SUBS_R, pick_gpr_zr(0), pick_gpr_zr(0), 31)); /* cmp */
    *cond = (int)rn(14);
}
static void flags_after(int cond) {
    if (cond >= 0) emit(cset(cond, pick_gpr(0)));
}

/* LDR/STR of one register, every addressing form. */
static void gen_single(void) {
    int vec = rn(4) == 0;
    int vs = vec ? (int)rn(5) : (int)rn(4); /* log2 bytes (vector 4: Q) */
    uint32_t bytes = 1u << vs;
    int load = (int)rn(2), size, opc;
    if (vec) size = vs == 4 ? 0 : vs, opc = (vs == 4 ? 2 : 0) | load;
    else {
        size = vs, opc = load;
        if (load && vs < 3 && rn(3) == 0) opc = vs == 2 ? 2 : 2 + (int)rn(2); /* LDRS* to 64 (or 32) bits */
    }
    int mode = (int)rn(6); /* 0, 1 unsigned offset, 2 unscaled, 3 pre, 4 post, 5 register */
    int sp = !in_sub && rn(6) == 0;
    int region = rn(10) < 7 ? NEAR : FAR;
    int wb = mode == 3 || mode == 4;
    int b = 31, t, m = -1;
    int64_t imm = 0, addr = 0;
    int option = 3, s = 0;
    if (sp) {
        if (wb) { /* by a multiple of 16: SP stays aligned */
            imm = 16 * (int64_t)(1 + rn(4));
            if (mode == 3 || rn(2)) imm = -imm;
            if (!sp_may_move(imm)) mode = 2, wb = 0;
        }
        if (mode < 2) imm = (int64_t)rn(16) * bytes;
        else if (mode == 2) imm = (int64_t)rn(64) - 32;
        else if (mode == 5) imm = 0;
        if (!stack_room(mode == 4 ? 0 : imm, bytes)) return;
    }
    t = vec ? (int)rn(32) : pick_gpr_zr(0);
    if (!sp) {
        b = pick_base(!vec && wb && t != 31 ? 1u << t : 0);
        addr = pick_off(region, bytes, 1);
        switch (mode) {
        case 0: case 1: imm = (int64_t)rn(mode ? 4096 : 16) * bytes; if (imm > addr + 1024) imm = (int64_t)rn(16) * bytes; break;
        case 2: case 3: case 4: imm = (int64_t)rn(512) - 256; break;
        default: break;
        }
    }
    int cond;
    flags_before(&cond);
    if (mode == 5) {
        static const int options[] = {3, 2, 6, 7};
        option = options[rn(4)];
        s = (int)rn(2);
        int64_t k = option == 2 ? (int64_t)rn(32) : (int64_t)rn(64) - 32;
        m = pick_gpr(sp ? 0 : 1u << b);
        int shift = s ? vs : 0;
        uint64_t idx = (uint64_t)k;
        if (option == 2 || option == 6) idx = (uint32_t)k | (uint64_t)(rnd() & 0xffff) << 32; /* the upper half is not used */
        mov64(m, idx);
        imm = (int64_t)((uint64_t)k << shift);
        if (sp && !stack_room(imm, bytes)) imm = 0, mode = 2; /* fall back to [sp] below */
    }
    if (!sp) set_base(b, region, mode == 4 ? addr : addr - imm);
    uint32_t w;
    if (mode == 5) w = ldst_reg(size, vec, opc, m, option, s, b, t);
    else if (mode < 2) w = ldst_uimm(size, vec, opc, (uint32_t)(imm / (int64_t)bytes), b, t);
    else w = ldst_imm9(size, vec, opc, (int)imm, mode == 2 ? 0 : mode == 3 ? 3 : 1, b, t);
    if (sp && wb) sp_off += (int)imm;
    emit(w);
    flags_after(cond);
    note(load ? "ld" : "st", vs | vec << 4, b, mode, sp ? imm : addr);
}

/* LDP/STP (and LDPSW), X, W, S, D, Q. */
static void gen_pair(void) {
    int vec = rn(3) == 0, load = (int)rn(2), opc, scale;
    if (vec) {
        opc = (int)rn(3);
        scale = 4 << opc;
    } else {
        opc = load && rn(4) == 0 ? 1 : rn(2) ? 2 : 0;
        scale = opc == 2 ? 8 : 4;
    }
    uint32_t bytes = 2u * (uint32_t)scale;
    int mode = 1 + (int)rn(3); /* 1 post, 2 offset, 3 pre */
    int sp = !in_sub && rn(4) == 0;
    int64_t k = (int64_t)rn(16) - 8, imm = k * scale;
    int t, t2, b = 31;
    if (vec) t = (int)rn(32), t2 = (int)rn(32);
    else {
        t = pick_gpr_zr(0);
        t2 = pick_gpr_zr(load ? 1u << t : 0);
    }
    if (vec && load && t == t2) t2 = (t + 1) & 31;
    int64_t addr = 0;
    if (sp) {
        if (mode != 2) { /* writeback by a multiple of 16 */
            imm = (int64_t)(1 + rn(4)) * 16 * (mode == 3 ? -1 : 1);
            if (!sp_may_move(imm)) mode = 2, imm = k * scale;
        }
        if (!stack_room(mode == 1 ? 0 : imm, bytes)) return;
        if (mode != 2) sp_off += (int)imm;
    } else {
        uint32_t avoid = 0;
        if (mode != 2 && !vec) {
            if (t != 31) avoid |= 1u << t;
            if (t2 != 31) avoid |= 1u << t2;
        }
        b = pick_base(avoid);
        int region = rn(10) < 7 ? NEAR : FAR;
        addr = pick_off(region, bytes, 1);
        set_base(b, region, mode == 1 ? addr : addr - imm);
    }
    int cond;
    flags_before(&cond);
    emit(ldstp(opc, vec, mode, load, (int)(imm / scale), t2, b, t));
    flags_after(cond);
    note(load ? "ldp" : "stp", opc | vec << 4, b, mode, sp ? imm : addr);
}

/* LD1..LD4 / ST1..ST4 (multiple structures), LD1R, LD1/ST1 of one S lane. */
static void gen_vec(void) {
    int b = pick_base(0), region = rn(10) < 7 ? NEAR : FAR, t = (int)rn(32), kind = (int)rn(4);
    uint32_t w, bytes;
    int64_t addr;
    if (kind == 3) { /* LD1R or a lane */
        int which = (int)rn(3), q = (int)rn(2), size = (int)rn(4);
        bytes = which == 0 ? 1u << size : 4;
        addr = pick_off(region, bytes, 1);
        set_base(b, region, addr);
        w = which == 0 ? ld1r(q, size, b, t) : lane_s(which == 1, (int)rn(4), b, t);
    } else {
        static const int ld1_op[5] = {0, 7, 10, 6, 2}, ldn_op[5] = {0, 0, 8, 4, 0};
        int n = 1 + (int)rn(4), q = (int)rn(2), size = (int)rn(4), multi = n > 1 && rn(2);
        if (multi && size == 3) q = 1; /* LD2-LD4 have no 1D form */
        int opcode = multi ? ldn_op[n] : ld1_op[n];
        bytes = (uint32_t)n * (q ? 16u : 8u);
        int post = (int)rn(3), m = 31; /* 0 none, 1 immediate, 2 register */
        addr = pick_off(region, bytes, 1);
        set_base(b, region, addr);
        if (post == 2) {
            m = pick_gpr(1u << b);
            mov64(m, rn(200));
        }
        w = vmulti(q, (int)rn(2), post != 0, m, opcode, size, b, t);
    }
    int cond;
    flags_before(&cond);
    emit(w);
    flags_after(cond);
    note("vec", kind, b, t, addr);
}

/* LDXR/STXR (and the pairs) in the usual retry loop: the state after is the same however often it ran. */
static void gen_excl(void) {
    int pair = rn(4) == 0, size = pair ? 2 + (int)rn(2) : (int)rn(4), acq = (int)rn(2), rel = (int)rn(2);
    uint32_t bytes = pair ? 2u << size : 1u << size;
    int b = pick_base(0), t = pick_gpr(1u << b), t2 = pick_gpr(1u << b | 1u << t), s = pick_gpr(1u << b | 1u << t | 1u << t2);
    int region = rn(10) < 7 ? NEAR : FAR;
    int64_t addr = pick_off(region, bytes, bytes);
    set_base(b, region, addr);
    uint32_t loop = pos;
    int clrex = rn(5) == 0; /* CLREX in between: the store fails, every time, so no loop */
    emit(excl(size, 0, 1, pair, 31, acq, pair ? t2 : 31, b, t));
    if (!pair) emit(size == 3 ? addsub_imm(0, 0, 0, 1, t, t) : 0x11000400u | R5(t) << 5 | R5(t)); /* add t, t, #1 */
    if (clrex) emit(CLREX);
    emit(excl(size, 0, 0, pair, s, rel, pair ? t2 : 31, b, t));
    if (!clrex) emit(cbz(0, 1, (int)loop - (int)pos, s));
    note(clrex ? "clrex" : "excl", size, b, pair, addr);
}

/* LSE atomics, CAS, CASP, LDAR/STLR/LDAPR: naturally aligned. */
static void gen_atomic(void) {
    int kind = (int)rn(5), size = (int)rn(4);
    int region = rn(10) < 7 ? NEAR : FAR;
    uint32_t bytes = 1u << size;
    int b, cond;
    int64_t addr;
    if (kind == 3) { /* CASP: even pairs */
        static const int pairs[] = {0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 24, 26, 28};
        int sz = (int)rn(2), sp = pairs[rn(13)], tp;
        do tp = pairs[rn(13)]; while (tp == sp);
        bytes = sz ? 16 : 8;
        b = pick_base(3u << sp | 3u << tp);
        addr = pick_off(region, bytes, bytes);
        set_base(b, region, addr);
        flags_before(&cond);
        emit(excl(sz, 0, (int)rn(2), 1, sp, (int)rn(2), 31, b, tp));
        flags_after(cond);
        note("casp", sz, b, sp, addr);
        return;
    }
    b = pick_base(0);
    addr = pick_off(region, bytes, bytes);
    set_base(b, region, addr);
    int t = pick_gpr_zr(1u << b), s = pick_gpr_zr(1u << b);
    uint32_t w;
    if (kind == 0 || kind == 1) { /* LDADD ... LDUMIN, SWP */
        int swp = rn(9) == 0;
        w = atomic(size, (int)rn(2), (int)rn(2), s, swp, swp ? 0 : (int)rn(8), b, t);
    } else if (kind == 2) { /* CAS, sometimes with the value memory holds */
        if (rn(2) && s != 31) emit(ldst_uimm(size, 0, 1, 0, b, s));
        w = excl(size, 1, (int)rn(2), 1, s, (int)rn(2), 31, b, t);
    } else { /* LDAR, STLR, LDAPR */
        int which = (int)rn(3);
        w = which == 2 ? ldapr(size, b, t) : excl(size, 1, which == 0, 0, 31, 1, 31, b, t);
    }
    flags_before(&cond);
    emit(w);
    flags_after(cond);
    note("atom", kind, b, size, addr);
}

/* Several accesses on one base register, as plan_groups groups them (memcpy-like, prologue-like). */
static void gen_burst(void) {
    int sp = !in_sub && rn(3) == 0, b = 31, region = rn(10) < 7 ? NEAR : FAR, n = 2 + (int)rn(5);
    int64_t base = 0;
    if (!sp) {
        static const int plain[] = {0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 20, 24, 25, 26, 27, 29, 30};
        do b = plain[rn(23)]; while (reserved(b));
        base = pick_off(region, 128, 8) - 48;
        set_base(b, region, base);
    }
    int cond;
    flags_before(&cond);
    for (int i = 0; i < n; i++) {
        int pair = (int)rn(2), vec = rn(3) == 0, load = (int)rn(2), last = i == n - 1;
        int scale = vec ? (rn(2) ? 16 : 8) : (rn(3) ? 8 : 4);
        int64_t off = (int64_t)rn(14) * 8 - 16;
        int mode = 2; /* offset */
        if (last && rn(3) == 0) mode = rn(2) ? 1 : 3;
        if (sp) {
            off = (int64_t)rn(8) * 16 - 64;
            if (mode != 2 && (!sp_may_move(off) || off == 0)) mode = 2;
            if (!stack_room(mode == 1 ? 0 : off, 32)) continue;
        } else {
            off &= ~(int64_t)(scale - 1);
        }
        uint32_t avoid = sp ? 0 : 1u << b; /* a load into the base ends the group, and the address with it */
        /* t2 != t, XZR too: Apple's CPUs make LDP xzr, xzr (Rt == Rt2) undefined */
        int t = vec ? (int)rn(32) : pick_gpr_zr(avoid), t2 = vec ? (int)rn(32) : pick_gpr_zr(avoid | 1u << t);
        if (vec && load && t == t2) t2 = (t + 1) & 31;
        if (pair) {
            int opc = vec ? (scale == 16 ? 2 : 1) : (scale == 8 ? 2 : 0);
            emit(ldstp(opc, vec, mode, load, (int)(off / scale), t2, b, t));
        } else if (mode == 2) {
            int vs = scale == 16 ? 4 : scale == 8 ? 3 : 2;
            if (off >= 0) emit(ldst_uimm(vs == 4 ? 0 : vs, vec, (vs == 4 && vec ? 2 : 0) | load, (uint32_t)(off / scale), b, t));
            else emit(ldst_imm9(vs == 4 ? 0 : vs, vec, (vs == 4 && vec ? 2 : 0) | load, (int)off, 0, b, t));
        } else {
            int vs = scale == 16 ? 4 : scale == 8 ? 3 : 2;
            emit(ldst_imm9(vs == 4 ? 0 : vs, vec, (vs == 4 && vec ? 2 : 0) | load, (int)off, mode == 3 ? 3 : 1, b, t));
        }
        if (sp && mode != 2) sp_off += (int)off;
    }
    flags_after(cond);
    note("burst", n, b, sp, base);
}

static void gen_other(void) {
    int kind = (int)rn(8);
    switch (kind) {
    case 0: { /* DC ZVA */
        int b = pick_base(0), region = rn(10) < 7 ? NEAR : FAR;
        int64_t addr = pick_off(region, 64, 64);
        set_base(b, region, addr + (int64_t)rn(64));
        emit(DC_ZVA | R5(b));
        note("zva", b, 0, 0, addr);
        break;
    }
    case 1: { /* a literal load from the code page's data */
        static const int forms[][2] = {{0, 0}, {1, 0}, {2, 0}, {0, 1}, {1, 1}, {2, 1}};
        int f = (int)rn(6), t = forms[f][1] ? (int)rn(32) : pick_gpr(0);
        int at = LIT_AT + (int)rn(LIT_WORDS - 4);
        emit(literal(forms[f][0], forms[f][1], at - (int)pos, t));
        note("lit", f, t, 0, at);
        break;
    }
    case 2: { /* flags and ALU */
        int d = pick_gpr(0);
        uint32_t ops[] = {ADD_R, ADDS_R, SUBS_R, EOR_R};
        emit(alu_reg(ops[rn(4)], pick_gpr_zr(0), pick_gpr_zr(0), d));
        break;
    }
    case 3: { /* a forward conditional branch over one instruction */
        int r = pick_gpr(0);
        uint32_t c = rn(3);
        emit(c == 0 ? bcond((int)rn(14), 2) : c == 1 ? cbz((int)rn(2), (int)rn(2), 2, r) : tbz((int)rn(2), (int)rn(64), 2, r));
        emit(alu_reg(ADD_R, pick_gpr_zr(0), pick_gpr_zr(0), pick_gpr(0)));
        break;
    }
    case 4: /* a call */
        if (in_sub || !nsub) break;
        emit(b_imm(1, (int)(SUB_AT + 64 * rn((uint32_t)nsub)) - (int)pos));
        note("call", 0, 0, 0, 0);
        break;
    case 5: { /* an indirect branch to the next instruction */
        if (in_sub) break;
        int r = pick_gpr(0), c = (int)rn(3);
        emit(adr(8, r));
        emit(c == 0 ? BR(r) : c == 1 ? BLR(r) : RET(r));
        note("ind", r, c, 0, 0);
        break;
    }
    default:
        gen_single();
        break;
    }
}

static void gen_op(void) {
    uint32_t k = rn(100);
    if (k < 30) gen_single();
    else if (k < 45) gen_pair();
    else if (k < 57) gen_burst();
    else if (k < 65) gen_vec();
    else if (k < 71) gen_excl();
    else if (k < 82) gen_atomic();
    else gen_other();
}

static uint32_t seg_start(int seg) {
    uint32_t page = (uint32_t)seg * PAGE_WORDS, lo = seg ? 1100 : 256;
    if (rn(10) < 3) return page + PAGE_WORDS - 8 - 4 * rn(24); /* runs into the next page */
    return page + lo + rn(PAGE_WORDS - lo - 8);
}

/* A whole program: prologue (native only), body (looped twice), epilogue at EPI_AT. Returns the body's start. */
static uint32_t gen_program(uint64_t seed) {
    rs = seed * 0x9e3779b97f4a7c15ull + 0x1234567;
    memset(cbuf, 0, sizeof cbuf); /* udf: nothing else runs */
    oplen = 0;
    oplog[0] = 0;
    for (int i = 0; i < LIT_WORDS; i++) cbuf[LIT_AT + i] = (uint32_t)rnd();
    /* Subroutines: a few accesses and RET. */
    nsub = 2;
    in_sub = 1;
    for (int j = 0; j < nsub; j++) {
        pos = SUB_AT + 64 * (uint32_t)j;
        for (int k = 1 + (int)rn(3); k > 0; k--) {
            uint32_t c = rn(3);
            if (c == 0) gen_single();
            else if (c == 1) gen_pair();
            else gen_atomic();
        }
        emit(RET(30));
    }
    in_sub = 0;
    /* Prologue: everything from the HvCpu at x28 (as harness.h's PROGRAM). */
    pos = 0;
    for (int k = 0; k < 16; k++) emit(ldstp(2, 1, 2, 1, (320 + 32 * k) / 16, 2 * k + 1, 28, 2 * k));
    emit(ldst_uimm(3, 0, 1, 0x340 / 8, 28, 0)), emit(MSR_FPCR);
    emit(ldst_uimm(3, 0, 1, 0x348 / 8, 28, 0)), emit(MSR_FPSR);
    emit(ldst_uimm(3, 0, 1, 0xf8 / 8, 28, 0)), emit(addsub_imm(0, 0, 0, 0, 0, 31)); /* mov sp, x0 */
    emit(ldst_uimm(3, 0, 1, 0x108 / 8, 28, 0)), emit(MSR_NZCV);
    for (int r = 0; r < 28; r += 2) emit(ldstp(2, 0, 2, 1, r, r + 1, 28, r));
    emit(ldstp(2, 0, 2, 1, 29, 30, 28, 29));
    emit(ldst_uimm(3, 0, 1, 28, 28, 28));
    uint32_t jump = pos;
    emit(0);
    /* Body: three segments in three pages, each going on to the next with a B. */
    sp_off = 0;
    uint32_t start = 0, prev_b = jump;
    for (int seg = 0; seg < 3; seg++) {
        uint32_t s = seg_start(seg);
        cbuf[prev_b] = b_imm(0, (int)s - (int)prev_b);
        if (!seg) start = s;
        pos = s;
        for (int k = 4 + (int)rn(28); k > 0 && pos < s + 900; k--) gen_op();
        prev_b = pos;
        emit(0);
    }
    pos = prev_b;
    if (sp_off) emit(addsub_imm(sp_off < 0 ? 0 : 1, 0, 0, (uint32_t)(sp_off < 0 ? -sp_off : sp_off), 31, 31)); /* SP back */
    sp_off = 0;
    emit(addsub_imm(1, 1, 0, 1, 23, 23)); /* subs x23, x23, #1 */
    emit(bcond(1, (int)start - (int)pos));
    emit(b_imm(0, EPI_AT - (int)pos));
    /* Epilogue: everything into *hv_native_cpu (as harness.h's END), then hv_native_return. */
    pos = EPI_AT;
    emit(ldstp(2, 0, 3, 0, -2, 1, 31, 0)); /* stp x0, x1, [sp, #-16]! */
    uint32_t lit_cpu = pos;
    emit(0);
    emit(ldst_uimm(3, 0, 1, 0, 0, 0)); /* ldr x0, [x0] */
    for (int r = 2; r < 30; r += 2) emit(ldstp(2, 0, 2, 0, r, r + 1, 0, r));
    emit(ldst_uimm(3, 0, 0, 30, 0, 30));
    emit(MRS_NZCV | 2), emit(ldst_uimm(3, 0, 0, 0x108 / 8, 0, 2));
    emit(ldstp(2, 0, 1, 1, 2, 3, 31, 2)); /* ldp x2, x3, [sp], #16 */
    emit(ldstp(2, 0, 2, 0, 0, 3, 0, 2));
    emit(addsub_imm(0, 0, 0, 0, 31, 2)), emit(ldst_uimm(3, 0, 0, 0xf8 / 8, 0, 2)); /* mov x2, sp */
    emit(MRS_FPCR | 2), emit(ldst_uimm(3, 0, 0, 0x340 / 8, 0, 2));
    emit(MRS_FPSR | 2), emit(ldst_uimm(3, 0, 0, 0x348 / 8, 0, 2));
    for (int k = 0; k < 16; k++) emit(ldstp(2, 1, 2, 0, (320 + 32 * k) / 16, 2 * k + 1, 0, 2 * k));
    uint32_t lit_ret = pos;
    emit(0);
    emit(BR(1));
    if (pos & 1) emit(0);
    uint32_t data = pos;
    uint64_t a = (uint64_t)(uintptr_t)hv_native_cpu, r = (uint64_t)(uintptr_t)hv_native_return;
    emit((uint32_t)a), emit((uint32_t)(a >> 32)), emit((uint32_t)r), emit((uint32_t)(r >> 32));
    cbuf[lit_cpu] = literal(1, 0, (int)data - (int)lit_cpu, 0);
    cbuf[lit_ret] = literal(1, 0, (int)data + 2 - (int)lit_ret, 1);
    return start;
}

/* ---- running ---- */

static void reset_mem(void) {
    memcpy(near_mem, pattern, NEAR_SIZE);
    memcpy(far_mem, pattern + NEAR_SIZE, FAR_SIZE);
    memcpy(stack_mem, pattern + NEAR_SIZE + FAR_SIZE, STACK_SIZE);
}

static void snap_mem(uint8_t *out) {
    memcpy(out, near_mem, NEAR_SIZE);
    memcpy(out + NEAR_SIZE, far_mem, FAR_SIZE);
    memcpy(out + NEAR_SIZE + FAR_SIZE, stack_mem, STACK_SIZE);
    memset(out + NEAR_SIZE + FAR_SIZE + SP0_OFF - 16, 0, 16); /* the native epilogue's push */
}

static sigjmp_buf fault_jmp;
static volatile sig_atomic_t native_running;
static void *volatile fault_addr;

static void on_fault(int sig, siginfo_t *si, void *ctx) {
    (void)ctx;
    if (native_running) {
        native_running = 0;
        fault_addr = si->si_addr;
        siglongjmp(fault_jmp, sig);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static int native_once(const TestProgram *p, const HvCpu *init, HvCpu *out, uint8_t *mem) {
    memcpy(out, init, HV_CPU_HELPER); /* registers only: the rest of an HvCpu is megabytes */
    reset_mem();
    int sig = sigsetjmp(fault_jmp, 1);
    if (sig) return sig;
    native_running = 1;
    hv_native_run(out, p->native);
    native_running = 0;
    snap_mem(mem);
    return 0;
}

static int same_regs(const HvCpu *a, const HvCpu *b) {
    for (int i = 0; i < 31; i++)
        if (i != 18 && a->x[i] != b->x[i]) return 0;
    return a->sp == b->sp && !((a->nzcv ^ b->nzcv) & 0xf0000000) && !memcmp(a->v, b->v, sizeof a->v) && a->fpsr == b->fpsr;
}

static uint8_t mem_a[MEM_TOTAL], mem_b[MEM_TOTAL], mem_j[MEM_TOTAL];
static int native_reports;

/* Darwin may clear x18 when it preempts the native run (and a base in x18 then faults): run until two runs agree. */
static int run_native_twice(const TestProgram *p, const HvCpu *init, HvCpu *out) {
    static HvCpu b;
    for (int tries = 0; tries < 12; tries++) {
        int s1 = native_once(p, init, out, mem_a), s2 = native_once(p, init, &b, mem_b);
        if (!s1 && !s2 && same_regs(out, &b) && !memcmp(mem_a, mem_b, MEM_TOTAL)) return 0;
        if (tries == 11 && native_reports++ < 4) {
            uintptr_t at = (uintptr_t)fault_addr, c0 = (uintptr_t)code;
            printf("  native runs never agreed (signals %d, %d", s1, s2);
            if ((s1 || s2) && at - c0 < CODE_SIZE) printf("; the last at word %u: %08x", (unsigned)((at - c0) / 4), cbuf[(at - c0) / 4]);
            else if (s1 || s2) printf("; the last at %p", fault_addr);
            printf(")\n");
        }
    }
    return 1;
}

/* ---- page tables for the MMU-on modes (16 KB granule, 48-bit VA), as test_mem.c builds them ---- */

static uint64_t pt_next, root_el1, root_el0, cur_root, map_ap;
static uint64_t root_same, root_moved; /* for "kept across switches": EL0's twigs exactly; the near area's pages rotated */

static uint64_t *pt_host(uint64_t pa) { return (uint64_t *)(void *)(pt + (pa - PT_PA)); }
static uint64_t pt_alloc(void) {
    uint64_t pa = PT_PA + pt_next;
    pt_next += 16384;
    if (pt_next > PT_SIZE) {
        printf("fuzz: out of page-table space\n");
        exit(1);
    }
    memset(pt_host(pa), 0, 16384);
    return pa;
}
static void map_page(uint64_t va, uint64_t pa) {
    uint64_t table = cur_root;
    for (int level = 0; level < 3; level++) {
        int shift = 14 + 11 * (3 - level);
        uint64_t *e = &pt_host(table)[(va >> shift) & 0x7ff];
        if (!(*e & 1)) *e = pt_alloc() | 3;
        table = *e & 0x0000ffffffffc000ull;
    }
    pt_host(table)[(va >> 14) & 0x7ff] = pa | 3 | 3u << 8 | 1u << 10 | map_ap;
}
static void map_range(uint64_t va, uint64_t pa, uint64_t size) {
    for (uint64_t off = 0; off < size; off += 16384) map_page(va + off, pa + off);
}
static void build_tables(void) {
    uint64_t c = (uint64_t)(uintptr_t)code, n = (uint64_t)(uintptr_t)near_mem, f = (uint64_t)(uintptr_t)far_mem,
             s = (uint64_t)(uintptr_t)stack_mem;
    for (int el0 = 0; el0 < 2; el0++) {
        cur_root = pt_alloc();
        if (el0) root_el0 = cur_root;
        else root_el1 = cur_root;
        map_ap = el0 ? 3u << 6 : 0; /* code: read-only at both ELs for EL0's tables */
        map_range(c, c, CODE_SIZE);
        map_ap = el0 ? 1u << 6 : 0;
        map_range(n, ALIAS_PA, NEAR_SIZE);
        map_range(f, f, FAR_SIZE);
        map_range(s, s, STACK_SIZE);
    }
    /* EL0's tables again under another root: new level 0 and 1 tables, the same level 2 ones (so every twig the same). */
    root_same = pt_alloc();
    for (int i = 0; i < 2048; i++) {
        uint64_t e = pt_host(root_el0)[i];
        if (!(e & 1)) continue;
        uint64_t l1 = pt_alloc();
        memcpy(pt_host(l1), pt_host(e & 0x0000ffffffffc000ull), 16384);
        pt_host(root_same)[i] = l1 | 3;
    }
    /* And tables of their own that map the near area's pages one further on (the last to the first), the far area
       read-only at EL0 (fewer rights), the rest as EL0's tables do. */
    cur_root = root_moved = pt_alloc();
    map_ap = 3u << 6;
    map_range(c, c, CODE_SIZE);
    map_range(f, f, FAR_SIZE);
    map_ap = 1u << 6;
    for (uint64_t off = 0; off < NEAR_SIZE; off += 16384) map_page(n + off, ALIAS_PA + (off + 16384) % NEAR_SIZE);
    map_range(s, s, STACK_SIZE);
}
static void mmu_el1(HvCpu *cpu) {
    cpu->mair_el1 = 0xff;
    cpu->tcr_el1 = 16 | 2u << 14 | 1u << 23 | 5ull << 32;
    cpu->ttbr0_el1 = root_el1;
    cpu->sctlr_el1 |= 1 | 1u << 2 | 1u << 12;
    hv_tlb_flush(cpu);
}
static void mmu_el0(HvCpu *cpu) {
    mmu_el1(cpu);
    cpu->ttbr0_el1 = root_el0;
    cpu->sctlr_el1 |= 1u << 14 | 1u << 15 | 1u << 26; /* DZE, UCT, UCI */
    cpu->el = 0;
    hv_tlb_flush(cpu);
}
/* The run's EL0 TLB entries come from process switches (hv_tlb_switch_user): every page filled under root_moved, a
   switch to root_same (the moved near pages must go, the rest may stay), every page filled again, a switch to EL0's
   tables (all of it may stay). An entry kept that should not have been reads or writes the wrong page. */
static void switch_to(HvCpu *cpu, uint64_t ttbr0) {
    uint64_t old = cpu->ttbr0_el1;
    cpu->ttbr0_el1 = ttbr0;
    hv_tlb_switch_user(cpu, old, ttbr0);
    hv_ijc_switch(cpu);
}
static void fill_all(HvCpu *cpu) {
    static const uint64_t sizes[4] = {CODE_SIZE, NEAR_SIZE, FAR_SIZE, STACK_SIZE};
    const uint64_t bases[4] = {(uint64_t)(uintptr_t)code, (uint64_t)(uintptr_t)near_mem, (uint64_t)(uintptr_t)far_mem, (uint64_t)(uintptr_t)stack_mem};
    for (int r = 0; r < 4; r++)
        for (uint64_t off = 0; off < sizes[r]; off += 16384) {
            uint64_t pa;
            hv_mmu_access(cpu, bases[r] + off, HV_ACC_READ, 0, &pa);
        }
}
static void mmu_el0_switched(HvCpu *cpu) {
    mmu_el0(cpu);
    switch_to(cpu, root_moved | 3ull << 48);
    fill_all(cpu);
    switch_to(cpu, root_same | 2ull << 48);
    fill_all(cpu);
    switch_to(cpu, root_el0 | 1ull << 48);
}

/* ---- the ways of translating ---- */

typedef struct {
    const char *name;
    int tiny;  /* the machine with a tiny JIT region: it fills, and flushes, mid-run */
    int mmu;   /* 0 off (EL1), 1 on at EL1, 2 on at EL0, 3 on at EL0 with the TLB filled through process switches */
    int knob, value;
    int slow;  /* every access through hv_mem_emulate */
    unsigned runs, fails;
} Conf;
static Conf confs[] = {
    {"default", 0, 0, -1, 0, 0, 0, 0},
    {"groups", 0, 0, HV_K_GROUPS, 1, 0, 0, 0},
    {"el0, mmu", 0, 2, -1, 0, 0, 0, 0},
    {"el1, mmu, groups", 0, 1, HV_K_GROUPS, 1, 0, 0, 0},
    {"no recheck", 0, 0, HV_K_RECHECK, 0, 0, 0, 0},
    {"spill all (K3), el0", 0, 2, HV_K_TEST3, 1, 0, 0, 0},
    {"one part (K2)", 0, 0, HV_K_TEST2, 1, 0, 0, 0},
    {"C path", 0, 0, -1, 0, 1, 0, 0},
    {"tiny JIT region", 1, 0, HV_K_GROUPS, 1, 0, 0, 0},
    {"slot-major TLB, el1 mmu", 0, 1, HV_K_TLBT, 0, 0, 0, 0},
    {"movimm", 0, 0, HV_K_MOVIMM, 1, 0, 0, 0},
    {"superblocks", 0, 2, HV_K_SUPERBLOCKS, 1, 0, 0, 0},
    {"hoisted checks", 0, 0, HV_K_HOIST, 1, 0, 0, 0},
    {"el0, mmu, kept across switches", 0, 3, -1, 0, 0, 0, 0},
};
#define NCONF ((int)(sizeof confs / sizeof confs[0]))

static HvMachine m, tiny;
static int base_knob[HV_K_COUNT];
static volatile uint64_t progress;
static volatile int cur_seq = -1, cur_conf;

static void *watchdog(void *arg) {
    (void)arg;
    uint64_t last = ~0ull;
    for (int stuck = 0;; sleep(1)) {
        if (progress != last) {
            last = progress, stuck = 0;
            continue;
        }
        if (++stuck >= 20) {
            printf("fuzz: no progress for 20 s at sequence %d (%s)\n", cur_seq, cur_seq >= 0 ? confs[cur_conf].name : "-");
            fflush(stdout);
            _exit(2);
        }
    }
    return NULL;
}

static void add_regions(HvMachine *mm) {
    hv_machine_add_ram(mm, (uint64_t)(uintptr_t)code, CODE_SIZE, code, 1);
    hv_machine_add_ram(mm, (uint64_t)(uintptr_t)near_mem, NEAR_SIZE, near_mem, 0);
    hv_machine_add_ram(mm, (uint64_t)(uintptr_t)far_mem, FAR_SIZE, far_mem, 0);
    hv_machine_add_ram(mm, (uint64_t)(uintptr_t)stack_mem, STACK_SIZE, stack_mem, 0);
    hv_machine_add_ram(mm, ALIAS_PA, NEAR_SIZE, near_mem, 0);
    hv_machine_add_ram(mm, PT_PA, PT_SIZE, pt, 0);
}

static double now_s(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

static int one(int seq, uint64_t seed, Conf *c, int report) {
    static HvCpu init, native, jits[2]; /* one per machine */
    HvCpu *jit = &jits[c->tiny];
    uint32_t start = gen_program(seed);
    hv_jit_write(&code_region, code, cbuf, CODE_SIZE);
    hv_jit_finish(&code_region, code, CODE_WORDS);
    TestProgram p = {"fuzz", code, code + start, code + EPI_AT};
    uint64_t ps = seed * 0x2545f4914f6cdd1dull + 7;
    for (size_t i = 0; i < MEM_TOTAL; i += 8) {
        ps ^= ps << 13, ps ^= ps >> 7, ps ^= ps << 17;
        memcpy(pattern + i, &ps, 8);
    }
    memset(&init, 0, HV_CPU_HELPER);
    seed_cpu(&init, seed, (uint64_t)(uintptr_t)stack_mem + SP0_OFF);
    init.x[21] = (uint64_t)(uintptr_t)near_mem;
    init.x[22] = (uint64_t)(uintptr_t)far_mem;
    init.x[23] = 2;
    init.nzcv = (seed & 15) << 28;
    if (run_native_twice(&p, &init, &native)) return 1; /* the program, not the JIT */
    HvMachine *mm = c->tiny ? &tiny : &m;
    memcpy(hv_knob, base_knob, sizeof hv_knob);
    if (c->knob >= 0) hv_knob[c->knob] = c->value;
    hv_flush_blocks(mm);
    mm->slow_mem = c->slow;
    reset_mem();
    int bad = run_jit(mm, &p, &init, jit, c->mmu == 1 ? mmu_el1 : c->mmu == 2 ? mmu_el0 : c->mmu == 3 ? mmu_el0_switched : NULL);
    char name[64];
    snprintf(name, sizeof name, "seq %d (%s)", seq, c->name);
    if (!bad) bad = report ? compare_cpus(name, &native, jit) : !same_regs(&native, jit);
    if (!bad) {
        snap_mem(mem_j);
        for (size_t off = 0; off < MEM_TOTAL; off += 8)
            if (memcmp(mem_a + off, mem_j + off, 8)) {
                if (report && bad < 4) {
                    uint64_t x, y;
                    memcpy(&x, mem_a + off, 8), memcpy(&y, mem_j + off, 8);
                    printf("  %s: %s+%zu native %016llx jit %016llx\n", name, off < NEAR_SIZE ? "near" : off < NEAR_SIZE + FAR_SIZE ? "far" : "stack",
                           off < NEAR_SIZE ? off : off < NEAR_SIZE + FAR_SIZE ? off - NEAR_SIZE : off - NEAR_SIZE - FAR_SIZE,
                           (unsigned long long)x, (unsigned long long)y);
                }
                bad++;
            }
    }
    return bad ? 2 : 0;
}

/* What HV_HOIST_CHECK costs in code: the same n programs translated without and with it (each run checked against
   the native one as usual). Returns the runs that differed. */
static int hoist_cost(uint64_t seed0, int n) {
    static Conf off = {"hoist off", 0, 0, HV_K_HOIST, 0, 0, 0, 0}, on = {"hoist on", 0, 0, HV_K_HOIST, 1, 0, 0, 0};
    uint64_t hot[2] = {0, 0}, all[2] = {0, 0}, insns[2] = {0, 0};
    int bad = 0;
    for (int i = 0; i < n; i++)
        for (int k = 0; k < 2; k++) {
            HvXlateCounts a = hv_xlate_counts;
            bad += one(-1, seed0 + 1000000 + (uint64_t)i, k ? &on : &off, 0) == 2;
            HvXlateCounts b = hv_xlate_counts;
            hot[k] += b.hot - a.hot;
            all[k] += b.hot + b.cold + b.pool - a.hot - a.cold - a.pool;
            insns[k] += b.insns - a.insns;
            progress++;
        }
    double h0 = (double)hot[0] / ((double)insns[0] + 1e-9), h1 = (double)hot[1] / ((double)insns[1] + 1e-9);
    double w0 = (double)all[0] / ((double)insns[0] + 1e-9), w1 = (double)all[1] / ((double)insns[1] + 1e-9);
    printf("hoisted checks (HV_HOIST_CHECK), the same %d programs: code per guest instruction %.3f words without, %.3f with "
           "(%+.2f%%; hot part %.3f, %.3f, %+.2f%%), %d failures\n",
           n, w0, w1, 100 * (w1 / (w0 + 1e-9) - 1), h0, h1, 100 * (h1 / (h0 + 1e-9) - 1), bad);
    return bad;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (check_encoders()) {
        printf("test_fuzz: encoders disagree with the assembler\n");
        return 1;
    }
    int nseq = getenv("FUZZ_SEQS") ? atoi(getenv("FUZZ_SEQS")) : 20000;
    double budget = getenv("FUZZ_SECONDS") ? atof(getenv("FUZZ_SECONDS")) : 50;
    uint64_t seed0 = getenv("FUZZ_SEED") ? strtoull(getenv("FUZZ_SEED"), NULL, 0) : 1;
    int only = getenv("FUZZ_ONLY") ? atoi(getenv("FUZZ_ONLY")) : -1;

    if (hv_jit_region_open(&code_region, CODE_SIZE) != 0) return 1;
    code = code_region.base;
    uint8_t *big = mmap(NULL, FAR_OFF + FAR_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (big == MAP_FAILED) return 1;
    near_mem = big, far_mem = big + FAR_OFF;
    stack_mem = aligned_alloc(16384, STACK_SIZE);
    pt = aligned_alloc(16384, PT_SIZE);
    if (!stack_mem || !pt) return 1;

    stack_t ss = {.ss_sp = malloc(1 << 16), .ss_size = 1 << 16, .ss_flags = 0};
    sigaltstack(&ss, NULL);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_fault;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);

    if (hv_machine_init(&m, 8 << 20) != 0 || hv_machine_init(&tiny, 16 << 10) != 0) return 1;
    add_regions(&m);
    add_regions(&tiny);
    m.stats_interval = 1000000; /* count (as the app does with HV_STATS) but never print */
    build_tables();
    memcpy(base_knob, hv_knob, sizeof hv_knob);
    pthread_t wd;
    pthread_create(&wd, NULL, watchdog, NULL);

    double t0 = now_s();
    int failed = 0, ran = 0, native_bad = 0, reported = 0;
    HvXlateCounts x0 = hv_xlate_counts;
    for (int seq = 0; seq < nseq; seq++) {
        if (now_s() - t0 > budget) break;
        int k = only >= 0 ? only % NCONF : seq % NCONF;
        uint64_t seed = seed0 + (uint64_t)seq;
        cur_seq = seq, cur_conf = k;
        int bad = one(seq, seed, &confs[k], 0);
        confs[k].runs++;
        ran++;
        progress++;
        if (!bad) continue;
        confs[k].fails++;
        failed++;
        native_bad += bad == 1;
        if (reported < 6 && (bad == 2 || reported < 2)) { /* the JIT's differences first: again, saying what they are */
            reported++;
            if (bad == 2) one(seq, seed, &confs[k], 1);
            logging = 1;
            gen_program(seed);
            logging = 0;
            printf("  seq %d (%s, FUZZ_SEED=%llu FUZZ_ONLY=%d FUZZ_SEQS=1): %s ops: %s\n", seq, confs[k].name, (unsigned long long)seed, k,
                   bad == 1 ? "native fault" : "JIT differs", oplog);
        }
    }
    double dt = now_s() - t0;
    memcpy(hv_knob, base_knob, sizeof hv_knob);
    for (int k = 0; k < NCONF; k++)
        if (confs[k].runs) printf("%-26s: %5u sequences, %u failures\n", confs[k].name, confs[k].runs, confs[k].fails);
    HvXlateCounts x = hv_xlate_counts;
    double insns = (double)(x.insns - x0.insns) + 1e-9;
    printf("code per guest instruction: hot %.2f cold %.2f pool %.2f total %.2f words (%llu blocks)\n",
           (double)(x.hot - x0.hot) / insns, (double)(x.cold - x0.cold) / insns, (double)(x.pool - x0.pool) / insns,
           (double)(x.hot - x0.hot + x.cold - x0.cold + x.pool - x0.pool) / insns, (unsigned long long)(x.blocks - x0.blocks));
    printf("cold code per guest instruction: exits %.2f slow paths %.2f group copies %.2f branch-cache misses %.2f other %.2f\n",
           (double)(x.cold_kind[HV_COLD_EXIT] - x0.cold_kind[HV_COLD_EXIT]) / insns,
           (double)(x.cold_kind[HV_COLD_SLOW] - x0.cold_kind[HV_COLD_SLOW]) / insns,
           (double)(x.cold_kind[HV_COLD_GROUP] - x0.cold_kind[HV_COLD_GROUP]) / insns,
           (double)(x.cold_kind[HV_COLD_IJC] - x0.cold_kind[HV_COLD_IJC]) / insns,
           (double)(x.cold_kind[HV_COLD_OTHER] - x0.cold_kind[HV_COLD_OTHER]) / insns);
    HvStats tot;
    hv_stats_total(&m, &tot);
    printf("slow paths: %llu helper accesses, %llu refills, %llu chained\n", (unsigned long long)hv_stat_slow_mem(&m),
           (unsigned long long)tot.refills, (unsigned long long)tot.chained);
    if (only < 0) failed += hoist_cost(seed0, 300);
    memcpy(hv_knob, base_knob, sizeof hv_knob);
    printf("%d sequences in %.1f s, %d failures (%d of them the native run's)\n", ran, dt, failed, native_bad);
    return failed != 0;
}
