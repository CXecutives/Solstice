// The segmented code cache under constant eviction (core/codecache.c): a code cache of 1-2 MB (HV_JIT_CAP) for some
// 4 MB of translated code a round, with HV_JIT_POISON, so a segment that is freed is zeroed (a stale jump into it faults
// at once) and checked to be unreachable (exits, the hash, the front caches). One CPU, then three on their own threads
// running at once: chaining, posting TLBIs to each other, waiting for room; with code changes from another thread and
// full flushes and the stats line in between in one of the runs, and the phone's sleeping TLBI waits in another. Every
// run's x0 must be the native run's, and the cache must have gone round hundreds of times.
#include "harness.h"

#include <mach/mach_time.h>
#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>

DECLARE_PROGRAM(ccstress);
extern const char codecache_programs_begin[], codecache_programs_finish[];

#define ROUNDS 2 /* per run: each CPU starts over often (parked in between) */

static const TestProgram prog = TEST_PROGRAM(ccstress);
static HvMachine m;
static int stop;

typedef struct {
    HvCpu *cpu;
    uint64_t seed, want, sp;
    uint64_t runs, bad;
    pthread_t th;
} Worker;

static void *worker(void *arg) {
    Worker *w = arg;
    HvCpu *cpu = w->cpu;
    while (!__atomic_load_n(&stop, __ATOMIC_ACQUIRE)) {
        cpu->x[0] = w->seed;
        cpu->x[20] = 1; /* TLBIs too */
        cpu->x[21] = ROUNDS;
        cpu->sp = w->sp;
        cpu->pc = (uint64_t)(uintptr_t)prog.start;
        int r = hv_run(cpu);
        if (r != HV_EXIT_HALT) {
            printf("  cpu %u: dispatcher returned %d at pc %llx (insn %08x), run %llu\n", cpu->index, r,
                   (unsigned long long)cpu->pc, cpu->exit_insn, (unsigned long long)w->runs);
            w->bad++;
            break;
        }
        if (cpu->x[0] != w->want) {
            printf("  cpu %u: run %llu: x0 %016llx, native %016llx\n", cpu->index, (unsigned long long)w->runs,
                   (unsigned long long)cpu->x[0], (unsigned long long)w->want);
            w->bad++;
        }
        w->runs++;
    }
    return NULL;
}

/* Like a device writing guest memory: a program page's translations dropped now and then, from outside the CPUs. */
static void *code_changer(void *arg) {
    uint64_t *count = arg, x = 88172645463325252ull;
    uint64_t lo = (uint64_t)(uintptr_t)codecache_programs_begin, n = ((uint64_t)(uintptr_t)codecache_programs_finish - lo) >> 14;
    while (!__atomic_load_n(&stop, __ATOMIC_ACQUIRE)) {
        x ^= x << 13, x ^= x >> 7, x ^= x << 17;
        hv_invalidate_code(&m, lo + ((x % n) << 14));
        (*count)++;
        usleep(20000);
    }
    return NULL;
}

static double now_s(void) {
    return (double)mach_absolute_time() / 24e6;
}

enum {
    RUN_CHANGES = 1,   /* code changes from another thread, and two full flushes */
    RUN_STATS = 2,     /* the stats line every 2 s (its counters and the code-cache line) */
    RUN_SYNC_WAIT = 4, /* TLBI waits asleep, as on the phone (HV_SYNC_WAIT=1) */
};

/* One run: cap_mb of code cache, ncpu CPUs, until want_laps times round (at least min_laps) or max_s seconds. */
static int run(const char *name, int cap_mb, int ncpu, int opts, double min_laps, double want_laps, double max_s) {
    char cap[16];
    snprintf(cap, sizeof cap, "%d", cap_mb);
    setenv("HV_JIT_CAP", cap, 1);
    if (hv_machine_init(&m, 32 << 20) != 0) {
        printf("%s: machine init failed\n", name);
        return 1;
    }
    int changes = opts & RUN_CHANGES, sync_wait = hv_knob[HV_K_SYNCWAIT];
    if (opts & RUN_STATS) m.stats_interval = 2;
    if (opts & RUN_SYNC_WAIT) hv_knob[HV_K_SYNCWAIT] = 1;
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)codecache_programs_begin, codecache_programs_finish - codecache_programs_begin,
                       (void *)codecache_programs_begin, 1);
    uint8_t *stack = aligned_alloc(16384, 65536);
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)stack, 65536, stack, 0);
    m.stop_pc = (uint64_t)(uintptr_t)prog.end;
    int failed = 0;
    uint32_t nseg = m.cc.nseg;
    if (nseg < 8) {
        printf("%s: %u code-cache segments for %d MB, want 8 or more: FAIL\n", name, nseg, cap_mb);
        failed++;
    }
    static Worker w[3];
    for (int i = 0; i < ncpu; i++) {
        memset(&w[i], 0, sizeof w[i]);
        w[i].seed = 0x9e3779b97f4a7c15ull * (uint64_t)(i + 1) + (uint64_t)cap_mb;
        w[i].sp = (uint64_t)(uintptr_t)stack + 16384 * (uint64_t)(i + 1);
        static HvCpu init, native;
        memset(&init, 0, sizeof init);
        seed_cpu(&init, (uint64_t)i + 1, w[i].sp);
        init.x[0] = w[i].seed;
        init.x[20] = 0; /* natively: no TLBIs */
        init.x[21] = ROUNDS;
        run_native(&prog, &init, &native, NULL);
        w[i].want = native.x[0];
        HvCpu *cpu = aligned_alloc(16384, (sizeof(HvCpu) + 16383) & ~(size_t)16383);
        memset(cpu, 0, sizeof *cpu);
        hv_cpu_reset_index(cpu, &m, (uint32_t)i);
        memcpy(cpu->x, init.x, sizeof cpu->x);
        cpu->cpacr_el1 = 3u << 20;
        w[i].cpu = cpu;
    }
    __atomic_store_n(&stop, 0, __ATOMIC_RELEASE);
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 16u << 20);
    for (int i = 0; i < ncpu; i++) pthread_create(&w[i].th, &attr, worker, &w[i]);
    pthread_t changer;
    uint64_t nchanges = 0;
    if (changes) pthread_create(&changer, &attr, code_changer, &nchanges);
    double t0 = now_s(), laps = 0;
    int flushes_asked = 0;
    for (;;) {
        usleep(100000);
        double t = now_s() - t0;
        laps = (double)__atomic_load_n(&m.cc.evictions, __ATOMIC_RELAXED) / (nseg ? nseg : 1);
        int bad = 0;
        for (int i = 0; i < ncpu; i++) bad += __atomic_load_n(&w[i].bad, __ATOMIC_RELAXED) != 0;
        if (bad || laps >= want_laps || t >= max_s) break;
        /* Full flushes (a knob change), twice, while evictions are under way. */
        if (changes && flushes_asked < 2 && laps >= (flushes_asked + 1) * want_laps / 3) {
            hv_knob_set(&m, "HV_RECHECK", hv_knob[HV_K_RECHECK]);
            flushes_asked++;
        }
    }
    __atomic_store_n(&stop, 1, __ATOMIC_RELEASE);
    for (int i = 0; i < ncpu; i++) pthread_join(w[i].th, NULL);
    if (changes) pthread_join(changer, NULL);
    double secs = now_s() - t0;
    const HvCodeCache *cc = &m.cc;
    static HvStats tot; /* the machine's counters and every CPU's own */
    hv_stats_total(&m, &tot);
    uint64_t runs = 0, bad = 0;
    for (int i = 0; i < ncpu; i++) {
        runs += w[i].runs;
        bad += w[i].bad;
        if (!w[i].runs) {
            printf("%s: cpu %d finished no run: FAIL\n", name, i);
            failed++;
        }
    }
    printf("%s: %.1f s, %llu runs; %u segments of %u KB: %.1f laps (%llu evictions, %llu of them tenured), %llu blocks "
           "dropped, %llu exits unchained, %llu waits for room (%.0f ms), %llu tenured translations, %llu redone, "
           "%llu checks failed; %llu full flushes (%llu for room), %llu code changes\n",
           name, secs, (unsigned long long)runs, nseg, (4u << cc->seg_shift) >> 10, laps, (unsigned long long)cc->evictions,
           (unsigned long long)cc->evict_tenured, (unsigned long long)cc->evict_blocks, (unsigned long long)cc->evict_unchained,
           (unsigned long long)cc->waits, (double)cc->wait_ticks / 24e3, (unsigned long long)tot.cc_tenured,
           (unsigned long long)cc->stale, (unsigned long long)cc->check_bad, (unsigned long long)tot.block_flushes,
           (unsigned long long)tot.flush_full, (unsigned long long)nchanges);
    if (bad) printf("%s: %llu runs wrong: FAIL\n", name, (unsigned long long)bad), failed++;
    if (cc->check_bad) printf("%s: a freed segment was still reachable: FAIL\n", name), failed++;
    if (laps < min_laps) printf("%s: the cache went round %.1f times, want %.0f: FAIL\n", name, laps, min_laps), failed++;
    if (!cc->evict_tenured || !tot.cc_tenured) printf("%s: nothing tenured, or no tenured segment evicted: FAIL\n", name), failed++;
    if (!cc->evict_unchained) printf("%s: no chained exit undone: FAIL\n", name), failed++;
    if (tot.flush_full) printf("%s: full flushes for room: FAIL\n", name), failed++;
    if (tot.block_flushes > (uint64_t)flushes_asked) /* (one asked for just before the end may not have run) */
        printf("%s: %llu full flushes, %d asked for: FAIL\n", name, (unsigned long long)tot.block_flushes, flushes_asked), failed++;
    for (int i = 0; i < ncpu; i++) free(w[i].cpu);
    hv_machine_free(&m);
    free(stack);
    hv_knob[HV_K_SYNCWAIT] = sync_wait;
    return failed;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setenv("HV_JIT_POISON", "1", 1); /* read once, at the first machine */
    int failed = 0;
    /* Each about 300 times round the cache (at least 100), at most a minute. */
    failed += run("1 cpu, 2 MB", 2, 1, 0, 100, 300, 60);
    failed += run("3 cpus, 2 MB, code changes, full flushes, stats", 2, 3, RUN_CHANGES | RUN_STATS, 100, 300, 60);
    failed += run("3 cpus, 1 MB, TLBI waits asleep (HV_SYNC_WAIT=1, as on the phone)", 1, 3, RUN_SYNC_WAIT, 100, 300, 60);
    printf("%s\n", failed ? "FAIL" : "ok");
    return failed != 0;
}
