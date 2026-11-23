#include "codecache.h"
#include "knobs.h"

#include <mach/mach_time.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "machine.h"
#include "mmu.h"
#include "translate.h"

/* How a segment's code stops being reachable, and why that is enough (see codecache.h for the outline).

   Ways into translated code: the block hash and each CPU's front cache (jc) in front of it, the indirect-branch
   caches and return predictions (per CPU), exits chained into a block (a patched B, a retargeted conditional branch,
   and the slot the chain thunk follows), and an exit the dispatcher is about to chain (pending_chain). And a CPU may
   simply be running there. A condemn (under the translation lock) bumps the segment's tag first, so from then on no
   lookup takes its blocks (hv_block_live), no chain is made into or out of it (chain() checks under the lock) and no
   block is published there (hv_cc_publish). Then, a step at a time, its blocks leave the hash and every exit chained
   into it from elsewhere goes back to its stub; then the epoch moves, naming the segment (epoch_seg), and every CPU is
   asked to leave. A CPU catches up at the top of its loop (hv_cc_service): it is out of translated code there, empties
   its front cache, drops every entry of its branch caches and return predictions that leads into a segment condemned
   since the epoch it saw last (a block it ran since the request may have noted a return into it; all of them, after
   more epochs than the ring holds), and forgets the exit it was about to chain; its next entry into code has an ISB.
   No entry into the segment can be made after that: its blocks are out of the hash and not live, and a fill (the
   dispatcher's, the light path's) is of a block found live, on the CPU's own thread, after it caught up. So once
   every CPU has, no branch cache leads into the segment, which is what lets a block found in a CPU's own branch cache
   be entered without an ISB (light.c). Entries into other segments stay: a reset made every process's indirect
   branches and returns miss once per eviction. A parked CPU does the same
   before it runs again. When every CPU has caught up, nothing it can reach leads into the segment, and nothing it was
   doing is still there: the segment's exits and block records are freed and it takes new code.

   A block is translated outside the lock into its thread's chunk of a segment; if that segment is condemned before
   the block is published, the block is dropped (its tag is old) and translated again. The segment cannot be freed
   meanwhile: its CPU has not been back at the top of its loop. */

enum { SEG_FREE, SEG_OPEN, SEG_FULL, SEG_CONDEMNED };
enum { JOB_IDLE, JOB_UNLINK, JOB_UNCHAIN, JOB_PUBLISH, JOB_WAIT, JOB_FREE };
#define NONE (~0u)
#define MIN_SEG_SHIFT 15    /* 128 KB: a block's hot and cold parts (translate.c's MAX_WORDS, 16384 words, each) fit */
#define WANT_SEGS 16
#define UNLINK_STEP 1024u   /* block records per step */
#define SCAN_STEP 32768u    /* exit slots per step: a step holds the translation lock well under a millisecond */

static inline size_t seg_words(const HvCodeCache *cc) { return (size_t)1 << cc->seg_shift; }

/* Word offset of p in the JIT region (huge when p is below it). */
static inline size_t jit_off(const HvMachine *m, const void *p) {
    return ((uintptr_t)p - (uintptr_t)m->jit.base) / sizeof(uint32_t);
}

static inline uint32_t seg_of(const HvMachine *m, const void *p) {
    size_t s = m->cc.nseg ? jit_off(m, p) >> m->cc.seg_shift : 0;
    return s < HV_CC_MAX_SEGS ? (uint32_t)s : HV_CC_MAX_SEGS;
}

static inline int in_seg(const HvMachine *m, const void *p, uint32_t s) {
    return jit_off(m, p) - ((size_t)s << m->cc.seg_shift) < seg_words(&m->cc);
}

static inline uint32_t slots_hw(const HvMachine *m) {
    uint32_t n = __atomic_load_n(&m->nslots, __ATOMIC_ACQUIRE);
    return n < m->max_slots ? n : m->max_slots;
}

static inline uint32_t tenure_key(const HvCodeCache *cc, uint64_t va, uint64_t pa, uint32_t flags) {
    uint64_t h = (va ^ (pa * 0x9e3779b97f4a7c15ull) ^ ((uint64_t)flags << 58)) * 0xff51afd7ed558ccdull;
    return (uint32_t)(h >> 32) & cc->evicted_mask;
}

/* As many segments as fit, about 16 (at most 64, at least 128 KB each); under 4, none. */
static void geometry(HvMachine *m) {
    HvCodeCache *cc = &m->cc;
    size_t cap = m->jit.limit && m->jit.limit < m->jit.capacity ? m->jit.limit : m->jit.capacity;
    uint32_t shift = MIN_SEG_SHIFT;
    while (shift < 40 && ((size_t)2 << shift) <= cap / WANT_SEGS) shift++;
    size_t n = cap >> shift;
    if (n > HV_CC_MAX_SEGS) n = HV_CC_MAX_SEGS;
    if (n < 4 || cc->too_big) n = 0;
    cc->seg_shift = shift;
    cc->nseg = (uint32_t)n;
    /* Tenured code may hold about seven eighths (half, with few segments): the working set should fit, and the
       young stream need only hold code until it is evicted and marked (a block wanted again within two laps of that
       comes back tenured). Three quarters translated a quarter more a run in test_codecache's workload whose hot
       pages fill the cache 0.7 times (the phone: 308 of 363 evictions were of tenured segments). */
    cc->tenure_max = n >= 8 ? (uint32_t)n * 7 / 8 - 1 : n ? (uint32_t)n / 2 - 1 : 0;
}

void hv_cc_reset(HvMachine *m) {
    HvCodeCache *cc = &m->cc;
    geometry(m);
    for (uint32_t s = 0; s < HV_CC_MAX_SEGS; s++) {
        __atomic_store_n(&cc->tag[s], s << 24 | ((cc->tag[s] + 1) & 0xffffff), __ATOMIC_SEQ_CST);
        cc->state[s] = SEG_FREE;
        cc->pos[s] = 0;
        cc->rec_head[s] = cc->rec_tail[s] = NONE;
        cc->nrec[s] = 0;
    }
    cc->fifo_head[0] = cc->fifo_head[1] = cc->fifo_len[0] = cc->fifo_len[1] = 0;
    cc->open[0] = cc->open[1] = -1;
    cc->nfree = cc->nseg;
    cc->ntenured = 0;
    cc->job_seg = -1;
    cc->job_phase = JOB_IDLE;
    cc->nwords = 0;
    for (uint32_t c = 0; c < cc->nrec_chunks; c++) {
        cc->rec_len[c] = 0;
        cc->rec_next[c] = c + 1 < cc->nrec_chunks ? c + 1 : NONE;
    }
    cc->rec_free = cc->nrec_chunks ? 0 : NONE;
    __atomic_store_n(&cc->slot_top, 0, __ATOMIC_SEQ_CST); /* the slots start over from 0 (m->nslots) */
}

/* Tenure marks: a byte per hashed key, about one for every two blocks. */
static uint32_t evicted_bits(uint32_t max_blocks) {
    uint32_t bits = 12;
    while (bits < 23 && (1u << bits) < max_blocks / 2) bits++;
    return bits;
}

size_t hv_cc_table_bytes(uint32_t max_blocks) {
    return (size_t)1 << evicted_bits(max_blocks);
}

int hv_cc_init(HvMachine *m) {
    HvCodeCache *cc = &m->cc;
    cc->rec_chunk = m->max_blocks >= (1u << 20) ? 1024 : 64;
    cc->nrec_chunks = m->max_blocks / cc->rec_chunk;
    cc->rec_len = calloc(cc->nrec_chunks ? cc->nrec_chunks : 1, sizeof *cc->rec_len);
    cc->rec_next = calloc(cc->nrec_chunks ? cc->nrec_chunks : 1, sizeof *cc->rec_next);
    uint32_t bits = evicted_bits(m->max_blocks);
    cc->evicted = hv_pages_alloc((size_t)1 << bits); /* untouched until evictions: costs nothing before */
    cc->evicted_mask = (1u << bits) - 1;
    cc->words_cap = 2 * SCAN_STEP;
    cc->words = malloc(cc->words_cap * sizeof *cc->words);
    if (!cc->rec_len || !cc->rec_next || !cc->evicted || !cc->words) return -1;
    cc->poison = hv_knob.jit_poison;
    hv_cc_reset(m);
    return 0;
}

void hv_cc_free(HvMachine *m) {
    HvCodeCache *cc = &m->cc;
    free(cc->rec_len);
    free(cc->rec_next);
    if (cc->evicted) hv_pages_free(cc->evicted, (size_t)cc->evicted_mask + 1);
    free(cc->words);
}

void hv_cc_trim(HvMachine *m) {
    HvCodeCache *cc = &m->cc;
    if (cc->evicted) hv_pages_zero(cc->evicted, (size_t)cc->evicted_mask + 1);
}

/* ---- records, slots, lists ---- */

/* Chunk c's records (m->blocks[0] is no block: index 0 ends a hash bucket). */
static inline HvBlock *chunk_recs(HvMachine *m, uint32_t c) {
    return &m->blocks[1 + (size_t)c * m->cc.rec_chunk];
}

static HvBlock *rec_alloc(HvMachine *m, uint32_t s) {
    HvCodeCache *cc = &m->cc;
    uint32_t c = cc->rec_tail[s];
    if (c == NONE || cc->rec_len[c] >= cc->rec_chunk) {
        c = cc->rec_free;
        if (c == NONE) return NULL;
        cc->rec_free = cc->rec_next[c];
        cc->rec_len[c] = 0;
        cc->rec_next[c] = NONE;
        if (cc->rec_head[s] == NONE) cc->rec_head[s] = c;
        else cc->rec_next[cc->rec_tail[s]] = c;
        cc->rec_tail[s] = c;
    }
    cc->nrec[s]++;
    return &chunk_recs(m, c)[cc->rec_len[c]++];
}

uint32_t hv_cc_slot_take(HvMachine *m) {
    HvCodeCache *cc = &m->cc;
    uint64_t top = __atomic_load_n(&cc->slot_top, __ATOMIC_ACQUIRE);
    while ((uint32_t)top) {
        uint32_t idx = (uint32_t)top - 1;
        uint32_t next = __atomic_load_n(&m->slot_xnext[idx], __ATOMIC_RELAXED);
        if (__atomic_compare_exchange_n(&cc->slot_top, &top, ((top >> 32) + 1) << 32 | next, 1, __ATOMIC_ACQUIRE,
                                        __ATOMIC_ACQUIRE))
            return idx;
    }
    /* Looked at before it is bumped, so a long run cannot take it round past 2^32 and hand out a slot in use. */
    if (__atomic_load_n(&m->nslots, __ATOMIC_RELAXED) >= m->max_slots) return ~0u;
    uint32_t idx = __atomic_fetch_add(&m->nslots, 1, __ATOMIC_RELAXED);
    return idx < m->max_slots ? idx : ~0u;
}

/* first .. last, linked through slot_xnext (slot + 1), onto the stack. */
static void slot_push(HvMachine *m, uint32_t first, uint32_t last) {
    HvCodeCache *cc = &m->cc;
    uint64_t top = __atomic_load_n(&cc->slot_top, __ATOMIC_RELAXED);
    do __atomic_store_n(&m->slot_xnext[last], (uint32_t)top, __ATOMIC_RELAXED);
    while (!__atomic_compare_exchange_n(&cc->slot_top, &top, ((top >> 32) + 1) << 32 | (first + 1), 1, __ATOMIC_RELEASE,
                                        __ATOMIC_RELAXED));
}

void hv_cc_slot_put(HvMachine *m, uint32_t idx) {
    slot_push(m, idx, idx);
}

void hv_cc_xlink(HvMachine *m, HvRam *ram, uint64_t pg, uint32_t idx) {
    uint32_t old = ram->xhead[pg];
    m->slot_xnext[idx] = old;
    m->slot_xprev[idx] = 0;
    if (old) m->slot_xprev[old - 1] = idx + 1;
    ram->xhead[pg] = idx + 1;
    m->nxchained++;
}

/* Off its target page's list (an exit chained to another page). */
static void xunlink(HvMachine *m, uint32_t idx) {
    uint32_t xpa = m->slot_xpa[idx];
    uint32_t prev = m->slot_xprev[idx], next = m->slot_xnext[idx];
    if (prev) {
        m->slot_xnext[prev - 1] = next;
    } else {
        HvRam *ram = hv_xpa_ram(xpa) < (uint32_t)m->nram ? &m->ram[hv_xpa_ram(xpa)] : NULL;
        uint64_t pg = hv_xpa_pg(xpa);
        if (ram && pg < ram->npages && ram->xhead[pg] == idx + 1) ram->xhead[pg] = next;
    }
    if (next) m->slot_xprev[next - 1] = prev;
    m->slot_xpa[idx] = 0;
    m->slot_xnext[idx] = m->slot_xprev[idx] = 0;
    m->nxchained--;
}

static void note_word(HvMachine *m, uint32_t *w) {
    HvCodeCache *cc = &m->cc;
    if (cc->nwords < cc->words_cap) cc->words[cc->nwords++] = w;
    else hv_jit_finish(&m->jit, w, 1);
}

static void flush_words(HvMachine *m) {
    HvCodeCache *cc = &m->cc;
    if (cc->nwords) hv_jit_finish_words(&m->jit, cc->words, cc->nwords);
    cc->nwords = 0;
}

/* An exit chained into a block that is going: back to its stub (the conditional branch too), as hv_invalidate_code
   does for a page. Other CPUs may be running the old branch: it still goes where it went until they catch up. */
static void unpatch(HvMachine *m, uint32_t idx) {
    uint32_t *site = hv_jit_word(m, m->slot_site[idx]), *stub = hv_jit_word(m, m->slot_stub[idx]), *cond = hv_jit_word(m, m->slot_cond[idx]);
    __atomic_store_n(HV_SLOT(m, idx), 0, __ATOMIC_RELEASE);
    if (m->slot_xpa[idx]) xunlink(m, idx);
    if (!site || !stub) return;
    uint32_t insn = 0x14000000u | (uint32_t)((stub - site) & 0x3ffffff);
    if (*site != insn) {
        hv_jit_write(&m->jit, site, &insn, 4);
        note_word(m, site);
    }
    if (cond) { /* it went to the exit's B (site) before it was chained */
        uint32_t was = *cond, now = was;
        if (hv_branch_retarget(&now, site - cond) && now != was) {
            hv_jit_write(&m->jit, cond, &now, 4);
            note_word(m, cond);
        }
    }
}

int hv_cc_code_live(const HvMachine *m, const uint32_t *p) {
    if (!m->cc.nseg) return 1;
    uint32_t s = seg_of(m, p);
    return s < m->cc.nseg && (m->cc.state[s] == SEG_OPEN || m->cc.state[s] == SEG_FULL);
}

/* ---- segments ---- */

static int take_free(HvCodeCache *cc) {
    for (uint32_t s = 0; s < cc->nseg; s++)
        if (cc->state[s] == SEG_FREE) return (int)s;
    return -1;
}

static void close_seg(HvCodeCache *cc, int s) {
    int k = cc->kind[s];
    cc->state[s] = SEG_FULL;
    __atomic_store_n(&cc->used[s], 0, __ATOMIC_RELAXED); /* in use from here on: entered again */
    cc->fifo[k][(cc->fifo_head[k] + cc->fifo_len[k]) % HV_CC_MAX_SEGS] = (uint8_t)s;
    cc->fifo_len[k]++;
    cc->open[k] = -1;
}

/* Which stream gives up its oldest segment: the tenured one only when it holds more than its share (or the young
   have none full). */
static int pick(const HvCodeCache *cc) {
    if (cc->fifo_len[HV_CC_TENURED] && (cc->ntenured > cc->tenure_max || !cc->fifo_len[HV_CC_YOUNG])) return HV_CC_TENURED;
    if (cc->fifo_len[HV_CC_YOUNG]) return HV_CC_YOUNG;
    if (cc->fifo_len[HV_CC_TENURED]) return HV_CC_TENURED;
    return -1;
}

/* Start an eviction if none is under way. force: when nothing is full, close the open segments to have one (blocks
   records ran out first). 0: nothing could be taken back. Under the translation lock. */
static int take_back(HvMachine *m, int force) {
    HvCodeCache *cc = &m->cc;
    if (cc->job_seg >= 0) return 1;
    int k = pick(cc);
    if (k < 0 && force) {
        for (int i = 0; i < 2; i++)
            if (cc->open[i] >= 0) close_seg(cc, cc->open[i]);
        k = pick(cc);
    }
    if (k < 0) return 0;
    /* A tenured segment entered since it filled or since its last chance (hv_cc_touch) goes to the back once instead
       (when all of them were: the oldest after all). 4-7% fewer translations a run in test_codecache. */
    if (k == HV_CC_TENURED)
        for (uint32_t i = 0; i < cc->fifo_len[k]; i++) {
            uint32_t h = cc->fifo[k][cc->fifo_head[k]];
            if (!__atomic_load_n(&cc->used[h], __ATOMIC_RELAXED)) break;
            __atomic_store_n(&cc->used[h], 0, __ATOMIC_RELAXED);
            cc->fifo_head[k] = (cc->fifo_head[k] + 1) % HV_CC_MAX_SEGS;
            cc->fifo[k][(cc->fifo_head[k] + cc->fifo_len[k] - 1) % HV_CC_MAX_SEGS] = (uint8_t)h;
            cc->second_chances++;
        }
    uint32_t s = cc->fifo[k][cc->fifo_head[k]];
    cc->fifo_head[k] = (cc->fifo_head[k] + 1) % HV_CC_MAX_SEGS;
    cc->fifo_len[k]--;
    if (k == HV_CC_TENURED) {
        cc->ntenured--;
        cc->evict_tenured++;
    }
    cc->state[s] = SEG_CONDEMNED;
    /* From here no lookup takes its blocks, nothing chains into or out of it, nothing is published there. */
    __atomic_store_n(&cc->tag[s], s << 24 | ((cc->tag[s] + 1) & 0xffffff), __ATOMIC_SEQ_CST);
    cc->nevict++;
    cc->evictions++;
    cc->job_seg = (int)s;
    cc->job_phase = JOB_UNLINK;
    cc->job_cursor = cc->rec_head[s];
    cc->job_sub = 0;
    if (hv_self && hv_self->m == m && hv_self->pc_state) hv_self->pc_state->cc_work |= HV_CC_JOB;
    return 1;
}

uint32_t *hv_cc_reserve(HvMachine *m, int kind, size_t words, uint32_t *stag) {
    HvCodeCache *cc = &m->cc;
    words = (words + 1) & ~(size_t)1; /* blocks stay 8-byte aligned */
    if (!cc->nseg) {
        *stag = __atomic_load_n(&cc->tag[0], __ATOMIC_RELAXED);
        return hv_jit_reserve(&m->jit, words);
    }
    if (words > seg_words(cc)) {
        cc->too_big = 1; /* the next full flush goes back to one region */
        return NULL;
    }
    pthread_mutex_lock(&m->tr_mu);
    int s = cc->open[kind];
    if (s < 0 || cc->pos[s] + words > seg_words(cc)) {
        if (s >= 0) close_seg(cc, s);
        s = take_free(cc);
        if (s < 0) {
            /* None free: the eviction under way frees one; this CPU waits for it at the top of its loop. */
            if (take_back(m, 1) && hv_self && hv_self->m == m && hv_self->pc_state) hv_self->pc_state->cc_work |= HV_CC_NEED;
            pthread_mutex_unlock(&m->tr_mu);
            return NULL;
        }
        cc->state[s] = SEG_OPEN;
        cc->kind[s] = (uint8_t)kind;
        cc->pos[s] = 0;
        cc->open[kind] = s;
        cc->nfree--;
        if (kind == HV_CC_TENURED) cc->ntenured++;
        if (!cc->nfree) take_back(m, 0); /* one ahead: the next segment is freed before it is needed */
    }
    size_t at = ((size_t)s << cc->seg_shift) + cc->pos[s];
    cc->pos[s] += (uint32_t)words;
    if (at + words > m->jit.used) m->jit.used = at + words; /* the extent that may hold code, for diagnostics */
    *stag = cc->tag[s];
    pthread_mutex_unlock(&m->tr_mu);
    return m->jit.base + at;
}

int hv_cc_kind(HvMachine *m, uint64_t va, uint64_t pa, uint32_t flags) {
    HvCodeCache *cc = &m->cc;
    if (!cc->nseg) return HV_CC_YOUNG;
    uint8_t e = __atomic_load_n(&cc->evicted[tenure_key(cc, va, pa, flags)], __ATOMIC_RELAXED);
    /* Dropped by one of the last two laps' evictions, and wanted again: working set. */
    if (!e || (uint8_t)((uint8_t)__atomic_load_n(&cc->nevict, __ATOMIC_RELAXED) - e) > 2 * cc->nseg) return HV_CC_YOUNG;
    hv_stats_here(m)->cc_tenured++; /* this CPU's own line */
    return HV_CC_TENURED;
}

int hv_cc_publish(HvMachine *m, const HvBlock *nb, uint32_t h, HvBlock **out) {
    HvCodeCache *cc = &m->cc;
    uint32_t s = cc->nseg ? (nb->stag >> 24) & (HV_CC_MAX_SEGS - 1) : 0;
    if (cc->tag[s] != nb->stag) {
        cc->stale++;
        return HV_CC_STALE;
    }
    HvBlock *b = rec_alloc(m, s);
    if (!b) { /* out of block records before the code filled (blocks smaller than counted on) */
        if (!cc->nseg) return HV_CC_FLUSH;
        return take_back(m, 1) ? HV_CC_NOSPACE : HV_CC_FLUSH;
    }
    /* Exits chained as it was placed, to blocks condemned since: back to their stubs (an eviction's scan may have
       passed them before their sites were set). */
    for (uint32_t k = 0, n = hv_translate_nsites(); k < n; k++) {
        uint32_t idx = hv_translate_site_slot(k);
        uint64_t v = __atomic_load_n(HV_SLOT(m, idx), __ATOMIC_RELAXED);
        if (v && !hv_cc_code_live(m, (const uint32_t *)(uintptr_t)v)) unpatch(m, idx);
    }
    flush_words(m);
    uint32_t idx = (uint32_t)(b - m->blocks);
    *b = *nb;
    b->next = m->hash[h];
    if (m->block_jit_gen) m->block_jit_gen[idx] = __atomic_load_n(&m->jit_gen, __ATOMIC_RELAXED); /* no flush meanwhile: the lock */
    __atomic_store_n(&m->hash[h], idx, __ATOMIC_RELEASE);
    m->nblocks++;
    *out = b;
    return HV_CC_OK;
}

/* ---- an eviction, a step at a time ---- */

static int epoch_passed(HvMachine *m, uint32_t e) {
    for (int i = 0; i < m->ncpus; i++) {
        HvCpu *c = m->cpus[i];
        if (!c || !c->pc_state) continue;
        HvPerCpu *p = c->pc_state;
        if (!__atomic_load_n(&p->active, __ATOMIC_SEQ_CST)) continue; /* parked: catches up before it runs again */
        if ((int32_t)(__atomic_load_n(&p->cc_seen, __ATOMIC_SEQ_CST) - e) < 0) return 0;
    }
    return 1;
}

static void hash_unlink(HvMachine *m, HvBlock *b) {
    uint32_t idx = (uint32_t)(b - m->blocks);
    uint32_t *pp = &m->hash[hv_block_hash(m, b->va, b->pa, b->flags)];
    for (uint32_t c = *pp; c; pp = &m->blocks[c].next, c = *pp)
        if (c == idx) {
            /* b->next stays: a lookup standing on b goes on along the bucket (b is not reused before the epoch). */
            __atomic_store_n(pp, b->next, __ATOMIC_RELEASE);
            return;
        }
}

static void check_bad(HvMachine *m, const char *what, unsigned long long v) {
    if (m->cc.check_bad++ < 20) fprintf(stderr, "hengevm: code cache check: %s (%llx)\n", what, v);
}

/* HV_JIT_POISON: nothing leads into segment s any more. With every CPU caught up (or parked: those catch up first). */
static void check_gone(HvMachine *m, uint32_t s) {
    HvCodeCache *cc = &m->cc;
    for (uint32_t idx = 0, hw = slots_hw(m); idx < hw; idx++) {
        uint64_t v = __atomic_load_n(HV_SLOT(m, idx), __ATOMIC_RELAXED);
        if (v && in_seg(m, (const uint32_t *)(uintptr_t)v, s)) check_bad(m, "an exit still chained into a freed segment", idx);
        uint32_t *site = hv_jit_word(m, __atomic_load_n(&m->slot_site[idx], __ATOMIC_ACQUIRE));
        if (site && in_seg(m, site, s)) check_bad(m, "an exit of a freed segment kept", idx);
    }
    for (uint32_t c = cc->rec_head[s]; c != NONE; c = cc->rec_next[c])
        for (uint32_t i = 0; i < cc->rec_len[c]; i++) {
            HvBlock *b = &chunk_recs(m, c)[i];
            for (uint32_t x = m->hash[hv_block_hash(m, b->va, b->pa, b->flags)]; x; x = m->blocks[x].next)
                if (&m->blocks[x] == b) check_bad(m, "a block of a freed segment still in the hash", b->va);
        }
    for (int i = 0; i < m->ncpus; i++) { /* those caught up (one parked then may be on its way back to do it) */
        HvCpu *c = m->cpus[i];
        if (!c || !c->pc_state || (int32_t)(__atomic_load_n(&c->pc_state->cc_seen, __ATOMIC_SEQ_CST) - cc->job_epoch) < 0) continue;
        for (uint32_t j = 0; j < (1u << HV_JC_BITS); j++) {
            HvBlock *b = __atomic_load_n(&c->pc_state->jc[j].b, __ATOMIC_RELAXED);
            if (b && in_seg(m, hv_block_code(m, b), s)) check_bad(m, "a front cache still holding a block of a freed segment", b->va);
        }
        /* Its branch caches and return predictions: a live entry that leads into it (one of a salt given up, as a
           reset leaves them, can never match again: ids and generations only go up until the tables are cleared). */
        HvPerCpu *p = c->pc_state;
        if (cc->evictions & 15) continue; /* megabytes a CPU: every 16th eviction */
        for (int t = 0; t < HV_IJC_TABLES; t++) {
            if (!(__atomic_load_n(&p->ijc_tables_used, __ATOMIC_RELAXED) >> t & 1)) continue;
            const uint64_t *ent = p->ijc + (size_t)t * (HV_IJC_TABLE_BYTES / 8);
            for (size_t k = 0; k < HV_IJC_TABLE_BYTES / 8; k += 2) {
                uint64_t tag = __atomic_load_n(&ent[k], __ATOMIC_RELAXED), code = __atomic_load_n(&ent[k + 1], __ATOMIC_RELAXED);
                uint32_t id = (uint32_t)(tag >> 48);
                int live = (t & HV_BLOCK_EL1) ? (id ^ 0xffff) == c->kernel_gen
                                              : id && (c->asid_cid[c->cid_asid[id]] == id || id == c->ijc_salt[0] >> 48);
                if (tag && live && in_seg(m, (const void *)(uintptr_t)code, s))
                    check_bad(m, "a branch cache leading into a freed segment", tag);
            }
        }
        const uint64_t *ret = (const uint64_t *)(const void *)c->ret_tab;
        for (size_t k = 0; k < sizeof c->ret_tab / 8; k += 2) {
            uint64_t tag = __atomic_load_n(&ret[k], __ATOMIC_RELAXED), h = __atomic_load_n(&ret[k + 1], __ATOMIC_RELAXED);
            int t = (int)(k * 8 / HV_RET_TAB_BYTES);
            uint64_t top = (tag ^ __atomic_load_n(&c->ret_salt[t & HV_BLOCK_EL1], __ATOMIC_RELAXED)) >> 48;
            if (tag && (top == 0 || top == 0xffff) && in_seg(m, (const void *)(uintptr_t)h, s))
                check_bad(m, "a return prediction into a freed segment", tag);
        }
    }
}

/* One step of the eviction in flight; under the translation lock. 0: none; 1: moved on; 2: waiting for CPUs. */
static int job_step(HvMachine *m) {
    HvCodeCache *cc = &m->cc;
    if (cc->job_seg < 0) return 0;
    uint32_t s = (uint32_t)cc->job_seg;
    uint64_t t0 = mach_absolute_time();
    switch (cc->job_phase) {
    case JOB_UNLINK: { /* its blocks out of the hash, each marked as evicted (tenuring) */
        uint8_t mk = (uint8_t)cc->nevict ? (uint8_t)cc->nevict : 1;
        for (uint32_t n = 0; n < UNLINK_STEP && cc->job_cursor != NONE;) {
            uint32_t c = cc->job_cursor, len = cc->rec_len[c];
            HvBlock *arr = chunk_recs(m, c);
            for (; cc->job_sub < len && n < UNLINK_STEP; cc->job_sub++, n++) {
                HvBlock *b = &arr[cc->job_sub];
                __atomic_store_n(&cc->evicted[tenure_key(cc, b->va, b->pa, b->flags)], mk, __ATOMIC_RELAXED);
                hash_unlink(m, b);
            }
            if (cc->job_sub >= len) {
                cc->job_cursor = cc->rec_next[c];
                cc->job_sub = 0;
            }
        }
        if (cc->job_cursor == NONE) {
            cc->job_phase = JOB_UNCHAIN;
            cc->job_cursor = 0;
        }
        break;
    }
    case JOB_UNCHAIN: { /* exits from blocks elsewhere chained into it: back to their stubs */
        uint32_t hw = slots_hw(m), end = cc->job_cursor + SCAN_STEP < hw ? cc->job_cursor + SCAN_STEP : hw;
        for (uint32_t idx = cc->job_cursor; idx < end; idx++) {
            uint64_t v = __atomic_load_n(HV_SLOT(m, idx), __ATOMIC_RELAXED);
            if (!v || !in_seg(m, (const uint32_t *)(uintptr_t)v, s)) continue;
            uint32_t *site = hv_jit_word(m, __atomic_load_n(&m->slot_site[idx], __ATOMIC_ACQUIRE));
            /* Not placed yet (hv_cc_publish sees to it), or an exit of the segment itself (freed with it). */
            if (!site || in_seg(m, site, s)) continue;
            unpatch(m, idx);
            cc->evict_unchained++;
        }
        flush_words(m);
        cc->job_cursor = end;
        if (end >= hw) cc->job_phase = JOB_PUBLISH;
        break;
    }
    case JOB_PUBLISH: /* the epoch moves, naming the segment; every CPU to leave and catch up */
        cc->job_epoch = cc->epoch + 1;
        __atomic_store_n(&cc->epoch_seg[cc->job_epoch & (HV_CC_EPOCHS - 1)], (uint8_t)s, __ATOMIC_RELAXED);
        __atomic_store_n(&cc->epoch, cc->job_epoch, __ATOMIC_SEQ_CST);
        for (int i = 0; i < m->ncpus; i++)
            if (m->cpus[i] && m->cpus[i] != hv_self) hv_cpu_post(m->cpus[i], 0); /* (no request: out to the top of its loop) */
        cc->job_phase = JOB_WAIT;
        break;
    case JOB_WAIT:
        if (!epoch_passed(m, cc->job_epoch)) return 2;
        cc->job_phase = JOB_FREE;
        cc->job_cursor = 0;
        break;
    case JOB_FREE: { /* its own exits: off their lists and free; then its records; then it takes new code */
        uint32_t hw = slots_hw(m), end = cc->job_cursor + SCAN_STEP < hw ? cc->job_cursor + SCAN_STEP : hw;
        uint32_t first = NONE, last = NONE;
        for (uint32_t idx = cc->job_cursor; idx < end; idx++) {
            uint32_t *site = hv_jit_word(m, __atomic_load_n(&m->slot_site[idx], __ATOMIC_ACQUIRE));
            if (!site || !in_seg(m, site, s)) continue;
            if (m->slot_xpa[idx]) xunlink(m, idx);
            __atomic_store_n(HV_SLOT(m, idx), 0, __ATOMIC_RELAXED);
            __atomic_store_n(&m->slot_site[idx], 0, __ATOMIC_RELAXED);
            m->slot_stub[idx] = m->slot_cond[idx] = 0;
            m->slot_xa[idx] = 0;
            m->slot_xnext[idx] = first == NONE ? 0 : first + 1;
            if (first == NONE) last = idx;
            first = idx;
        }
        if (first != NONE) slot_push(m, first, last);
        cc->job_cursor = end;
        if (end < hw) break;
        if (cc->poison) check_gone(m, s);
        if (cc->rec_head[s] != NONE) {
            cc->rec_next[cc->rec_tail[s]] = cc->rec_free;
            cc->rec_free = cc->rec_head[s];
        }
        m->nblocks -= (int)cc->nrec[s];
        cc->evict_blocks += cc->nrec[s];
        cc->nrec[s] = 0;
        cc->rec_head[s] = cc->rec_tail[s] = NONE;
        if (cc->poison) hv_jit_poison(&m->jit, m->jit.base + ((size_t)s << cc->seg_shift), seg_words(cc));
        cc->state[s] = SEG_FREE;
        cc->pos[s] = 0;
        cc->nfree++;
        cc->job_seg = -1;
        cc->job_phase = JOB_IDLE;
        break;
    }
    }
    cc->evict_ticks += mach_absolute_time() - t0;
    return 1;
}

static int cc_step(HvMachine *m) {
    HvCodeCache *cc = &m->cc;
    if (__atomic_load_n(&cc->job_seg, __ATOMIC_RELAXED) < 0) return 0;
    /* Waiting needs no lock. */
    if (__atomic_load_n(&cc->job_phase, __ATOMIC_RELAXED) == JOB_WAIT &&
        !epoch_passed(m, __atomic_load_n(&cc->job_epoch, __ATOMIC_RELAXED)))
        return 2;
    pthread_mutex_lock(&m->tr_mu);
    int r = job_step(m);
    pthread_mutex_unlock(&m->tr_mu);
    return r;
}

/* Every entry of this CPU's branch caches (each table it filled) and return predictions (every table) that leads into
   segment s: dropped. Its own thread, out of translated code; another CPU's TLBI may drop entries meanwhile, which
   writes the same zeros. */
static uint64_t ijc_drop_seg(HvCpu *cpu, uint32_t s) {
    HvMachine *m = cpu->m;
    HvPerCpu *p = cpu->pc_state;
    uintptr_t lo = (uintptr_t)(m->jit.base + ((size_t)s << m->cc.seg_shift)), len = seg_words(&m->cc) * sizeof(uint32_t);
    uint64_t n = 0;
    for (int t = 0; t < HV_IJC_TABLES; t++) {
        if (!(p->ijc_tables_used >> t & 1)) continue; /* never filled since it was last cleared: all zero */
        uint64_t *ent = p->ijc + (size_t)t * (HV_IJC_TABLE_BYTES / 8);
        for (size_t i = 0; i < HV_IJC_TABLE_BYTES / 8; i += 2)
            if ((uintptr_t)ent[i + 1] - lo < len) {
                __atomic_store_n(&ent[i], 0, __ATOMIC_RELAXED); /* the empty tag */
                __atomic_store_n(&ent[i + 1], 0, __ATOMIC_RELAXED);
                n++;
            }
    }
    uint64_t *ret = (uint64_t *)(void *)cpu->ret_tab;
    for (size_t i = 0; i < sizeof cpu->ret_tab / 8; i += 2) /* {tag, the host return address} */
        if ((uintptr_t)ret[i + 1] - lo < len) {
            ret[i] = ret[i + 1] = 0;
            n++;
        }
    return n;
}

/* Out of translated code, at the top of the dispatcher loop: nothing of what this CPU holds may lead into a segment
   condemned before the epoch it now acknowledges. */
static int cc_ack(HvCpu *cpu) {
    HvPerCpu *p = cpu->pc_state;
    HvCodeCache *cc = &cpu->m->cc;
    uint32_t e = __atomic_load_n(&cc->epoch, __ATOMIC_SEQ_CST), seen = p->cc_seen;
    if (e == seen) return 0;
    hv_cpu_process_requests(cpu);
    /* The segments of the epochs since it last caught up. While this CPU is active no epoch after e can pass, so at
       most one more is published meanwhile: half the ring is safe to read. Further behind (parked long, or a first
       run): everything. */
    if (cc->nseg && e - seen <= HV_CC_EPOCHS / 2) {
        uint64_t t0 = mach_absolute_time(), n = 0;
        for (uint32_t k = seen + 1; k != e + 1; k++)
            n += ijc_drop_seg(cpu, __atomic_load_n(&cc->epoch_seg[k & (HV_CC_EPOCHS - 1)], __ATOMIC_RELAXED));
        __atomic_add_fetch(&cc->ijc_scans, 1, __ATOMIC_RELAXED);
        __atomic_add_fetch(&cc->ijc_dropped, n, __ATOMIC_RELAXED);
        __atomic_add_fetch(&cc->ijc_scan_ticks, mach_absolute_time() - t0, __ATOMIC_RELAXED);
    } else {
        hv_ijc_reset(cpu, 0); /* and the return predictions, each half */
        hv_ijc_reset(cpu, 1);
        __atomic_add_fetch(&cc->ijc_resets, 1, __ATOMIC_RELAXED);
    }
    memset(p->jc, 0, sizeof p->jc);
    __atomic_store_n(&p->cc_seen, e, __ATOMIC_SEQ_CST);
    return 1;
}

int hv_cc_service(HvCpu *cpu) {
    HvMachine *m = cpu->m;
    HvPerCpu *p = cpu->pc_state;
    int acked = cc_ack(cpu);
    if (p->cc_work & HV_CC_NEED) {
        /* No room: see the eviction under way through. Caught up all the while, so CPUs waiting like this one count
           as having passed (no two wait for each other), and answering requests (a CPU may wait for this one's). */
        uint64_t t0 = mach_absolute_time();
        for (uint32_t spins = 0;; spins++) {
            if (__atomic_load_n(&m->flush_pending, __ATOMIC_SEQ_CST) || __atomic_load_n(&m->stw_active, __ATOMIC_SEQ_CST))
                break; /* a full flush first: the dispatcher's barrier */
            int r = cc_step(m);
            acked |= cc_ack(cpu);
            hv_cpu_process_requests(cpu);
            if (!r) break;
            if (r == 2) {
                hv_machine_kick_all(m);
                if (m->big_lock_on) { /* debugging (HV_BIG_LOCK): let the others run to catch up */
                    cpu->excl_addr = ~0ull;
                    hv_big_unlock(m);
                    sched_yield();
                    hv_big_lock(m);
                } else if (spins > 64) {
                    sched_yield();
                }
            }
        }
        p->cc_work &= ~(HV_CC_NEED | HV_CC_JOB);
        __atomic_add_fetch(&m->cc.waits, 1, __ATOMIC_RELAXED);
        __atomic_add_fetch(&m->cc.wait_ticks, mach_absolute_time() - t0, __ATOMIC_RELAXED);
    } else if (p->cc_work & HV_CC_JOB) {
        if (!cc_step(m)) p->cc_work &= ~HV_CC_JOB;
        acked |= cc_ack(cpu);
    }
    return acked;
}

HvBlock *hv_block_at(HvMachine *m, const uint32_t *pc) {
    HvCodeCache *cc = &m->cc;
    if (!m->nblocks || !pc || jit_off(m, pc) >= m->jit.capacity) return NULL;
    uint32_t s = seg_of(m, pc);
    if (s >= HV_CC_MAX_SEGS) return NULL;
    /* Records go into a chunk in the order blocks were published, close to the order of their code: a binary search
       per chunk (approximate where CPUs placed blocks side by side). */
    HvBlock *best = NULL;
    uint32_t walked = 0; /* read without the lock (profilers): a list changing meanwhile cannot keep it going */
    for (uint32_t c = cc->rec_head[s]; c != NONE && c < cc->nrec_chunks && walked++ < cc->nrec_chunks; c = cc->rec_next[c]) {
        uint32_t len = cc->rec_len[c];
        if (!len || len > cc->rec_chunk) continue;
        HvBlock *arr = chunk_recs(m, c);
        uint32_t lo = 0, hi = len - 1;
        while (lo < hi) {
            uint32_t mid = (lo + hi + 1) / 2;
            if (hv_block_code(m, &arr[mid]) <= pc) lo = mid;
            else hi = mid - 1;
        }
        if (hv_block_code(m, &arr[lo]) <= pc && (!best || arr[lo].code_off > best->code_off)) best = &arr[lo];
    }
    return best;
}
