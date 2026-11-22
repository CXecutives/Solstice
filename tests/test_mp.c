// Several CPU threads in guest code at once (mp_programs.S), with the machine's own kicker:
//  - per-CPU counters (O4): exact totals from CPUs counting at the same time;
//  - the deadline-driven kicker (O9): timer interrupts reach CPUs that spin in code that never leaves by itself, on
//    time; CPU 0's device deadline (a 60 Hz refresh grid, as pvg_lite.c's) keeps every refresh, running or asleep;
//    an idle machine wakes rarely (it was every CPU every millisecond).
#include "harness.h"

#include <mach/mach_time.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <unistd.h>

#include "pvg_vblank_clock.h"

extern const char mp_programs_begin[], mp_programs_finish[], mp_done[], mp_svc[], mp_timer_spin[], mp_timer_wfi[],
    mp_idle[], mp_spin[];
#define ADDR(sym) ((uint64_t)(uintptr_t)(sym))
#define NCPU 4

static HvMachine m;
static HvCpu cpus[NCPU];
static uint32_t *flag;
static int checks, failures;

static void check(const char *what, int ok) {
    checks++;
    if (!ok) printf("  FAIL %s\n", what), failures++;
}

/* The board's tick, as vmapple.c's: each CPU's virtual timer drives its IRQ line; CPU 0 also has the display's
   refresh (on a 60 Hz grid) and polls "the devices" when woken for them or a device deadline is due. */
static int refresh_on;
static HvVblankClock vclock;
static uint64_t poll_due;
static _Atomic uint64_t refreshes, polls;
static uint64_t tick(HvMachine *mm, HvCpu *cpu) {
    (void)mm;
    HvPerCpu *p = cpu->pc_state;
    uint64_t now = mach_absolute_time();
    int on = (cpu->cntv_ctl & 1) && !(cpu->cntv_ctl & 2);
    int fired = on && now - cpu->cntvoff >= cpu->cntv_cval;
    __atomic_store_n(&p->irq_line, fired, __ATOMIC_SEQ_CST);
    uint64_t due = on && !fired ? cpu->cntv_cval + cpu->cntvoff : 0;
    if (cpu->index == 0 && refresh_on) {
        const uint64_t period = 24000000 / 60;
        uint64_t vb = hv_vblank_next(&vclock);
        if (__atomic_exchange_n(&p->poll_req, 0, __ATOMIC_ACQ_REL) || now >= poll_due || (vb && now >= vb)) {
            atomic_fetch_add(&polls, 1);
            if (hv_vblank_due(&vclock, now, period)) atomic_fetch_add(&refreshes, 1);
            poll_due = now + HV_DEV_SAFETY;
            vb = hv_vblank_next(&vclock);
        }
        uint64_t dev = vb && vb < poll_due ? vb : poll_due;
        if (!due || dev < due) due = dev;
    }
    return due;
}

static void *cpu_thread(void *arg) {
    return (void *)(intptr_t)hv_run(arg);
}

static _Atomic int kicker_stop;
static void *kicker_thread(void *unused) {
    (void)unused;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0); /* as host/vm.c runs it */
    hv_machine_kicker(&m, &kicker_stop);
    return NULL;
}

static pthread_t kicker;
static void kicker_start(void) {
    atomic_store(&kicker_stop, 0);
    pthread_create(&kicker, NULL, kicker_thread, NULL);
}
static void kicker_end(void) {
    atomic_store(&kicker_stop, 1);
    hv_machine_kicker_poke(&m);
    pthread_join(kicker, NULL);
}

/* Each CPU from the start of prog[i] with x0, x1 = arg0, arg1; returns when all have stopped. */
static pthread_t threads[NCPU];
static void start(const char *const prog[NCPU], uint64_t arg0, uint64_t arg1) {
    __atomic_store_n(flag, 0, __ATOMIC_SEQ_CST);
    for (int i = 0; i < NCPU; i++) {
        HvCpu *c = &cpus[i];
        hv_cpu_reset_index(c, &m, (uint32_t)i);
        c->mpidr = (uint64_t)i;
        c->x[0] = arg0;
        c->x[1] = arg1;
        c->x[9] = ADDR(flag);
        c->pc = ADDR(prog[i]);
    }
    m.stop_pc = ADDR(mp_done);
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 8u << 20);
    for (int i = 0; i < NCPU; i++) pthread_create(&threads[i], &attr, cpu_thread, &cpus[i]);
    pthread_attr_destroy(&attr);
}

static void finish(const char *what) {
    __atomic_store_n(flag, 1, __ATOMIC_SEQ_CST);
    for (int i = 0; i < NCPU; i++) hv_cpu_wake(&cpus[i]);
    for (int i = 0; i < NCPU; i++) {
        void *r;
        pthread_join(threads[i], &r);
        char msg[160];
        snprintf(msg, sizeof msg, "%s: cpu %d stopped normally (exit %d, x17 %llx esr %llx elr %llx)", what, i,
                 (int)(intptr_t)r, (unsigned long long)cpus[i].x[17], (unsigned long long)cpus[i].x[19],
                 (unsigned long long)cpus[i].x[18]);
        check(msg, (intptr_t)r == HV_EXIT_HALT && cpus[i].x[17] == 0);
    }
}

static uint64_t kicker_wakes(void) { return __atomic_load_n(&m.stats.kicker_wakes, __ATOMIC_RELAXED); }
static uint64_t wfis(void) {
    uint64_t n = 0;
    for (int i = 0; i < NCPU; i++) n += __atomic_load_n(&m.percpu[i].own.stats.wfi, __ATOMIC_RELAXED);
    return n;
}

/* O4: four CPUs taking SVCs at once; their counters add up exactly (a shared counter loses some). */
static void counters(void) {
    const uint64_t n = 200000;
    static const char *const prog[NCPU] = {mp_svc, mp_svc, mp_svc, mp_svc};
    static HvStats before, after;
    hv_stats_total(&m, &before);
    uint64_t elchg0[NCPU];
    for (int i = 0; i < NCPU; i++) elchg0[i] = m.percpu[i].own.stats.nelchg;
    start(prog, n, 0);
    finish("counters");
    hv_stats_total(&m, &after);
    for (int i = 0; i < NCPU; i++) check("counters: every SVC reached the vector", cpus[i].x[20] == n);
    printf("counters: exceptions %llu of %llu, blocks %llu\n", (unsigned long long)(after.exceptions - before.exceptions),
           (unsigned long long)(NCPU * n), (unsigned long long)(after.blocks - before.blocks));
    check("counters: exceptions summed over the CPUs are exact", after.exceptions - before.exceptions == NCPU * n);
    for (int i = 0; i < NCPU; i++)
        check("counters: each CPU's own ring counted its exceptions and returns",
              (uint32_t)(m.percpu[i].own.stats.nelchg - elchg0[i]) == (uint32_t)(2 * n));
    check("counters: dispatcher entries counted", after.blocks > before.blocks);
}

/* O9: timer interrupts 1 ms after they are set, 300 each on four CPUs: two spin in a loop that never leaves by itself
   (only the kicker gets them out, at their deadline), two wait in WFI. On average well under the 20 ms safety kick. */
static void timers(void) {
    const uint64_t n = 300, delay = 24000;
    static const char *const prog[NCPU] = {mp_timer_spin, mp_timer_spin, mp_timer_wfi, mp_timer_wfi};
    uint64_t kicks0 = m.stats.kicker_kicks;
    kicker_start();
    start(prog, n, delay);
    for (int i = 0; i < NCPU; i++) pthread_join(threads[i], NULL), threads[i] = 0;
    kicker_end();
    for (int i = 0; i < NCPU; i++) {
        char msg[200];
        double mean = (double)cpus[i].x[22] / (double)n / 24.0, max = (double)cpus[i].x[23] / 24.0;
        printf("timers: cpu %d (%s): %llu interrupts, late by %.0f us on average, %.0f us at most\n", i, i < 2 ? "spinning" : "in WFI",
               (unsigned long long)cpus[i].x[21], mean, max);
        snprintf(msg, sizeof msg, "timers: cpu %d took all its interrupts and nothing else (x17 %llx esr %llx)", i,
                 (unsigned long long)cpus[i].x[17], (unsigned long long)cpus[i].x[19]);
        check(msg, cpus[i].x[21] == n && cpus[i].x[17] == 0);
        snprintf(msg, sizeof msg, "timers: cpu %d on time (late by %.0f us on average, under 3 ms)", i, mean);
        check(msg, mean < 3000);
        snprintf(msg, sizeof msg, "timers: cpu %d never lost (at most %.0f us late, under 100 ms)", i, max);
        check(msg, max < 100000);
    }
    check("timers: the kicker kicked CPUs at their deadlines", m.stats.kicker_kicks > kicks0);
}

/* O9 + GFX-3: CPU 0's refresh deadline. A second with CPU 0 spinning (the kicker brings it out at each refresh and polls
   it every millisecond), then a second with every CPU in WFI (they wake at their own deadlines: the refresh, the 100 ms
   cap; the kicker looks only after those). Every refresh comes (60 a second), and the idle machine wakes rarely. */
static void refresh_and_idle(void) {
    refresh_on = 1;
    memset(&vclock, 0, sizeof vclock);
    poll_due = 0;
    kicker_start();
    for (int phase = 0; phase < 2; phase++) {
        static const char *const busy[NCPU] = {mp_spin, mp_idle, mp_idle, mp_idle}, *const idle[NCPU] = {mp_idle, mp_idle, mp_idle, mp_idle};
        start(phase ? idle : busy, 0, 0);
        usleep(300000); /* settled */
        uint64_t r0 = atomic_load(&refreshes), p0 = atomic_load(&polls), k0 = kicker_wakes(), w0 = wfis();
        uint64_t t0 = mach_absolute_time();
        usleep(1000000);
        double dt = (double)(mach_absolute_time() - t0) / 24e6;
        double r = (double)(atomic_load(&refreshes) - r0) / dt, p = (double)(atomic_load(&polls) - p0) / dt;
        double k = (double)(kicker_wakes() - k0) / dt, w = (double)(wfis() - w0) / dt;
        printf("refresh, cpu 0 %s: refreshes %.1f/s, device polls %.0f/s, kicker wakeups %.0f/s, WFI wakeups %.0f/s\n",
               phase ? "asleep" : "spinning", r, p, k, w);
        char msg[160];
        snprintf(msg, sizeof msg, "refresh, cpu 0 %s: every 60 Hz refresh came (%.1f/s)", phase ? "asleep" : "spinning", r);
        check(msg, r >= 57 && r <= 61.5);
        if (!phase) {
            snprintf(msg, sizeof msg, "refresh, cpu 0 spinning: devices polled about every millisecond (%.0f/s)", p);
            check(msg, p >= 300);
        } else {
            snprintf(msg, sizeof msg, "idle: devices polled at the refreshes only (%.0f/s)", p);
            check(msg, p <= 150);
            snprintf(msg, sizeof msg, "idle: the kicker wakes rarely (%.0f/s; it was 1000)", k);
            check(msg, k <= 200);
            snprintf(msg, sizeof msg, "idle: CPUs wake rarely (%.0f/s)", w);
            check(msg, w <= 160);
        }
        finish(phase ? "idle" : "refresh");
    }
    kicker_end();
    refresh_on = 0;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    alarm(240); /* a multi-CPU test that hangs fails */
    if (hv_machine_init(&m, 16 << 20) != 0) return 1;
    m.stats_interval = 3600; /* counted as on a device (HV_STATS), never printed here */
    m.tick = tick;
    flag = aligned_alloc(16384, 16384);
    hv_machine_add_ram(&m, ADDR(mp_programs_begin), (uint64_t)(mp_programs_finish - mp_programs_begin), (void *)mp_programs_begin, 1);
    hv_machine_add_ram(&m, ADDR(flag), 16384, flag, 0);
    counters();
    timers();
    refresh_and_idle();
    printf("%d checks, %d failures\n", checks, failures);
    return failures != 0;
}
