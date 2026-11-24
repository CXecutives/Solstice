#ifndef SOLSTICEVM_TRANSLATE_H
#define SOLSTICEVM_TRANSLATE_H

#include <stdint.h>

#include "machine.h"

/* What a block passes to hv_helper. Lives in the block's literal pool. */
typedef struct HvHelperInfo {
    uint64_t pc;
    uint32_t insn;
    uint32_t op;
} HvHelperInfo;

enum {
    HV_OP_MEM = 1,     /* a load or store the fast path did not handle: emulate it whole */
    HV_OP_MRS,
    HV_OP_MSR,         /* MSR (register) or MSR (immediate); always leaves the block */
    HV_OP_SYS,         /* DC, IC, TLBI, AT */
    HV_OP_EXCEPTION,   /* SVC, HVC, SMC, BRK, HLT */
    HV_OP_ERET,
    HV_OP_UNDEF,
    HV_OP_FPTRAP,      /* FP/SIMD while CPACR_EL1.FPEN traps it */
    HV_OP_CLREX,
    HV_OP_WFI,
    HV_OP_WFE,         /* waits for the exclusive monitor's word to change (or a request); the block carries on */
};
/* In op, beside HV_OP_*: hv_helper_thunk tries the light path (hv_light, light.c) first. SVC, ERET and WFE have it. */
#define HV_OP_LIGHT 0x100u

#define HV_MAX_BLOCK_INSNS 128

/* Translates guest code starting at b->va (b->pa, b->flags filled in) into the
   machine's JIT region. `code` is the host copy of the guest instructions and
   `avail` how many may be read before the end of the guest page.
   Returns -1 if the JIT region is full. */
int hv_translate_block(HvMachine *m, HvBlock *b, const uint32_t *code, uint32_t avail);
/* The same in two steps, so CPUs translate in parallel: emit into this
   thread's buffer (no lock needed), then place it in the JIT region (under the
   translation lock). place returns -1 if the region is full. */
int hv_translate_emit(HvMachine *m, HvBlock *b, const uint32_t *code, uint32_t avail);
int hv_translate_place(HvMachine *m, HvBlock *b);
uint32_t hv_translate_last_words(void);
/* Every word this thread's last block took: hot part, cold part and literal pool. */
uint32_t hv_translate_last_size(void);
/* Its guest instructions and words (by part) into the CPU's own stats, at its publish: a translation dropped (another
   CPU's was first, its segment went meanwhile) or tried again is not counted. */
void hv_translate_count_last(HvStats *st, const HvBlock *b);
/* This thread's last translation: its chainable exits' slots, and giving them back when it is dropped. */
uint32_t hv_translate_nsites(void);
uint32_t hv_translate_site_slot(uint32_t k);
void hv_translate_discard_slots(HvMachine *m);
/* What a block's cold code is for: exit stubs (and an exit's checks), memory and other slow-path records, groups'
   plain copies, indirect-branch cache misses (the second way and the way out), the rest. */
enum { HV_COLD_EXIT, HV_COLD_SLOW, HV_COLD_GROUP, HV_COLD_IJC, HV_COLD_OTHER, HV_COLD_KINDS };
/* Totals over every block placed, for code size per guest instruction (tests and test_bench print them). */
typedef struct HvXlateCounts {
    uint64_t blocks, insns;
    uint64_t hot, cold, pool; /* words: the hot part, the cold part's code, the literal pool */
    uint64_t cold_kind[HV_COLD_KINDS]; /* the cold part's code by what it is for (HV_COLD_*) */
} HvXlateCounts;
extern HvXlateCounts hv_xlate_counts;

int hv_branch_retarget(uint32_t *w, int64_t off);

#endif
