#ifndef HENGEVM_CODECACHE_H
#define HENGEVM_CODECACHE_H

#include <stddef.h>
#include <stdint.h>

/* The code cache in segments (codecache.c). The JIT region is cut into equal segments that two streams of blocks fill
   in turn: young blocks, and tenured ones (blocks translated again soon after an eviction dropped them: the working
   set), which may hold about three quarters and are evicted only when they hold more. When only one free segment is
   left, the oldest full segment of one stream is condemned: nothing new may lead
   into it, the chained exits into it go back to their stubs, its blocks leave the hash, and every CPU is asked to empty
   its branch caches. Once every CPU has been back at the top of its dispatcher loop since then (or was parked), nothing
   can reach its code any more, and it is freed for new code. No CPU stops for it. A full flush (every CPU stopped) is
   left for what this cannot do: a region too small for segments, or nothing that could be taken back.

   Based on oliverames' Henge PR #186 (the region as a ring of segments, block records kept per segment, exits listed
   both ways so one can leave a list, freed exits reused, one cache maintenance pass for many rewritten words). */

struct HvMachine;
struct HvCpu;
struct HvBlock;
struct HvRam;

#define HV_CC_MAX_SEGS 64
enum { HV_CC_YOUNG, HV_CC_TENURED };
enum { HV_CC_OK, HV_CC_STALE, HV_CC_NOSPACE, HV_CC_FLUSH }; /* hv_cc_publish */
#define HV_CC_NEED 1u /* HvPerCpu.cc_work: this CPU waits for room (at the top of its loop) */
#define HV_CC_JOB 2u  /* it condemned a segment and moves the eviction on, a step per loop */

typedef struct HvCodeCache {
    /* Read by every CPU without a lock (each block lookup, the top of each dispatcher loop); written at a condemn. */
    uint32_t epoch __attribute__((aligned(128))); /* bumped once a condemned segment's ways in are closed */
    uint32_t nseg;      /* segments in use; 0: one region, filled, then flushed whole */
    uint32_t seg_shift; /* a segment is 1 << seg_shift words */
    uint32_t tag[HV_CC_MAX_SEGS]; /* seg << 24 | generation, bumped at a condemn: a block whose stag differs is gone */
    /* The rest under the translation lock (m->tr_mu), but slot_top. */
    uint8_t state[HV_CC_MAX_SEGS] __attribute__((aligned(128)));
    uint8_t kind[HV_CC_MAX_SEGS];
    uint32_t pos[HV_CC_MAX_SEGS];  /* words handed out from an open segment */
    uint32_t rec_head[HV_CC_MAX_SEGS], rec_tail[HV_CC_MAX_SEGS], nrec[HV_CC_MAX_SEGS]; /* its blocks' record chunks */
    uint8_t fifo[2][HV_CC_MAX_SEGS]; /* each stream's full segments, oldest first (a ring) */
    uint32_t fifo_head[2], fifo_len[2];
    int open[2];        /* each stream's segment being filled, or -1 */
    uint32_t nfree, ntenured, tenure_max; /* free segments; tenured ones open or full, and how many before one goes */
    int too_big;        /* a reservation larger than a segment: segments off from the next full flush */
    /* The eviction in flight (one at a time). */
    int job_seg;        /* -1: none */
    uint32_t job_phase, job_cursor, job_sub, job_epoch;
    /* Block records: chunks of m->blocks, handed to segments and back. */
    uint32_t rec_chunk, nrec_chunks, rec_free;
    uint16_t *rec_len;
    uint32_t *rec_next;
    /* Tenuring: blocks dropped by an eviction, by key (hashed), marked with the eviction count then (low byte). */
    uint8_t *evicted;
    uint32_t evicted_mask, nevict;
    /* Words rewritten in one step, for one instruction-cache pass. */
    uint32_t **words;
    uint32_t nwords, words_cap;
    int poison;         /* HV_JIT_POISON: freed segments zeroed, and checked to be unreachable */
    /* Exits freed with their segments, for the exits translated next: a lock-free stack through m->slot_xnext,
       (pops << 32) | (slot + 1). */
    uint64_t slot_top __attribute__((aligned(128)));
    /* Counters, for the stats line and the tests (mostly under the lock; tenured translations: HvStats.cc_tenured). */
    uint64_t evictions, evict_tenured, evict_blocks, evict_unchained, evict_ticks;
    uint64_t waits, wait_ticks, stale, check_bad;
} HvCodeCache;

int hv_cc_init(struct HvMachine *m);
void hv_cc_free(struct HvMachine *m);
/* The bytes of its tables for max_blocks records (hv_machine_table_bytes), and those given back (hv_machine_trim). */
size_t hv_cc_table_bytes(uint32_t max_blocks);
void hv_cc_trim(struct HvMachine *m);
/* A full flush (every CPU stopped, the translation lock held): every segment free, sized again from the JIT region. */
void hv_cc_reset(struct HvMachine *m);
/* Which stream a block about to be placed goes to. Any thread. */
int hv_cc_kind(struct HvMachine *m, uint64_t va, uint64_t pa, uint32_t flags);
/* Room for `words` instructions in an open segment of the stream (taking the translation lock), and that segment's
   tag for the blocks placed there. NULL: none now; then a CPU (hv_self) that should wait for it has HV_CC_NEED set,
   else only a full flush makes room. */
uint32_t *hv_cc_reserve(struct HvMachine *m, int kind, size_t words, uint32_t *stag);
/* Under the translation lock: a block just placed (nb, its slots this thread's last translation's) into the hash
   bucket h. HV_CC_OK with *out its record; STALE: its segment was condemned meanwhile, translate it again; NOSPACE:
   wait for room (an eviction is under way); FLUSH: only a full flush makes room. */
int hv_cc_publish(struct HvMachine *m, const struct HvBlock *nb, uint32_t h, struct HvBlock **out);
/* Under the translation lock: is the code at p in a segment that is not on its way out? */
int hv_cc_code_live(const struct HvMachine *m, const uint32_t *p);
/* A chainable exit's slot (~0u: none left), and back when its translation is dropped. Any thread. */
uint32_t hv_cc_slot_take(struct HvMachine *m);
void hv_cc_slot_put(struct HvMachine *m, uint32_t idx);
/* Under the translation lock: an exit chained to a block in RAM page pg of ram, onto that page's list. */
void hv_cc_xlink(struct HvMachine *m, struct HvRam *ram, uint64_t pg, uint32_t idx);
/* The top of the dispatcher loop, when the epoch moved or this CPU has code-cache work: catch up (its branch caches,
   return predictions and front cache emptied), move an eviction on, or wait for room. 1 if it caught up with a new
   epoch: an exit remembered from before must not be chained now. */
int hv_cc_service(struct HvCpu *cpu);
/* Diagnostics: the block whose code starts nearest at or before host address pc, or NULL. */
struct HvBlock *hv_block_at(struct HvMachine *m, const uint32_t *pc);

#endif
