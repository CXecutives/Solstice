#ifndef HENGEVM_JIT_REGION_H
#define HENGEVM_JIT_REGION_H

#include <stddef.h>
#include <stdint.h>

/* One executable region for translated blocks. Blocks are never freed one by
   one: the machine hands the region out in segments and takes back a whole
   segment at a time (core/codecache.c), or, too small for that, resets the
   whole region when it fills (hv_jit_reserve).

   Two shapes. macOS: one MAP_JIT mapping, made writable per thread while code
   is copied in (rw_diff is 0). iOS: an executable mapping a debugger granted
   (StikDebug or the built-in helper) plus a writable alias of the same pages
   made with vm_remap; code is written through base + rw_diff and runs at base.
   Everything outside this file and the final copy in the translator sees only
   the executable addresses. HV_JIT_SPLIT=1 makes the macOS build use the iOS
   shape, to test it. */
typedef struct HvJitRegion {
    uint32_t *base;     /* executable addresses */
    intptr_t rw_diff;   /* writable alias = base + rw_diff (bytes), or 0 */
    size_t capacity;    /* in instructions */
    size_t used;        /* in instructions */
    size_t limit;       /* in instructions; 0: all of it (HV_JIT_CAP: a smaller cache in the same region, to compare) */
    int owned;          /* mapped here (closed here) rather than handed in */
} HvJitRegion;

int hv_jit_region_open(HvJitRegion *region, size_t bytes);
/* Ask for a region of `want` bytes through claim (> 0: got it; 0: not at that size; < 0: not at any, stop), and on a
   refusal for half as much (whole 16 KB pages), and so on while at least min_bytes: the bytes obtained, or 0. A region
   smaller than wanted only empties more often; none at all and the Mac cannot start (the 4 GB iPad's case). */
size_t hv_jit_claim_halving(size_t want, size_t min_bytes, int (*claim)(size_t bytes, void *ctx), void *ctx);
/* Use memory the host already has: rx executable, rw a writable alias of it (or rx itself on macOS MAP_JIT). */
int hv_jit_region_attach(HvJitRegion *region, void *rx, void *rw, size_t bytes);
void hv_jit_region_close(HvJitRegion *region);

/* Copy `words` instructions to start (an executable address) and make them runnable. */
void hv_jit_write(HvJitRegion *region, uint32_t *start, const void *src, size_t bytes);
void hv_jit_finish(HvJitRegion *region, uint32_t *start, size_t words);
/* hv_jit_finish for two ranges at once (a block's hot and cold parts): one wait for the instruction caches, not two. */
void hv_jit_finish2(HvJitRegion *region, uint32_t *a, size_t na, uint32_t *b, size_t nb);
/* After rewriting one B (an unconditional branch) as another B, which a CPU may run as it changes (Arm allows it for
   B): the instruction caches drop the line without waiting for them all to have done so. A CPU still running the old
   branch takes the way the old one went (chaining: the exit's stub, which follows the slot) until its cache lets go. */
void hv_jit_finish_branch(HvJitRegion *region, uint32_t *word);
/* After rewriting single words with hv_jit_write: one pass, with one wait for the instruction caches, for all of them
   (an eviction undoes many chained exits at once). */
void hv_jit_finish_words(HvJitRegion *region, uint32_t *const *words, size_t n);
/* Debugging (HV_JIT_POISON): zero `words` instructions at start (an executable address), so running them faults. */
void hv_jit_poison(HvJitRegion *region, uint32_t *start, size_t words);

/* Space for `words` instructions, or NULL when the region is full. */
uint32_t *hv_jit_reserve(HvJitRegion *region, size_t words);
void hv_jit_reset(HvJitRegion *region);

#endif
