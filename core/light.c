/* The light paths for SVC, ERET and WFE (see light.h). Built with -mgeneral-regs-only: translated code calls them with
   the guest's q0-q31 in the registers, so nothing here touches SIMD/FP or calls libc (tools/simd_gate.py). */
#include "light.h"

#include "exception.h"
#include "mmu.h"
#include "translate.h"

uint32_t hv_light_flags;
uint32_t hv_light_clock;

/* How long a WFE waits for its word at most: 50 us at 24 MHz. */
#define HV_WFE_WAIT (24 * 50)

/* mach_absolute_time, as the commpage has it read (hv_light_clock must not be 0). For deadlines, so no ISB before the
   read (translated CNTVCT reads have one). */
static inline uint64_t light_now(void) {
    uint64_t t;
    uint32_t type = __atomic_load_n(&hv_light_clock, __ATOMIC_RELAXED);
    if (type == 1) __asm__ volatile("mrs %0, cntvct_el0" : "=r"(t));
    else if (type == 2) __asm__ volatile("mrs %0, S3_3_C14_C0_6" : "=r"(t)); /* CNTVCTSS_EL0 */
    else __asm__ volatile("mrs %0, S3_4_C15_C10_6" : "=r"(t));               /* ACNTVCT_EL0 */
    return t + *(volatile const uint64_t *)(uintptr_t)HV_COMMPAGE_TIMEBASE_OFFSET;
}

uintptr_t hv_resume(HvCpu *cpu) {
    HvMachine *m = cpu->m;
    HvPerCpu *p = cpu->pc_state;
    int stats = m->stats_interval != 0;
    if (!(__atomic_load_n(&hv_light_flags, __ATOMIC_RELAXED) & HV_LIGHT_RESUME) || !m->chain || m->trace || m->log >= 2 || !p ||
        cpu->pc == m->stop_pc || cpu->pc == m->stop_pc2 || cpu->halted || cpu->off) {
        if (stats && p) p->own.stats.fr_fail[0]++;
        return 0;
    }
    if (__atomic_load_n(&cpu->exit_req, __ATOMIC_RELAXED) || __atomic_load_n(&m->flush_pending, __ATOMIC_RELAXED) ||
        __atomic_load_n(&m->stw_active, __ATOMIC_RELAXED)) {
        if (stats) p->own.stats.fr_fail[1]++;
        return 0;
    }
    if ((p->irq_line && !(cpu->daif & HV_PSTATE_I)) || (p->fiq_line && !(cpu->daif & HV_PSTATE_F))) {
        if (stats) p->own.stats.fr_fail[2]++;
        return 0;
    }
    /* Its timer due: the dispatcher's tick takes the interrupt. Without a clock to read here, the kicker sets exit_req
       at the deadline instead (machine.c, kicker_pass). */
    uint64_t due = __atomic_load_n(&cpu->timer_due, __ATOMIC_RELAXED);
    if (due && __atomic_load_n(&hv_light_clock, __ATOMIC_RELAXED) && light_now() >= due) {
        if (stats) p->own.stats.fr_fail[3]++;
        return 0;
    }
    uint32_t flags = hv_block_flags(cpu);
    int kernel = flags & HV_BLOCK_EL1;
    uint64_t va = cpu->pc;
    if ((int)((va >> 55) & 1) != kernel || (va & 3)) return 0;
    uint64_t tag = va ^ cpu->ijc_salt[kernel];
    const uint64_t *ent = p->ijc + (size_t)(flags & (HV_IJC_TABLES - 1)) * (HV_IJC_TABLE_BYTES / 8) + (size_t)hv_ijc_index(tag) * 2;
    /* From this CPU's cache: no ISB. Only this CPU fills it, each time before an ISB of its own (hv_enter, the thunks
       after hv_ijc_resolve, and below), and the code an entry leads to stays until this CPU drops the entry (a code
       segment is freed only after every CPU emptied its cache, hv_cc_service; a flush empties them all). Translated
       code's own lookups (put_ijc_jump) rely on the same. */
    uintptr_t code = ent[0] == tag ? (uintptr_t)ent[1] : ent[2] == tag ? (uintptr_t)ent[3] : 0;
    if (!code) { /* made already but not cached: cache it, and an ISB first (it may be one another CPU just wrote) */
        code = (uintptr_t)hv_ijc_resolve(cpu, va, flags);
        if (code) code |= 1;
    }
    if (code) {
        cpu->exit_reason = HV_EXIT_BRANCH;
        if (stats) p->own.stats.fast_resumes++;
    } else if (stats) {
        p->own.stats.fr_fail[4]++;
    }
    return code;
}

/* WFE. xnu's spin loops arm the exclusive monitor on the lock word (LDAXR) and wait for it to change; leaving for the
   dispatcher every time made a waiting CPU spin through it (a hundred thousand times a second). Wait here instead: the
   host core sleeps in its own WFE on the host copy of the word, which wakes when another core writes it (or at the
   event stream, about every microsecond). A request for this CPU (an interrupt, a TLBI: exit_req) ends the wait, and
   so does a short timeout, so its timer and devices are seen to. Without a monitor to watch it leaves for the
   dispatcher at once, as without HV_LIGHT_WFE_WAIT. */
void hv_light_wfe(HvCpu *cpu) {
    uint32_t lf = __atomic_load_n(&hv_light_flags, __ATOMIC_RELAXED);
    uint64_t va = cpu->excl_addr;
    uint32_t size = cpu->excl_size;
    const HvTlbEntry *e = hv_tlb_ent(cpu, (va >> HV_TLB_PAGE_BITS) & (HV_TLB_SIZE - 1), hv_tlb_table(cpu, (int)cpu->el));
    uint64_t page = va & ~((1ull << HV_TLB_PAGE_BITS) - 1);
    if (!(lf & HV_LIGHT_WFE_WAIT) || va == ~0ull || (size != 1 && size != 2 && size != 4 && size != 8) || (va & (size - 1)) ||
        e->read_tag == HV_TLB_INVALID || e->read_tag + HV_TLB_ADJ != page) {
        __atomic_store_n(&cpu->exit_req, 1, __ATOMIC_RELAXED); /* let another CPU run: the dispatcher's way */
        return;
    }
    const void *host = (const void *)(uintptr_t)(va + (uint64_t)e->addend);
    uint64_t want = cpu->excl_val[0] & (size == 8 ? ~0ull : (1ull << (8 * size)) - 1);
    uint64_t deadline = light_now() + HV_WFE_WAIT;
    if (cpu->m->stats_interval) HV_ST(cpu).wfe_waits++;
    for (;;) {
        uint64_t v;
        switch (size) { /* LDAXR arms the host monitor too, so the WFE below wakes on a write */
        case 1: { uint32_t w; __asm__ volatile("ldaxrb %w0, [%1]" : "=r"(w) : "r"(host) : "memory"); v = w; break; }
        case 2: { uint32_t w; __asm__ volatile("ldaxrh %w0, [%1]" : "=r"(w) : "r"(host) : "memory"); v = w; break; }
        case 4: { uint32_t w; __asm__ volatile("ldaxr %w0, [%1]" : "=r"(w) : "r"(host) : "memory"); v = w; break; }
        default: __asm__ volatile("ldaxr %0, [%1]" : "=r"(v) : "r"(host) : "memory"); break;
        }
        if (v != want || __atomic_load_n(&cpu->exit_req, __ATOMIC_RELAXED)) break;
        if (light_now() >= deadline) {
            __atomic_store_n(&cpu->exit_req, 1, __ATOMIC_RELAXED);
            break;
        }
        if (lf & HV_LIGHT_WFE_SLEEP) __asm__ volatile("wfe" ::: "memory");
        else __asm__ volatile("yield" ::: "memory");
    }
    __asm__ volatile("clrex" ::: "memory");
}

uintptr_t hv_light(HvCpu *cpu, const HvHelperInfo *info, uintptr_t back) {
    HvMachine *m = cpu->m;
    switch (info->op & 0xff) {
    case HV_OP_WFE:
        hv_light_wfe(cpu);
        return back;
    case HV_OP_EXCEPTION: /* SVC, the only exception instruction marked light (translate.c) */
        if (m->trace || m->log >= 2) return 0; /* the full path says what it takes */
        hv_exception_enter(cpu, HV_EXC_SYNC, HV_EC_SVC64 << 26 | 1u << 25 | ((info->insn >> 5) & 0xffff), 0, 0, info->pc + 4);
        break;
    case HV_OP_ERET:
        hv_eret(cpu);
        break;
    default:
        return 0;
    }
    uintptr_t code = hv_resume(cpu);
    return code ? code : HV_LIGHT_LEAVE;
}
