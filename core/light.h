#ifndef HENGEVM_LIGHT_H
#define HENGEVM_LIGHT_H

#include <stdint.h>

#include "machine.h"

/* The light paths (light.c): SVC, ERET and WFE, the guest's most frequent transitions, called by translated code
   through hv_helper_thunk with only x0-x17, NZCV and SP saved (host/enter.S), so the guest's q0-q31 are still live:
   nothing they reach may use SIMD or call libc (built with -mgeneral-regs-only; tools/simd_gate.py checks it). */

struct HvHelperInfo;

/* The arm64 commpage's timebase: what mach_absolute_time adds to the counter, and which counter it reads. Translated
   counter reads and the light paths take the host's time from it, without libc. */
#define HV_COMMPAGE_TIMEBASE_OFFSET 0xfffffc088ull
#define HV_COMMPAGE_TIMEBASE_TYPE   0xfffffc090ull

/* What the light paths cannot find out themselves, set once by the dispatcher before any block runs (dispatch.c). */
enum {
    HV_LIGHT_RESUME = 1,    /* an exception or ERET may go straight to its block (not HV_NO_FAST_RESUME) */
    HV_LIGHT_WFE_WAIT = 2,  /* a WFE waits in place for its word (not HV_WFE_SPIN, and the host's time is readable) */
    HV_LIGHT_WFE_SLEEP = 4, /* the host's WFE comes back by itself soon (its event stream): wait in it, not spinning */
};
extern uint32_t hv_light_flags;
extern uint32_t hv_light_clock; /* the commpage's timebase type: 0 none readable here, 1 CNTVCT, 2 CNTVCTSS, else ACNTVCT */

/* What a light path returns to hv_helper_thunk besides code to go on at: leave for the dispatcher. */
#define HV_LIGHT_LEAVE 1u

/* The block flags (HV_BLOCK_*) of the CPU's state now: what its next block is translated under. */
static inline uint32_t hv_block_flags(const HvCpu *cpu) {
    uint32_t flags = cpu->el ? HV_BLOCK_EL1 : 0;
    if (cpu->el && cpu->spsel) flags |= HV_BLOCK_SPX;
    if (cpu->el && (cpu->pstate_extra & HV_PSTATE_PAN)) flags |= HV_BLOCK_PAN;
    uint32_t fpen = (cpu->cpacr_el1 >> 20) & 3;
    if (fpen == 0 || fpen == 2 || (fpen == 1 && cpu->el == 0)) flags |= HV_BLOCK_FPOFF;
    return flags;
}

/* hv_helper_thunk's light path for SVC, ERET and WFE (HV_OP_LIGHT). back: where the block goes on after the call.
   Returns the code to go on at (bit 0 set: after an ISB), HV_LIGHT_LEAVE, or 0 when it did nothing (the full helper,
   hv_helper, then does it all). */
uintptr_t hv_light(HvCpu *cpu, const struct HvHelperInfo *info, uintptr_t back);
/* After an exception taken or an ERET: the code of the CPU's next block when nothing needs the dispatcher first (bit 0
   set: found only now, so an ISB must come before it), else 0. */
uintptr_t hv_resume(HvCpu *cpu);
/* WFE: wait in place for the word the exclusive monitor watches, or set exit_req for the dispatcher. */
void hv_light_wfe(HvCpu *cpu);

#endif
