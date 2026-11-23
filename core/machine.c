#include "machine.h"

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "dispatch.h"
#include "light.h"
#include "mmu.h"
#include "sysreg.h"

_Static_assert(sizeof(*((HvMachine *)0)->slots) == 8, "HV_SLOT: two 8-byte words (hv_chain_thunk reads the target at +8)");

extern void hv_exit(void);
extern void hv_helper_entry(void);
extern void hv_helper_thunk(void);
extern void hv_chain_thunk(void);
extern void hv_ijc_thunk(void);
extern void hv_xjump_thunk(void);

static int init_rest(HvMachine *m);

int hv_knob[HV_K_COUNT];
static const char *const hv_knob_names[HV_K_COUNT] = {"HV_NO_RAS", "HV_SUPERBLOCKS", "HV_GROUPS", "HV_WFI_SPIN", "HV_FLUSH", "HV_K1", "HV_K2", "HV_K3", "HV_TLBT", "HV_JIT_CAP", "HV_RECHECK", "HV_SYNC_WAIT", "HV_SWITCH_FLUSH", "HV_RANGE_DROP", "HV_MOVIMM", "HV_PREDSTAT", "HV_WALK_LOG", "HV_HOIST_CHECK", "HV_IJC_PAGES", "HV_DNS_PROXY"};

static void knobs_init(void) {
    for (int i = 0; i < HV_K_COUNT; i++)
        hv_knob[i] = getenv(hv_knob_names[i]) ? atoi(getenv(hv_knob_names[i])) : 0;
    if (getenv("HV_NO_RAS") && !*getenv("HV_NO_RAS")) hv_knob[HV_K_NO_RAS] = 1;
    /* HV_SWITCH_FLUSH (skipping the local TLBI VMALLE1 xnu issues right after a process switch) is off unless asked
       since 2026-11-09: a checked skip on the phone found a kept user entry out of date (a stack page, no mapping),
       the stale state that flush exists to retire (xnu reusing a hardware ASID, which can leave every process's kept
       entries stale, not just the incoming one's). It was worth ~3% on a process-spawn loop; not worth guest memory. */
    if (!getenv("HV_IJC_PAGES")) hv_knob[HV_K_IJCPAGES] = 1;
    if (!getenv("HV_DNS_PROXY")) hv_knob[HV_K_DNSPROXY] = 1;
}

int hv_knob_set(HvMachine *m, const char *name, int value) {
    for (int i = 0; i < HV_K_COUNT; i++)
        if (!strcmp(name, hv_knob_names[i])) {
            hv_knob[i] = value;
            __atomic_store_n(&m->flush_pending, 1, __ATOMIC_SEQ_CST);
            hv_machine_kick_all(m);
            return 1;
        }
    return 0;
}

int hv_machine_init(HvMachine *m, size_t jit_bytes) {
    knobs_init(); /* the tests and the Mac tool read the same knobs as the app */
    memset(m, 0, sizeof *m);
    if (hv_jit_region_open(&m->jit, jit_bytes) != 0) return -1;
    return init_rest(m);
}

int hv_machine_init_jit(HvMachine *m, void *rx, void *rw, size_t jit_bytes) {
    knobs_init();
    memset(m, 0, sizeof *m);
    if (hv_jit_region_attach(&m->jit, rx, rw, jit_bytes) != 0) return -1;
    return init_rest(m);
}

/* ---- tables ---- */

static size_t page_bytes(void) {
    static size_t ps;
    if (!ps) ps = (size_t)getpagesize();
    return ps;
}

void *hv_pages_alloc(size_t bytes) {
    if (!bytes) return NULL;
    void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    return p == MAP_FAILED ? NULL : p;
}

void hv_pages_free(void *p, size_t bytes) {
    if (p && bytes) munmap(p, bytes);
}

void hv_pages_zero(void *p, size_t bytes) {
    if (!p || !bytes) return;
    size_t ps = page_bytes();
    uintptr_t a = (uintptr_t)p, e = a + bytes, lo = (a + ps - 1) & ~(uintptr_t)(ps - 1), hi = e & ~(uintptr_t)(ps - 1);
    if (hi <= lo) {
        memset(p, 0, bytes);
        return;
    }
    memset(p, 0, lo - a);
    memset((void *)hi, 0, e - hi);
    /* The kernel keeps the old pages if it refuses the new ones (it puts back what it took): then zero them. */
    if (mmap((void *)lo, hi - lo, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0) == MAP_FAILED)
        memset((void *)lo, 0, hi - lo);
}

/* How many records, slots and buckets a JIT region of jit_bytes gets: as many blocks as it holds at
   HV_BLOCK_MIN_BYTES each (so the code filling, not this, is what evicts), and a bucket per one to two blocks. One
   place for init_rest and hv_machine_table_bytes. */
static void table_counts(size_t jit_bytes, uint32_t *blocks, uint32_t *slots, uint32_t *buckets) {
    size_t n = jit_bytes / HV_BLOCK_MIN_BYTES;
    if (n < 4096) n = 4096;
    *blocks = (uint32_t)n;
    *slots = (uint32_t)n * HV_SLOTS_PER_BLOCK;
    uint32_t b = 4096;
    while ((size_t)b * 2 <= n) b *= 2;
    *buckets = b;
}

/* Per slot: the HV_SLOT pair, slot_xa, then the 32-bit arrays (site, stub, cond, xpa, xnext, xprev). */
#define SLOT_BYTES (2 * sizeof(uint64_t) + sizeof(uint64_t) + 6 * sizeof(uint32_t))
_Static_assert(SLOT_BYTES == 48, "an exit slot: 48 bytes");

static size_t percpu_tables_bytes(void) {
    return (size_t)HV_IJC_TABLES * HV_IJC_TABLE_BYTES + (sizeof(uint64_t) << HV_UCODE_BITS) + 65536 * sizeof(uint64_t[4]) +
           (size_t)HV_STASHES * HV_STASH_CAP * (sizeof(HvTlbEntry) + sizeof(uint16_t));
}

size_t hv_machine_table_bytes(size_t jit_bytes, int ncpus) {
    uint32_t blocks, slots, buckets;
    table_counts(jit_bytes, &blocks, &slots, &buckets);
    if (ncpus < 1) ncpus = 1;
    if (ncpus > HV_MAX_CPUS) ncpus = HV_MAX_CPUS;
    return ((size_t)blocks + 1) * sizeof(HvBlock) + (size_t)slots * SLOT_BYTES + (size_t)buckets * sizeof(uint32_t) +
           hv_cc_table_bytes(blocks) + HV_MAX_CPUS * sizeof(HvPerCpu) + (size_t)ncpus * percpu_tables_bytes();
}

/* A CPU's tables, at its first reset (or before, hv_machine_add_cpus). */
static int percpu_tables(HvPerCpu *p) {
    if (p->tables) return 0;
    size_t bytes = percpu_tables_bytes();
    uint8_t *t = hv_pages_alloc(bytes);
    if (!t) return -1;
    p->tables = t;
    p->tables_bytes = bytes;
    p->ijc = (uint64_t *)(void *)t;
    t += (size_t)HV_IJC_TABLES * HV_IJC_TABLE_BYTES;
    p->ucode = (uint64_t *)(void *)t;
    t += sizeof(uint64_t) << HV_UCODE_BITS;
    p->cid_chunks = (uint64_t (*)[4])(void *)t;
    t += 65536 * sizeof(uint64_t[4]);
    for (int k = 0; k < HV_STASHES; k++, t += HV_STASH_CAP * sizeof(HvTlbEntry)) p->stash[k].ent = (HvTlbEntry *)(void *)t;
    for (int k = 0; k < HV_STASHES; k++, t += HV_STASH_CAP * sizeof(uint16_t)) p->stash[k].slot = (uint16_t *)(void *)t;
    return 0;
}

int hv_machine_add_cpus(HvMachine *m, int n) {
    for (int i = 0; i < n && i < HV_MAX_CPUS; i++)
        if (percpu_tables(&m->percpu[i]) != 0) return -1;
    return 0;
}

static int init_rest(HvMachine *m) {
    hv_kva_init();
    m->percpu = hv_pages_alloc(HV_MAX_CPUS * sizeof *m->percpu);
    if (!m->percpu) return -1;
    pthread_mutex_init(&m->big_mu, NULL);
    pthread_cond_init(&m->big_cv, NULL);
    pthread_mutexattr_t ra;
    pthread_mutexattr_init(&ra);
    pthread_mutexattr_settype(&ra, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&m->dev_mu, &ra);
    pthread_mutexattr_destroy(&ra);
    pthread_mutex_init(&m->tr_mu, NULL);
    pthread_mutex_init(&m->stw_mu, NULL);
    pthread_cond_init(&m->stw_cv, NULL);
    pthread_mutex_init(&m->kick_mu, NULL);
    pthread_cond_init(&m->kick_cv, NULL);
    for (int i = 0; i < HV_MAX_CPUS; i++) {
        pthread_mutex_init(&m->percpu[i].wake_mu, NULL);
        pthread_cond_init(&m->percpu[i].wake_cv, NULL);
        pthread_mutex_init(&m->percpu[i].req_mu, NULL);
    }
    m->locks_initialized = 1;
    /* HV_JIT_CAP (testing): MB of the region to use from the start, not only after the first full flush, so a
       device reaches its full flushes in minutes (henge-env.txt on iOS). */
    if (getenv("HV_JIT_CAP")) hv_knob[HV_K_JITCAP] = atoi(getenv("HV_JIT_CAP"));
    m->jit.limit = hv_knob[HV_K_JITCAP] > 0 ? ((size_t)hv_knob[HV_K_JITCAP] << 20) / sizeof(uint32_t) : 0;
    /* The TLB layout (cpu.h): HV_TLBT from the environment here too, so the Mac tool and the tests can pick it. */
    hv_knob[HV_K_TLBT] = getenv("HV_TLBT") ? atoi(getenv("HV_TLBT")) : 1; /* table-major unless asked: 9-20% faster in 5 of 6 paired rounds of the mix */
    hv_tlb_tmajor = hv_knob[HV_K_TLBT] != 0;
    /* HV_MOVIMM=1: constants built in registers instead of loaded from the pool (translate.c put_lit). Off: no
       measured gain (Mac mix 24.1 s either way, 2026-11-08); the tests pass with it on (HV_MOVIMM=1 make test). */
    hv_knob[HV_K_MOVIMM] = getenv("HV_MOVIMM") ? atoi(getenv("HV_MOVIMM")) : 0;
    /* On unless asked: the Mac bench (2026-11-08) posted 130-400 raced remote drops/s with it against 710-1370
       without (most walks a drop met were of other pages), and the phone's login storm waits up to 24% of a CPU. */
    hv_knob[HV_K_WALKLOG] = getenv("HV_WALK_LOG") ? atoi(getenv("HV_WALK_LOG")) : 1;
    if (getenv("HV_HOIST_CHECK")) hv_knob[HV_K_HOIST] = atoi(getenv("HV_HOIST_CHECK"));
    /* On unless asked: a code change used to drop every CPU's whole branch cache (~100/s with JavaScriptCore's JIT
       on the Mac bench, 300-390K refills/s after); now only the page's targets (Mac 2026-11-09: resets 195 -> 2/s,
       a JIT check of 200 recompiled functions correct; bench times the same within noise). */
    hv_knob[HV_K_IJCPAGES] = getenv("HV_IJC_PAGES") ? atoi(getenv("HV_IJC_PAGES")) : 1;
    hv_knob[HV_K_DNSPROXY] = getenv("HV_DNS_PROXY") ? atoi(getenv("HV_DNS_PROXY")) : 1;
    /* So the tests can run the translator these ways too (the iOS and --phone paths read them in knobs_init). */
    if (getenv("HV_SUPERBLOCKS")) hv_knob[HV_K_SUPERBLOCKS] = atoi(getenv("HV_SUPERBLOCKS"));
    /* The exact check for an access in a page's last 15 bytes, in the access's out-of-line path (code size only):
       on the phone, Golden Gate's boot and login send 80-240K such accesses a second to the helper without it. It
       costs ~13% of the code (Mac 2026-11-09: 296-300 against 259-261 bytes a block), and the phone's code cache
       fills every 40-60 s: worth a phone A/B (HV_RECHECK 0 vs 1 over a login), not a Mac one (~7K such accesses/s). */
    hv_knob[HV_K_RECHECK] = getenv("HV_RECHECK") ? atoi(getenv("HV_RECHECK")) : 1;
    /* Records, slots and buckets for the whole region (table_counts), mapped, so what no block uses costs nothing. */
    uint32_t buckets;
    table_counts(m->jit.capacity * sizeof(uint32_t), &m->max_blocks, &m->max_slots, &buckets);
    m->blocks_bytes = ((size_t)m->max_blocks + 1) * sizeof(HvBlock); /* blocks[0] is never used: index 0 ends a bucket */
    m->blocks = hv_pages_alloc(m->blocks_bytes);
    m->hash_bytes = (size_t)buckets * sizeof *m->hash;
    m->hash = hv_pages_alloc(m->hash_bytes);
    m->hash_mask = buckets - 1;
    m->slots_bytes = (size_t)m->max_slots * SLOT_BYTES;
    uint8_t *s = hv_pages_alloc(m->slots_bytes);
    if (!m->blocks || !m->hash || !s) return -1;
    size_t n = m->max_slots;
    m->slots = (uint64_t *)(void *)s, s += n * 2 * sizeof(uint64_t); /* HV_SLOT: two words each */
    m->slot_xa = (uint64_t *)(void *)s, s += n * sizeof(uint64_t);
    m->slot_site = (uint32_t *)(void *)s, s += n * sizeof(uint32_t);
    m->slot_stub = (uint32_t *)(void *)s, s += n * sizeof(uint32_t);
    m->slot_cond = (uint32_t *)(void *)s, s += n * sizeof(uint32_t);
    m->slot_xpa = (uint32_t *)(void *)s, s += n * sizeof(uint32_t);
    m->slot_xnext = (uint32_t *)(void *)s, s += n * sizeof(uint32_t);
    m->slot_xprev = (uint32_t *)(void *)s;
    if (getenv("HV_JIT_POISON")) { /* debugging: each block's full-flush count, checked as it is entered and chained */
        m->block_jit_gen = hv_pages_alloc(((size_t)m->max_blocks + 1) * sizeof *m->block_jit_gen);
        if (!m->block_jit_gen) return -1;
    }
    m->stop_pc = ~0ull;
    m->stop_pc2 = ~0ull;
    m->chain = 1;
    if (hv_cc_init(m) != 0) return -1; /* the JIT region's segments: after the limit and the tables above */
    return 0; /* each CPU's tables: hv_machine_add_cpus, or its first reset */
}

/* Every CPU paused: the full flush the dispatcher does (stop_the_world), then the tables' pages back. */
int hv_machine_trim(HvMachine *m) {
    for (int i = 0; i < m->ncpus; i++)
        if (m->cpus[i] && __atomic_load_n(&m->percpu[i].active, __ATOMIC_SEQ_CST)) return -1;
    pthread_mutex_lock(&m->tr_mu);
    hv_flush_blocks(m);
    hv_pages_zero(m->blocks, m->blocks_bytes);
    hv_pages_zero(m->hash, m->hash_bytes);
    hv_pages_zero(m->slots, m->slots_bytes);
    if (m->block_jit_gen) hv_pages_zero(m->block_jit_gen, ((size_t)m->max_blocks + 1) * sizeof *m->block_jit_gen);
    hv_cc_trim(m);
    for (int i = 0; i < m->nram; i++) { /* the pages' notes of cached targets: none are left */
        HvRam *r = &m->ram[i];
        hv_pages_zero(r->ijc_va, r->npages * sizeof *r->ijc_va);
    }
    for (int i = 0; i < m->ncpus; i++) {
        HvCpu *c = m->cpus[i];
        HvPerCpu *p = &m->percpu[i];
        if (!c || !p->tables) continue;
        for (int k = 0; k < HV_STASHES; k++) { /* the stashes go with the rest: their entries are refilled as used */
            p->stash[k].ttbr0 = 0;
            p->stash[k].n = 0;
            __atomic_add_fetch(&p->stash[k].gen, 1, __ATOMIC_SEQ_CST);
        }
        hv_pages_zero(p->tables, p->tables_bytes); /* the branch caches (emptied by the flush), ucode, cid_chunks */
        p->ijc_tables_used = 0;
        p->ucode_count = 0;
        p->ijc_keyed_count = 0;
        p->last_fill[0] = p->last_fill[1] = 0;
        hv_pages_zero(p->ijc_keyed, sizeof p->ijc_keyed);
        hv_pages_zero(p->ijc_pages, sizeof p->ijc_pages);
        hv_pages_zero(p->ijc_hint, sizeof p->ijc_hint);
        hv_pages_zero(p->jc, sizeof p->jc);
    }
    pthread_mutex_unlock(&m->tr_mu);
    return 0;
}

__thread HvCpu *hv_self;

_Static_assert(offsetof(HvStats, small_at) % sizeof(uint64_t) == 0, "HvStats: counters first");

/* Only the CPUs there are: a CPU never reset counted nothing, and reading its pages would make them. */
void hv_stats_total(HvMachine *m, HvStats *out) {
    *out = m->stats;
    uint64_t *sum = (uint64_t *)(void *)out;
    for (int i = 0; i < m->ncpus && m->percpu; i++) {
        const uint64_t *c = (const uint64_t *)(const void *)&m->percpu[i].own.stats;
        for (size_t k = 0; k < HV_STATS_COUNTERS; k++) sum[k] += __atomic_load_n(&c[k], __ATOMIC_RELAXED);
    }
}

uint64_t hv_stat_blocks(HvMachine *m) {
    uint64_t n = __atomic_load_n(&m->stats.blocks, __ATOMIC_RELAXED);
    for (int i = 0; i < m->ncpus && m->percpu; i++) n += __atomic_load_n(&m->percpu[i].own.stats.blocks, __ATOMIC_RELAXED);
    return n;
}

uint64_t hv_stat_translations(HvMachine *m) {
    uint64_t n = __atomic_load_n(&m->stats.translations, __ATOMIC_RELAXED);
    for (int i = 0; i < m->ncpus && m->percpu; i++) n += __atomic_load_n(&m->percpu[i].own.stats.translations, __ATOMIC_RELAXED);
    return n;
}

uint64_t hv_stat_slow_mem(HvMachine *m) {
    uint64_t n = 0;
    for (int i = 0; i < m->ncpus && m->percpu; i++) n += __atomic_load_n(&m->percpu[i].own.slow_mem, __ATOMIC_RELAXED);
    return n;
}

/* The guest PC of the access being emulated on this thread's CPU, for logs. */
static uint64_t hv_access_pc(HvMachine *m) {
    HvCpu *self = hv_self;
    return self && self->pc_state ? self->pc_state->own.access_pc : m->access_pc;
}

void hv_dev_lock(HvMachine *m) {
    if (pthread_mutex_trylock(&m->dev_mu) == 0) return;
    uint64_t t0 = m->stats_interval ? mach_absolute_time() : 0;
    pthread_mutex_lock(&m->dev_mu);
    if (m->stats_interval) {
        HvStats *st = hv_stats_here(m);
        st->dev_waits++;
        st->dev_wait_ticks += mach_absolute_time() - t0;
    }
}

void hv_dev_unlock(HvMachine *m) {
    pthread_mutex_unlock(&m->dev_mu);
}

static uint64_t post_locked_done(HvCpu *target, HvPerCpu *p) {
    uint64_t seq = __atomic_add_fetch(&p->req_seq, 1, __ATOMIC_SEQ_CST);
    pthread_mutex_unlock(&p->req_mu);
    __atomic_store_n(&target->exit_req, 1, __ATOMIC_SEQ_CST);
    __asm__ volatile("sev" ::: "memory"); /* a WFE waiting in place (wfe() in dispatch.c) sees it now */
    if (target->m->stats_interval) hv_stats_here(target->m)->kick_src[0]++;
    return seq;
}

uint64_t hv_cpu_post_tlbi(HvCpu *target, uint32_t op1, uint32_t crn, uint32_t crm, uint32_t op2, uint64_t xt) {
    HvPerCpu *p = target->pc_state;
    pthread_mutex_lock(&p->req_mu);
    if (p->nreq < sizeof p->req / sizeof p->req[0]) {
        p->req[p->nreq].op1 = op1, p->req[p->nreq].crn = crn, p->req[p->nreq].crm = crm, p->req[p->nreq].op2 = op2;
        p->req[p->nreq].xt = xt;
        p->nreq++;
    } else {
        p->req_flags |= HV_REQ_TLB_ALL; /* too many queued: drop everything instead */
    }
    return post_locked_done(target, p);
}

/* Code changed in a page whose blocks were cached as branch targets at VA page v (| 2), or v = 1: only the return
   predictions. Too many queued: the whole branch cache instead. */
uint64_t hv_cpu_post_ijc_page(HvCpu *target, uint64_t v) {
    HvPerCpu *p = target->pc_state;
    pthread_mutex_lock(&p->req_mu);
    if (p->nijc_page < sizeof p->ijc_page / sizeof p->ijc_page[0]) p->ijc_page[p->nijc_page++] = v;
    else p->req_flags |= HV_REQ_IJC_RESET;
    return post_locked_done(target, p);
}

uint64_t hv_cpu_post(HvCpu *target, uint32_t flags) {
    HvPerCpu *p = target->pc_state;
    pthread_mutex_lock(&p->req_mu);
    p->req_flags |= flags;
    return post_locked_done(target, p);
}

/* HV_SYNC_WAIT: a CPU waiting for another's acknowledgement sleeps (after a short spin) instead of
   spinning and yielding, so a host core is free for the CPU it waits on: the phone has two fast cores
   for three guest CPUs, the display and the app. The kernel's compare-and-wait on a 32-bit word. */
extern int __ulock_wait(uint32_t operation, void *addr, uint64_t value, uint32_t timeout_us);
extern int __ulock_wake(uint32_t operation, void *addr, uint64_t wake_value);
#define HV_UL_COMPARE_AND_WAIT 1u
#define HV_ULF_WAKE_ALL 0x100u
#define HV_ULF_NO_ERRNO 0x1000000u

/* Wake whoever sleeps on p's ack_seq (it moved, or p stopped using its TLB). */
static void ack_wake(HvPerCpu *p) {
    if (__atomic_load_n(&p->ack_waiters, __ATOMIC_SEQ_CST))
        __ulock_wake(HV_UL_COMPARE_AND_WAIT | HV_ULF_WAKE_ALL | HV_ULF_NO_ERRNO, &p->ack_seq, 0);
}

void hv_cpu_ack_wake(HvCpu *cpu) {
    if (cpu->pc_state) ack_wake(cpu->pc_state);
}

void hv_cpu_process_requests(HvCpu *cpu) {
    HvPerCpu *p = cpu->pc_state;
    uint64_t seq = __atomic_load_n(&p->req_seq, __ATOMIC_ACQUIRE);
    if (seq == __atomic_load_n(&p->ack_seq, __ATOMIC_RELAXED)) return;
    static __thread struct { uint32_t op1, crn, crm, op2; uint64_t xt; } q[64];
    static __thread uint64_t pages[16];
    pthread_mutex_lock(&p->req_mu);
    seq = p->req_seq;
    uint32_t flags = p->req_flags, n = p->nreq, npages = p->nijc_page;
    memcpy(q, p->req, n * sizeof q[0]);
    memcpy(pages, p->ijc_page, npages * sizeof pages[0]);
    p->req_flags = 0;
    p->nreq = 0;
    p->nijc_page = 0;
    pthread_mutex_unlock(&p->req_mu);
    if (flags & HV_REQ_TLB_ALL) {
        HV_ST(cpu).flush_why[7]++;
        hv_tlb_flush(cpu);
    } else {
        for (uint32_t i = 0; i < n; i++) hv_tlbi_apply(cpu, q[i].op1, q[i].crn, q[i].crm, q[i].op2, q[i].xt);
    }
    if (flags & HV_REQ_IJC_RESET) {
        HV_ST(cpu).user_reset_why[5]++; /* code under several VA pages (or more changed pages queued than fit) */
        hv_ijc_reset(cpu, 0);
        hv_ijc_reset(cpu, 1);
    } else {
        for (uint32_t i = 0; i < npages; i++) hv_ijc_drop_code_page(cpu, pages[i]);
    }
    __atomic_store_n(&p->ack_seq, seq, __ATOMIC_RELEASE);
    ack_wake(p);
}

/* A CPU waiting for another's acknowledgement first watches its ack_seq this long (24 MHz ticks: 2 us), in WFE, which a
   store to the word ends at once: acknowledgements often come within microseconds, and the wait neither spins on the
   target's cache line nor sleeps through one (HV_SYNC_WAIT's sleep, or a yield without it, comes after). */
#define HV_SYNC_WATCH 48

static void ack_watch(const uint64_t *ack_seq, uint64_t seen) {
    uint64_t v;
    __asm__ volatile("ldaxr %0, [%1]" : "=r"(v) : "r"(ack_seq) : "memory"); /* arms the monitor: a store to it ends the WFE */
    if (v == seen) {
        if (__atomic_load_n(&hv_light_flags, __ATOMIC_RELAXED) & HV_LIGHT_WFE_SLEEP) __asm__ volatile("wfe" ::: "memory");
        else __asm__ volatile("yield" ::: "memory"); /* no event stream to end a WFE (or not measured yet: light_init) */
    }
    __asm__ volatile("clrex" ::: "memory");
}

void hv_cpu_sync(HvCpu *self, HvCpu *target, uint64_t seq) {
    HvPerCpu *t = target->pc_state, *s = self ? self->pc_state : NULL;
    HvMachine *mm = target->m;
    HvStats *st = s ? &s->own.stats : &mm->stats;
    uint64_t t0 = mm->stats_interval ? mach_absolute_time() : 0;
    if (s) {
        __atomic_store_n(&s->tlb_live, 0, __ATOMIC_SEQ_CST); /* others need not wait for this one meanwhile */
        ack_wake(s);
    }
    int sleep = hv_knob[HV_K_SYNCWAIT], probed = !t0 || !mm->stats_deep, probed_long = probed; /* thread_info: diagnostics only */
    if (s) __atomic_store_n(&s->phase, HV_PHASE_SYNC, __ATOMIC_RELAXED);
    uint64_t watch_end = 0;
    for (uint32_t spins = 0;; spins++) {
        uint64_t ack = __atomic_load_n(&t->ack_seq, __ATOMIC_ACQUIRE);
        if (ack >= seq) break;
        if (!probed && !(spins & 63) && mach_absolute_time() - t0 >= 2400) { /* 100 us: what is it doing? */
            probed = 1;
            thread_basic_info_data_t ti;
            mach_msg_type_number_t cnt = THREAD_BASIC_INFO_COUNT;
            int on = !t->thread || (thread_info(t->thread, THREAD_BASIC_INFO, (thread_info_t)&ti, &cnt) == KERN_SUCCESS && ti.run_state == TH_STATE_RUNNING);
            st->sync_probe[on ? 1 : 0]++;
            if (__atomic_load_n(&t->walk_seq, __ATOMIC_RELAXED) & 1) st->sync_probe[2]++;
            if (__atomic_load_n(&t->ijc_seq, __ATOMIC_RELAXED) & 1) st->sync_probe[3]++;
        }
        if (probed && !probed_long && !(spins & 63) && mach_absolute_time() - t0 >= 24000) { /* 1 ms */
            probed_long = 1;
            thread_basic_info_data_t ti;
            mach_msg_type_number_t cnt = THREAD_BASIC_INFO_COUNT;
            int on = !t->thread || (thread_info(t->thread, THREAD_BASIC_INFO, (thread_info_t)&ti, &cnt) == KERN_SUCCESS && ti.run_state == TH_STATE_RUNNING);
            st->sync_phase[on ? __atomic_load_n(&t->phase, __ATOMIC_RELAXED) % 5 : 5]++;
        }
        if (!__atomic_load_n(&t->tlb_live, __ATOMIC_SEQ_CST)) break; /* parked: it does the work before it runs again */
        if (self) hv_cpu_process_requests(self);
        uint64_t now = mach_absolute_time();
        if (!watch_end) watch_end = now + HV_SYNC_WATCH;
        if (now < watch_end) {
            ack_watch(&t->ack_seq, ack);
        } else if (sleep) {
            __atomic_add_fetch(&t->ack_waiters, 1, __ATOMIC_SEQ_CST);
            /* Asleep until ack_seq's low word moves or 100 us pass (a missed wake costs no more than that). */
            if (__atomic_load_n(&t->ack_seq, __ATOMIC_SEQ_CST) == ack && __atomic_load_n(&t->tlb_live, __ATOMIC_SEQ_CST))
                __ulock_wait(HV_UL_COMPARE_AND_WAIT | HV_ULF_NO_ERRNO, &t->ack_seq, (uint32_t)ack, 100);
            __atomic_sub_fetch(&t->ack_waiters, 1, __ATOMIC_SEQ_CST);
        } else {
            sched_yield();
        }
    }
    if (s) {
        __atomic_store_n(&s->tlb_live, 1, __ATOMIC_SEQ_CST);
        hv_cpu_process_requests(self); /* anything that came in while we were not live */
        __atomic_store_n(&s->phase, HV_PHASE_HELPER, __ATOMIC_RELAXED); /* TLBIs are waited for from a helper */
    }
    if (mm->stats_interval) {
        uint64_t dt = mach_absolute_time() - t0;
        int b = dt < 240 ? 0 : dt < 2400 ? 1 : dt < 24000 ? 2 : 3; /* 24 MHz ticks */
        st->syncs++;
        st->sync_ticks += dt;
        st->sync_len[b]++;
        st->sync_len_ticks[b] += dt;
    }
}

void hv_big_lock(HvMachine *m) {
    if (!m->big_lock_on) return;
    pthread_mutex_lock(&m->big_mu);
    uint64_t me = m->big_next++;
    while (m->big_serving != me) pthread_cond_wait(&m->big_cv, &m->big_mu);
    pthread_mutex_unlock(&m->big_mu);
}

void hv_big_unlock(HvMachine *m) {
    if (!m->big_lock_on) return;
    pthread_mutex_lock(&m->big_mu);
    m->big_serving++;
    pthread_cond_broadcast(&m->big_cv);
    pthread_mutex_unlock(&m->big_mu);
}

void hv_big_yield(HvMachine *m) {
    if (!m->big_lock_on) return;
    pthread_mutex_lock(&m->big_mu);
    int waiting = m->big_next - m->big_serving > 1;
    pthread_mutex_unlock(&m->big_mu);
    if (!waiting) return;
    hv_big_unlock(m);
    hv_big_lock(m);
}

/* Make cpu leave its block at its next checked exit (and end an in-place WFE wait). */
void hv_cpu_kick(HvCpu *cpu) {
    __atomic_store_n(&cpu->exit_req, 1, __ATOMIC_SEQ_CST);
    __asm__ volatile("sev" ::: "memory");
}

/* Return tables: nothing to return to. A tag is never 0: salts are not, and no VA has their bits. */
void hv_ret_clear(HvCpu *cpu) {
    memset(cpu->ret_tab, 0, sizeof cpu->ret_tab);
    cpu->ret_salt[0] = cpu->ret_salt[1] = 1ull << 48;
}

void hv_cpu_wake(HvCpu *cpu) {
    HvPerCpu *pw = cpu->pc_state;
    __atomic_store_n(&pw->poll_req, 1, __ATOMIC_SEQ_CST); /* for CPU 0: its tick polls the devices (vmapple.c) */
    __atomic_store_n(&cpu->exit_req, 1, __ATOMIC_SEQ_CST);
    __asm__ volatile("sev" ::: "memory");
    if (cpu->m->stats_interval) hv_stats_here(cpu->m)->kick_src[1]++;
    HvPerCpu *p = cpu->pc_state;
    pthread_mutex_lock(&p->wake_mu);
    p->wake_pending = 1;
    pthread_cond_signal(&p->wake_cv);
    pthread_mutex_unlock(&p->wake_mu);
}

void hv_machine_kick_all(HvMachine *m) {
    if (m->stats_interval) hv_stats_here(m)->kick_src[2]++;
    for (int i = 0; i < m->ncpus; i++)
        if (m->cpus[i]) __atomic_store_n(&m->cpus[i]->exit_req, 1, __ATOMIC_SEQ_CST);
    __asm__ volatile("sev" ::: "memory");
}

void hv_machine_halt(HvMachine *m, enum HvHaltReason reason) {
    for (int i = 0; i < m->ncpus; i++) if (m->cpus[i]) {
        /* CPU_ON resets a parked CPU under this lock. It must not erase a
           terminal halt while another CPU is shutting the machine down. */
        HvPerCpu *p = m->cpus[i]->pc_state;
        pthread_mutex_lock(&p->wake_mu);
        int running = HV_HALT_NONE;
        atomic_compare_exchange_strong(&m->cpus[i]->halted, &running, reason);
        pthread_mutex_unlock(&p->wake_mu);
    }
    /* CPU_OFF sleeps on wake_cv without a timeout. exit_req/SEV alone only
       interrupts translated code and cannot release that condition wait. */
    for (int i = 0; i < m->ncpus; i++)
        if (m->cpus[i]) hv_cpu_wake(m->cpus[i]);
}

/* Device work is for CPU 0, which polls the devices. */
void hv_machine_wake(HvMachine *m) {
    if (m->stats_interval) hv_stats_here(m)->kick_src[3]++;
    if (m->cpu) hv_cpu_wake(m->cpu);
}

void hv_machine_kicker_poke(HvMachine *m) {
    pthread_mutex_lock(&m->kick_mu);
    m->kick_poked = 1;
    pthread_cond_signal(&m->kick_cv);
    pthread_mutex_unlock(&m->kick_mu);
}

/* A CPU's deadline (timer_due, stored before this with SEQ_CST) came in. The kicker stores kick_at, then looks at the
   deadlines once more before it sleeps: either it sees this one, or this sees its kick_at (or 0 while it looks). */
void hv_kicker_note(HvMachine *m, uint64_t due) {
    if (!due || !__atomic_load_n(&m->kicker_on, __ATOMIC_SEQ_CST)) return;
    uint64_t at = __atomic_load_n(&m->kick_at, __ATOMIC_SEQ_CST);
    if (at && due + HV_KICK_SLACK >= at) return; /* it is awake by then anyway */
    hv_machine_kicker_poke(m);
}

void hv_cpu_set_due(HvCpu *cpu, uint64_t due) {
    __atomic_store_n(&cpu->timer_due, due, __ATOMIC_SEQ_CST);
    hv_kicker_note(cpu->m, due);
}

/* The running CPUs' deadlines: kick those due (once per deadline), and return when to look again: the earliest
   other deadline, CPU 0's next device poll, the safety kick, at most HV_KICK_CAP away. With none running: a little
   after the first parked one's WFI ends by itself (it may run on then; one woken earlier says so, see unpark), at
   most HV_KICK_IDLE away. *running: how many run. */
static uint64_t kicker_pass(HvMachine *m, uint64_t now, uint64_t *kicked, uint64_t *poll, uint64_t safety, int kick, int *running) {
    uint64_t wake = now + HV_KICK_CAP, idle = now + HV_KICK_IDLE;
    *running = 0;
    for (int i = 0; i < m->ncpus && i < HV_MAX_CPUS; i++) {
        HvCpu *c = __atomic_load_n(&m->cpus[i], __ATOMIC_ACQUIRE);
        if (!c) continue;
        if (!__atomic_load_n(&m->percpu[i].active, __ATOMIC_SEQ_CST)) {
            uint64_t until = __atomic_load_n(&m->percpu[i].wfi_until, __ATOMIC_SEQ_CST);
            if (until && until + HV_KICK_CAP > now && until + HV_KICK_CAP < idle) idle = until + HV_KICK_CAP;
            continue;
        }
        ++*running;
        uint64_t due = __atomic_load_n(&c->timer_due, __ATOMIC_SEQ_CST);
        if (due && due <= now) {
            if (kick && due != kicked[i]) {
                kicked[i] = due;
                hv_cpu_kick(c);
                m->stats.kicker_kicks++;
            }
        } else if (due && due < wake) {
            wake = due;
        }
        if (i == 0) { /* CPU 0 polls the devices while it runs, for work no device signals (vmapple.c) */
            if (kick && now >= *poll) {
                __atomic_store_n(&m->percpu[0].poll_req, 1, __ATOMIC_SEQ_CST);
                hv_cpu_kick(c);
                *poll = now + HV_POLL_BUSY;
                m->stats.kicker_polls++;
            }
            if (*poll < wake) wake = *poll;
        }
    }
    if (!*running) return idle;
    return safety < wake ? safety : wake;
}

/* Instead of every CPU every millisecond: each running CPU when its own deadline is due, CPU 0 for its device polls,
   all of them every HV_KICK_SAFETY. With every CPU asleep in WFI (they wake themselves at their deadlines) it looks
   only after one wakes. */
void hv_machine_kicker(HvMachine *m, _Atomic int *stop) {
    uint64_t kicked[HV_MAX_CPUS] = {0};
    uint64_t now = mach_absolute_time();
    uint64_t safety = now + HV_KICK_SAFETY, poll = now + HV_POLL_BUSY;
    __atomic_store_n(&m->kicker_on, 1, __ATOMIC_SEQ_CST);
    while (!atomic_load(stop)) {
        now = mach_absolute_time();
        if (now >= safety) {
            hv_machine_kick_all(m);
            safety = now + HV_KICK_SAFETY;
        }
        if (!__atomic_load_n(&m->percpu[0].active, __ATOMIC_SEQ_CST)) poll = now + HV_POLL_BUSY; /* asleep: its own tick polls */
        int running;
        uint64_t wake = kicker_pass(m, now, kicked, &poll, safety, 1, &running);
        __atomic_store_n(&m->kick_at, wake, __ATOMIC_SEQ_CST);
        /* Once more, as a CPU's deadline or a CPU coming back may have been missed by the pass (see hv_kicker_note). */
        int running2;
        uint64_t wake2 = kicker_pass(m, now, kicked, &poll, safety, 0, &running2);
        pthread_mutex_lock(&m->kick_mu);
        if (!m->kick_poked && !atomic_load(stop) && running2 <= running && wake2 + HV_KICK_SLACK >= wake) {
            uint64_t t = mach_absolute_time(), left = wake > t ? wake - t : 0;
            if (left) {
                struct timespec ts = {(time_t)(left / 24000000), (long)(left % 24000000) * 1000 / 24};
                pthread_cond_timedwait_relative_np(&m->kick_cv, &m->kick_mu, &ts);
            }
        }
        m->kick_poked = 0;
        __atomic_store_n(&m->kick_at, 0, __ATOMIC_SEQ_CST);
        pthread_mutex_unlock(&m->kick_mu);
        m->stats.kicker_wakes++;
    }
    __atomic_store_n(&m->kicker_on, 0, __ATOMIC_SEQ_CST);
}

void hv_machine_free(HvMachine *m) {
    hv_jit_region_close(&m->jit);
    for (int i = 0; i < m->nram; i++) {
        free(m->ram[i].code_pages);
        free(m->ram[i].page_gen);
        free(m->ram[i].whint);
        hv_pages_free(m->ram[i].ijc_va, m->ram[i].npages * sizeof *m->ram[i].ijc_va);
        hv_pages_free(m->ram[i].xhead, m->ram[i].npages * sizeof *m->ram[i].xhead);
        free(m->ram[i].code_hash);
    }
    hv_pages_free(m->blocks, m->blocks_bytes);
    hv_pages_free(m->hash, m->hash_bytes);
    hv_pages_free(m->slots, m->slots_bytes);
    hv_pages_free(m->block_jit_gen, ((size_t)m->max_blocks + 1) * sizeof *m->block_jit_gen);
    for (int i = 0; i < HV_MAX_CPUS && m->percpu; i++) {
        HvPerCpu *p = &m->percpu[i];
        /* hv_run keeps a thread send right for statistics; CPU workers have ended. */
        if (p->thread) mach_port_deallocate(mach_task_self(), p->thread);
        hv_pages_free(p->tables, p->tables_bytes);
        if (m->locks_initialized) {
            pthread_mutex_destroy(&p->wake_mu);
            pthread_cond_destroy(&p->wake_cv);
            pthread_mutex_destroy(&p->req_mu);
        }
    }
    hv_pages_free(m->percpu, HV_MAX_CPUS * sizeof *m->percpu);
    hv_cc_free(m);
    if (m->locks_initialized) {
        pthread_mutex_destroy(&m->big_mu);
        pthread_cond_destroy(&m->big_cv);
        pthread_mutex_destroy(&m->dev_mu);
        pthread_mutex_destroy(&m->tr_mu);
        pthread_mutex_destroy(&m->stw_mu);
        pthread_cond_destroy(&m->stw_cv);
        pthread_mutex_destroy(&m->kick_mu);
        pthread_cond_destroy(&m->kick_cv);
    }
    memset(m, 0, sizeof *m);
}

int hv_machine_add_ram(HvMachine *m, uint64_t pa, uint64_t size, void *host, int readonly) {
    size_t pages = (size + (1u << HV_TLB_PAGE_BITS) - 1) >> HV_TLB_PAGE_BITS;
    if (m->nram == HV_MAX_RAM || pages >= (1u << 28)) return -1; /* hv_xpa: 28 bits of page (4 TB) */
    HvRam *r = &m->ram[m->nram++];
    r->pa = pa;
    r->size = size;
    r->host = host;
    r->readonly = readonly;
    r->pages_log2 = 0;
    while ((1ull << r->pages_log2) < pages) r->pages_log2++;
    /* A power of two, so translated code bounds-checks a page index with one shift (IC IVAU). */
    r->code_pages = calloc((size_t)1 << r->pages_log2, 1);
    if (!m->main_ram || size > m->main_ram->size) m->main_ram = r;
    r->page_gen = calloc(pages, sizeof *r->page_gen);
    r->npages = pages;
    r->whint = calloc(pages * HV_MAX_CPUS, sizeof *r->whint);
    r->ijc_va = hv_pages_alloc(pages * sizeof *r->ijc_va); /* given back by hv_machine_trim, xhead by a full flush */
    r->xhead = hv_pages_alloc(pages * sizeof *r->xhead);
    r->code_hash = getenv("HV_CODE_CHECK") ? calloc(pages, sizeof *r->code_hash) : NULL;
    return r->code_pages && r->page_gen && r->whint && r->ijc_va && r->xhead ? 0 : -1;
}

int hv_machine_add_mmio(HvMachine *m, uint64_t pa, uint64_t size, void *opaque,
                        uint64_t (*read)(void *, uint64_t, unsigned),
                        void (*write)(void *, uint64_t, uint64_t, unsigned), const char *name) {
    if (m->nmmio == HV_MAX_MMIO) return -1;
    m->mmio[m->nmmio++] = (HvMmio){pa, size, opaque, read, write, name, 0};
    return 0;
}

HvRam *hv_ram_lookup(HvMachine *m, uint64_t pa) {
    for (int i = 0; i < m->nram; i++) {
        HvRam *r = &m->ram[i];
        if (pa - r->pa < r->size) return r;
    }
    return NULL;
}

uint32_t *hv_smc_counts;
uint64_t *hv_smc_last;
uint64_t hv_smc_pages, hv_smc_cpu, hv_smc_dma;

void hv_invalidate_code(HvMachine *m, uint64_t pa) {
    HvRam *r = hv_ram_lookup(m, pa);
    if (!r) return;
    uint64_t pg = (pa - r->pa) >> HV_TLB_PAGE_BITS;
    if (!r->code_pages[pg]) return;
    /* Blocks remember the generation they were made under; a stale one is
       retranslated the next time it is looked up. The block running now may
       finish with the old code, as it would with a real instruction pipeline. */
    r->code_pages[pg] = 0;
    __atomic_add_fetch(&r->page_gen[pg], 1, __ATOMIC_SEQ_CST);
    m->stats.flush_smc++;
    if (hv_smc_counts && pg < hv_smc_pages) {
        hv_smc_counts[pg]++;
        uint64_t caller = hv_self ? hv_self->pc : 0;
        hv_smc_last[pg] = caller;
        if (hv_self) hv_smc_cpu++;
        else hv_smc_dma++;
    }
    /* Exits from other pages chained into the stale blocks go back to their stub
       (whose next chain finds the new translation). Under the translation lock,
       as chaining them is: one that saw the old generation is done by now. */
    pthread_mutex_lock(&m->tr_mu);
    for (uint32_t k = r->xhead[pg]; k;) {
        uint32_t idx = k - 1;
        k = m->slot_xnext[idx];
        m->slot_xnext[idx] = m->slot_xprev[idx] = 0;
        m->slot_xpa[idx] = 0;
        __atomic_store_n(HV_SLOT(m, idx), 0, __ATOMIC_RELEASE);
        uint32_t *site = hv_jit_word(m, m->slot_site[idx]);
        if (site) {
            uint32_t insn = 0x14000000u | (uint32_t)((hv_jit_word(m, m->slot_stub[idx]) - site) & 0x3ffffff); /* back to its stub */
            hv_jit_write(&m->jit, site, &insn, 4);
            hv_jit_finish(&m->jit, site, 1);
        }
        m->nxchained--;
    }
    r->xhead[pg] = 0;
    pthread_mutex_unlock(&m->tr_mu);
    /* The indirect-branch cache may lead into the stale blocks: drop those entries (or, without HV_IJC_PAGES, the
       whole cache), here at once and on the other CPUs before they next leave a block (their cache lookups and
       chained exits check exit_req first). Which entries: the page's blocks were cached under one VA page (ijc_va,
       read after the generation went up; a fill notes its page before checking the generation, see
       hv_ijc_fill_checked), so only that page's; under none, only the return predictions go; under several, all. */
    uint64_t v = __atomic_exchange_n(&r->ijc_va[pg], 0, __ATOMIC_SEQ_CST);
    if (!hv_knob[HV_K_IJCPAGES]) v = ~0ull;
    if (m->stats_interval) hv_stats_here(m)->code_ijc[!v ? 0 : v == ~0ull ? 2 : 1]++;
    if (!v) v = 1;
    for (int i = 0; i < m->ncpus; i++) {
        HvCpu *c = m->cpus[i];
        if (!c) continue;
        /* Only a CPU may reset its own cache; from any other thread (a device,
           or no CPU running yet) it is a request, or a running CPU could read a
           half-written entry and jump into the wrong code. */
        if (c == hv_self) {
            if (v == ~0ull) {
                if (c->pc_state) HV_ST(c).user_reset_why[5]++;
                hv_ijc_reset(c, 0);
                hv_ijc_reset(c, 1);
            } else {
                hv_ijc_drop_code_page(c, v);
            }
        } else if (v == ~0ull) {
            hv_cpu_post(c, HV_REQ_IJC_RESET);
        } else {
            hv_cpu_post_ijc_page(c, v);
        }
    }
    hv_stats_here(m)->reset_why[4]++;
    /* Make a running chain leave (chains stay patched: see chain() in dispatch.c). */
    hv_machine_kick_all(m);
}

void hv_dma_written(HvMachine *m, uint64_t pa, uint64_t len) {
    HvRam *r = hv_ram_lookup(m, pa);
    if (!r || !len || pa + len - r->pa > r->size) return;
    uint64_t first = (pa - r->pa) >> HV_TLB_PAGE_BITS, last = (pa + len - 1 - r->pa) >> HV_TLB_PAGE_BITS;
    for (uint64_t pg = first; pg <= last; pg++)
        if (__atomic_load_n(&r->code_pages[pg], __ATOMIC_ACQUIRE)) hv_invalidate_code(m, r->pa + (pg << HV_TLB_PAGE_BITS));
}

static uint64_t page_hash(const uint8_t *page) {
    const uint64_t *w = (const uint64_t *)page;
    uint64_t h = 0x9e3779b97f4a7c15ull;
    for (size_t i = 0; i < (1u << HV_TLB_PAGE_BITS) / 8; i++) h = (h ^ w[i]) * 0x100000001b3ull + (h >> 29);
    return h | 1; /* 0: not noted */
}

void hv_code_check_note(HvRam *ram, uint64_t pg) {
    if (ram->code_hash && pg < ram->npages) __atomic_store_n(&ram->code_hash[pg], page_hash(ram->host + (pg << HV_TLB_PAGE_BITS)), __ATOMIC_RELAXED);
}

void hv_code_check_all(HvMachine *m) {
    static int told;
    uint64_t checked = 0;
    for (int i = 0; i < m->nram; i++) {
        HvRam *r = &m->ram[i];
        if (!r->code_hash) continue;
        for (uint64_t pg = 0; pg < r->npages; pg++) {
            if (!r->code_pages[pg] || !r->code_hash[pg]) continue;
            checked++;
            const uint8_t *page = r->host + (pg << HV_TLB_PAGE_BITS);
            uint64_t h = page_hash(page);
            if (h == r->code_hash[pg]) continue;
            r->code_hash[pg] = h;
            if (told++ >= 100) continue;
            const uint32_t *w = (const uint32_t *)page;
            uint32_t ff = 0;
            for (uint32_t k = 0; k < (1u << HV_TLB_PAGE_BITS) / 4; k++) ff += w[k] >> 24 == 0xff;
            fprintf(stderr, "hengevm: code check: page pa %llx changed with its translations kept (flush %llu): %u of 4096 words "
                            "start with ff; at +0:", (unsigned long long)(r->pa + (pg << HV_TLB_PAGE_BITS)),
                    (unsigned long long)m->stats.block_flushes, ff);
            for (int k = 0; k < 8; k++) fprintf(stderr, " %08x", w[k]);
            fprintf(stderr, "\n");
        }
    }
    static uint64_t last_report;
    if (m->stats.block_flushes - last_report >= 20) {
        last_report = m->stats.block_flushes;
        fprintf(stderr, "hengevm: code check: %llu code pages checked at flush %llu\n", (unsigned long long)checked,
                (unsigned long long)m->stats.block_flushes);
    }
}

HvMmio *hv_mmio_lookup(HvMachine *m, uint64_t pa) {
    for (int i = 0; i < m->nmmio; i++) {
        HvMmio *d = &m->mmio[i];
        if (pa - d->pa < d->size) return d;
    }
    return NULL;
}

void *hv_phys_ptr(HvMachine *m, uint64_t pa, uint64_t len) {
    HvRam *r = hv_ram_lookup(m, pa);
    if (!r || pa + len - r->pa > r->size) return NULL;
    return r->host + (pa - r->pa);
}

/* MMIO is accessed in naturally sized pieces of at most 8 bytes. */
int hv_phys_read(HvMachine *m, uint64_t pa, void *buf, unsigned len) {
    void *p = hv_phys_ptr(m, pa, len);
    if (p) {
        memcpy(buf, p, len);
        return 0;
    }
    HvMmio *d = hv_mmio_lookup(m, pa);
    if (!d || len > 8) return -1;
    if (!d->self_locked) hv_dev_lock(m);
    uint64_t v = d->read ? d->read(d->opaque, pa - d->pa, len) : 0;
    if (!d->self_locked) hv_dev_unlock(m);
    memcpy(buf, &v, len);
    if (m->log >= 3)
        fprintf(stderr, "mmio read  %s+%llx size %u = %llx pc %llx\n", d->name, (unsigned long long)(pa - d->pa), len,
                (unsigned long long)v, (unsigned long long)hv_access_pc(m));
    return 0;
}

int hv_phys_write(HvMachine *m, uint64_t pa, const void *buf, unsigned len) {
    HvRam *r = hv_ram_lookup(m, pa);
    if (r && pa + len - r->pa <= r->size) {
        if (r->readonly) return 0; /* ROM: writes are ignored */
        uint64_t off = pa - r->pa;
        uint64_t first = off >> HV_TLB_PAGE_BITS, last = (off + len - 1) >> HV_TLB_PAGE_BITS;
        for (uint64_t pg = first; pg <= last; pg++)
            if (r->code_pages[pg]) hv_invalidate_code(m, r->pa + (pg << HV_TLB_PAGE_BITS)); /* a write to code */
        if (m->watch_pa && m->watch_pa - pa < len) {
            uint64_t v = 0;
            memcpy(&v, (const uint8_t *)buf + (m->watch_pa - pa), len - (m->watch_pa - pa) < 8 ? len - (m->watch_pa - pa) : 8);
            fprintf(stderr, "hengevm: watch: write to pa %llx = %llx (%u bytes at pa %llx) by pc %llx\n",
                    (unsigned long long)m->watch_pa, (unsigned long long)v, len, (unsigned long long)pa,
                    (unsigned long long)hv_access_pc(m));
        }
        memcpy(r->host + off, buf, len);
        return 0;
    }
    HvMmio *d = hv_mmio_lookup(m, pa);
    if (!d || len > 8) return -1;
    uint64_t v = 0;
    memcpy(&v, buf, len);
    if (m->log >= 3)
        fprintf(stderr, "mmio write %s+%llx size %u = %llx pc %llx\n", d->name, (unsigned long long)(pa - d->pa), len,
                (unsigned long long)v, (unsigned long long)hv_access_pc(m));
    if (!d->self_locked) hv_dev_lock(m);
    if (d->write) d->write(d->opaque, pa - d->pa, v, len);
    if (!d->self_locked) hv_dev_unlock(m);
    return 0;
}

void hv_cpu_reset(HvCpu *cpu, HvMachine *m) {
    hv_cpu_reset_index(cpu, m, 0);
}

void hv_cpu_reset_index(HvCpu *cpu, HvMachine *m, uint32_t index) {
    /* Everything but m and pc_state: other CPUs' TLBIs read those of a CPU
       being started (PSCI CPU_ON) at any time. */
    _Static_assert(offsetof(HvCpu, m) < offsetof(HvCpu, pc_state), "HvCpu layout");
    size_t a = offsetof(HvCpu, m), b = offsetof(HvCpu, pc_state);
    memset(cpu, 0, a);
    memset((char *)cpu + a + sizeof cpu->m, 0, b - a - sizeof cpu->m);
    memset((char *)cpu + b + sizeof cpu->pc_state, 0, sizeof *cpu - b - sizeof cpu->pc_state);
    HvPerCpu *p = &m->percpu[index];
    /* Its tables before other CPUs can see it (they read them for TLBIs); made at the board's start
       (hv_machine_add_cpus) unless a test resets the CPU first. */
    if (percpu_tables(p) != 0) {
        fprintf(stderr, "hengevm: no memory for cpu %u's tables\n", index);
        abort();
    }
    cpu->m = m;
    cpu->index = index;
    cpu->cntvoff = m->cntvoff;
    cpu->pc_state = p;
    m->cpus[index] = cpu;
    if (m->ncpus <= (int)index) m->ncpus = (int)index + 1;
    if (index == 0) m->cpu = cpu;
    /* Ids start over, so entries tagged with the old ones must go. */
    for (int t = 0; t < HV_IJC_TABLES; t++)
        if (p->ijc_tables_used >> t & 1) hv_pages_zero(p->ijc + (size_t)t * (HV_IJC_TABLE_BYTES / 8), HV_IJC_TABLE_BYTES);
    p->ijc_tables_used = 0;
    hv_pages_zero(p->ijc_keyed, sizeof p->ijc_keyed);
    p->ijc_keyed_count = 0;
    memset(p->ijc_pages, 0, sizeof p->ijc_pages);
    memset(p->ijc_hint, 0, sizeof p->ijc_hint);
    hv_pages_zero(p->jc, sizeof p->jc);
    cpu->ijc = (uint64_t)(uintptr_t)p->ijc;
    cpu->lines_ptr = (uint64_t)(uintptr_t)&p->irq_line;
    for (int t = 0; t < HV_IJC_TABLES; t++) cpu->ijc_tab[t] = (uint64_t)(uintptr_t)(p->ijc + (size_t)t * (HV_IJC_TABLE_BYTES / 8));
    hv_ret_clear(cpu);
    cpu->next_cid = 1;
    cpu->kernel_gen = 1;
    cpu->ijc_salt[1] = 1ull << 48; /* tags of an all-zero table never match */
    hv_ijc_switch(cpu);
    cpu->exit_routine = (uint64_t)hv_exit;
    cpu->helper_routine = (uint64_t)hv_helper_entry;
    cpu->helper_thunk = (uint64_t)hv_helper_thunk;
    cpu->chain_thunk = (uint64_t)hv_chain_thunk;
    cpu->ijc_thunk = (uint64_t)hv_ijc_thunk;
    cpu->xjump_thunk = (uint64_t)hv_xjump_thunk;
    cpu->el = 1;
    cpu->spsel = 1;
    cpu->daif = HV_PSTATE_DAIF;
    cpu->excl_addr = ~0ull;
    /* Architectural reset value has the MMU and caches off; RES1 bits set. */
    cpu->sctlr_el1 = 0x30d00980; /* RES1 bits, and ITD and SED, which read as 1 without AArch32 at EL0 */
    cpu->nkernel_fills = HV_KERNEL_FILLS + 1; /* nothing is logged yet: make every entry invalid */
    hv_tlb_flush(cpu);
}
