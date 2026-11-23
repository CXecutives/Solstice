// Several CPU threads in guest code at once (mp_programs.S), with the machine's own kicker:
//  - per-CPU counters (O4): exact totals from CPUs counting at the same time;
//  - the deadline-driven kicker (O9): timer interrupts reach CPUs that spin in code that never leaves by itself, on
//    time; CPU 0's device deadline (a 60 Hz refresh grid, as pvg_lite.c's) keeps every refresh, running or asleep;
//    an idle machine wakes rarely (it was every CPU every millisecond).
#include "harness.h"

#include <mach/mach_time.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <unistd.h>

#include "exception.h"
#include "pvg_vblank_clock.h"

extern const char mp_programs_begin[], mp_programs_finish[], mp_done[], mp_svc[], mp_timer_spin[], mp_timer_wfi[],
    mp_idle[], mp_spin[], mp_pv_probe[], mp_pv_pingpong[], mp_lock[];
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
    __atomic_store_n(&p->guest_due, due, __ATOMIC_RELAXED); /* the guest timer's alone, as vmapple.c's */
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
static void start(const char *const prog[NCPU], uint64_t arg0, uint64_t arg1, void (*setup)(HvCpu *c, int i)) {
    __atomic_store_n(flag, 0, __ATOMIC_SEQ_CST);
    for (int i = 0; i < NCPU; i++) {
        HvCpu *c = &cpus[i];
        hv_cpu_reset_index(c, &m, (uint32_t)i);
        c->mpidr = (uint64_t)i;
        c->x[0] = arg0;
        c->x[1] = arg1;
        c->x[9] = ADDR(flag);
        c->pc = ADDR(prog[i]);
        if (setup) setup(c, i);
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
    start(prog, n, 0, NULL);
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

/* How late this host's timed waits (pthread_cond_timedwait_relative_np, as the kicker and WFI sleep) come back after
   `ticks`, on average in us, at QoS class `qos`: a few us on a Mac or a phone, ~10 ms on the CI's virtual Macs. The
   timing checks allow for it; whether the kicker works at all is checked by what it counted. */
struct Overshoot { qos_class_t qos; uint64_t ticks; double us; };
static void *measure_overshoot(void *arg) {
    struct Overshoot *o = arg;
    if (o->qos != QOS_CLASS_DEFAULT) pthread_set_qos_class_self_np(o->qos, 0);
    pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
    double sum = 0;
    for (int i = 0; i < 10; i++) {
        struct timespec ts = {(time_t)(o->ticks / 24000000), (long)(o->ticks % 24000000) * 1000 / 24};
        uint64_t t0 = mach_absolute_time();
        pthread_mutex_lock(&mu);
        pthread_cond_timedwait_relative_np(&cv, &mu, &ts);
        pthread_mutex_unlock(&mu);
        uint64_t dt = mach_absolute_time() - t0;
        sum += dt > o->ticks ? (double)(dt - o->ticks) / 24.0 : 0;
    }
    o->us = sum / 10;
    return NULL;
}
static double overshoot_us(qos_class_t qos, uint64_t ticks) {
    struct Overshoot o = {qos, ticks, 0};
    pthread_t t;
    pthread_create(&t, NULL, measure_overshoot, &o);
    pthread_join(t, NULL);
    return o.us;
}

/* The longest this host kept a 1 ms timed wait from coming back while a test ran. A CI virtual Mac sometimes stalls
   every thread for 100 ms and more; a check of "no timer was lost" (a lost one comes about 100 ms late, at the WFI
   cap) cannot tell that from a lost timer, so it is only made when the host itself did not stall. */
static _Atomic int stall_watch;
static double stall_worst_us;
/* With stall_period_us set: how many such periods those stalls spanned (a wait that comes back later than a period
   took that many deadlines with it, and one more for the one it was in). */
static double stall_period_us, stall_periods;
static void *watch_stalls(void *arg) {
    (void)arg;
    pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
    const uint64_t ticks = 24000;
    while (atomic_load(&stall_watch)) {
        struct timespec ts = {0, (long)ticks * 1000 / 24};
        uint64_t t0 = mach_absolute_time();
        pthread_mutex_lock(&mu);
        pthread_cond_timedwait_relative_np(&cv, &mu, &ts);
        pthread_mutex_unlock(&mu);
        uint64_t dt = mach_absolute_time() - t0;
        double late = dt > ticks ? (double)(dt - ticks) / 24.0 : 0;
        if (late > stall_worst_us) stall_worst_us = late;
        if (stall_period_us > 0 && late > stall_period_us) stall_periods += late / stall_period_us + 1;
    }
    return NULL;
}

/* O9: timer interrupts 1 ms after they are set, 300 each on four CPUs: two spin in a loop that never leaves by itself
   (only a kick gets them out: the kicker's, at their deadline), two wait in WFI (until their deadline). On time, as
   far as the host's own timed waits allow; the spinning ones by a kick at nearly every deadline. */
static void timers(void) {
    const uint64_t n = 300, delay = 24000;
    static const char *const prog[NCPU] = {mp_timer_spin, mp_timer_spin, mp_timer_wfi, mp_timer_wfi};
    double slack_kicker = overshoot_us(QOS_CLASS_USER_INTERACTIVE, delay), slack_cpu = overshoot_us(QOS_CLASS_DEFAULT, delay);
    printf("timers: this host's 1 ms timed waits come back %.0f us late (kicker's QoS), %.0f us (CPU threads')\n", slack_kicker, slack_cpu);
    uint64_t kicks0 = m.stats.kicker_kicks;
    pthread_t watcher;
    stall_worst_us = 0;
    atomic_store(&stall_watch, 1);
    pthread_create(&watcher, NULL, watch_stalls, NULL);
    kicker_start();
    start(prog, n, delay, NULL);
    for (int i = 0; i < NCPU; i++) pthread_join(threads[i], NULL), threads[i] = 0;
    kicker_end();
    atomic_store(&stall_watch, 0);
    pthread_join(watcher, NULL);
    int host_stalled = stall_worst_us > 50000;
    if (host_stalled) printf("timers: this host stalled a 1 ms wait for %.0f ms itself: 'never lost' is not checked\n", stall_worst_us / 1000);
    uint64_t kicks = m.stats.kicker_kicks - kicks0;
    for (int i = 0; i < NCPU; i++) {
        char msg[200];
        double mean = (double)cpus[i].x[22] / (double)n / 24.0, max = (double)cpus[i].x[23] / 24.0;
        double bound = (i < 2 ? slack_kicker : slack_cpu) + 3000;
        printf("timers: cpu %d (%s): %llu interrupts, late by %.0f us on average, %.0f us at most\n", i, i < 2 ? "spinning" : "in WFI",
               (unsigned long long)cpus[i].x[21], mean, max);
        snprintf(msg, sizeof msg, "timers: cpu %d took all its interrupts and nothing else (x17 %llx esr %llx)", i,
                 (unsigned long long)cpus[i].x[17], (unsigned long long)cpus[i].x[19]);
        check(msg, cpus[i].x[21] == n && cpus[i].x[17] == 0);
        snprintf(msg, sizeof msg, "timers: cpu %d on time (late by %.0f us on average, under %.0f us)", i, mean, bound);
        check(msg, mean < bound);
        snprintf(msg, sizeof msg, "timers: cpu %d never lost (at most %.0f us late, under 100 ms)", i, max);
        if (!host_stalled) check(msg, max < 100000 + 3 * (i < 2 ? slack_kicker : slack_cpu));
    }
    printf("timers: the kicker kicked %llu CPUs at their deadline for %llu interrupts of the spinning CPUs\n",
           (unsigned long long)kicks, (unsigned long long)(2 * n));
    check("timers: the kicker brought the spinning CPUs out at their deadlines (nearly every interrupt)", kicks >= 2 * n * 8 / 10);
}

/* O9 + GFX-3: CPU 0's refresh deadline. A second with CPU 0 spinning and no device work waiting for a poll (the kicker
   brings it out at each refresh and polls nothing else), a second with such work (a display channel waiting for
   another's stamp: then it polls at each kicker wakeup, every millisecond), then a second with every CPU in WFI (they
   wake at their own deadlines: the refresh, the 100 ms cap; the kicker looks only after those). Every refresh comes
   (60 a second), and the idle machine wakes rarely. */
static void refresh_and_idle(void) {
    const uint64_t period = 24000000 / 60;
    double slack_kicker = overshoot_us(QOS_CLASS_USER_INTERACTIVE, HV_POLL_BUSY), slack_wfi = overshoot_us(QOS_CLASS_DEFAULT, period);
    /* What the host's timed waits allow: one refresh per wakeup at most, one wakeup per period plus how late it comes. */
    double want_asleep = 1e6 / ((double)period / 24.0 + slack_wfi);
    if (want_asleep > 60) want_asleep = 60;
    printf("refresh: this host's timed waits come back %.0f us late after 1 ms (kicker), %.0f us after 16.7 ms (CPU threads)\n",
           slack_kicker, slack_wfi);
    refresh_on = 1;
    memset(&vclock, 0, sizeof vclock);
    poll_due = 0;
    kicker_start();
    for (int phase = 0; phase < 3; phase++) {
        static const char *const busy[NCPU] = {mp_spin, mp_idle, mp_idle, mp_idle}, *const idle[NCPU] = {mp_idle, mp_idle, mp_idle, mp_idle};
        static const char *const what[3] = {"spinning", "spinning, unsignalled work", "asleep"};
        start(phase == 2 ? idle : busy, 0, 0, NULL);
        hv_machine_unsignalled(&m, HV_UNSIG_PVG_CHAN, phase == 1);
        usleep(300000); /* settled */
        uint64_t r0 = atomic_load(&refreshes), p0 = atomic_load(&polls), k0 = kicker_wakes(), w0 = wfis();
        uint64_t kp0 = __atomic_load_n(&m.stats.kicker_polls, __ATOMIC_RELAXED);
        /* The host's own stalls over the same second: a refresh whose deadline passed while every thread stood still
           is the host's, not the engine's. */
        pthread_t watcher;
        stall_worst_us = stall_periods = 0;
        stall_period_us = (double)period / 24.0;
        atomic_store(&stall_watch, 1);
        pthread_create(&watcher, NULL, watch_stalls, NULL);
        uint64_t t0 = mach_absolute_time();
        usleep(1000000);
        double dt = (double)(mach_absolute_time() - t0) / 24e6;
        atomic_store(&stall_watch, 0);
        pthread_join(watcher, NULL);
        stall_period_us = 0;
        double stalled = stall_periods / dt;
        double r = (double)(atomic_load(&refreshes) - r0) / dt, p = (double)(atomic_load(&polls) - p0) / dt;
        double k = (double)(kicker_wakes() - k0) / dt, w = (double)(wfis() - w0) / dt;
        double kp = (double)(__atomic_load_n(&m.stats.kicker_polls, __ATOMIC_RELAXED) - kp0) / dt;
        printf("refresh, cpu 0 %s: refreshes %.1f/s, device polls %.0f/s (kicker's %.0f/s), kicker wakeups %.0f/s, WFI wakeups %.0f/s\n",
               what[phase], r, p, kp, k, w);
        char msg[200];
        if (phase < 2) { /* kicked at each refresh deadline */
            snprintf(msg, sizeof msg, "refresh, cpu 0 %s: every 60 Hz refresh came (%.1f/s; this host's stalls spanned %.1f)", what[phase], r, stalled);
            check(msg, r >= 57 - stalled && r <= 61.5);
        }
        if (phase == 0) { /* nothing waits for a poll: the kicker asks for none, CPU 0 polls at its refreshes */
            snprintf(msg, sizeof msg, "refresh, cpu 0 spinning: no poll asked by the kicker (%.0f/s), polls at the refreshes (%.0f/s)", kp, p);
            check(msg, kp == 0 && p <= r + 3);
        } else if (phase == 1) {
            /* How often the kicker gets to run is the host's call (a busy CI VM gave 84/s against 181 it promised a
               moment before), so check what the engine decides: a poll at each kicker wakeup, not just at refreshes. */
            snprintf(msg, sizeof msg, "refresh, unsignalled work: a poll asked at each kicker wakeup but the refreshes' (%.0f/s of %.0f; %.0f polls/s)", kp, k, p);
            /* The kicker wakes for CPU 0's refresh deadlines too, and asks for no poll then unless a poll period has
               passed. How many of the polls it asks for CPU 0 gets to make is again the host's call (asked twice while
               its thread stood still is one poll), so what is checked is the asking. */
            check(msg, kp >= 0.9 * (k - r - 5) && kp > 0 && p > r);
        } else { /* asleep until each refresh deadline: one refresh per wakeup */
            snprintf(msg, sizeof msg, "refresh, cpu 0 asleep: a refresh at each deadline (%.1f/s; %.1f allowed by this host)", r, want_asleep);
            check(msg, r >= 0.85 * want_asleep - 1 && r <= 61.5);
            snprintf(msg, sizeof msg, "idle: devices polled at the refreshes only (%.0f/s)", p);
            check(msg, p <= 150);
            snprintf(msg, sizeof msg, "idle: the kicker wakes rarely (%.0f/s; it was 1000)", k);
            check(msg, k <= 200);
            snprintf(msg, sizeof msg, "idle: CPUs wake rarely (%.0f/s)", w);
            check(msg, w <= 160);
        }
        finish(phase == 2 ? "idle" : "refresh");
        hv_machine_unsignalled(&m, HV_UNSIG_PVG_CHAN, 0);
    }
    kicker_end();
    refresh_on = 0;
}

/* CPU 0's syscalls near its device deadlines: CPU 0 takes SVCs (the light path resumes them) while the refreshes come
   on their grid, its guest timer off. A refresh due is no reason to refuse the fast resume (the kicker brings CPU 0
   out for it): only its guest timer is. */
static void resume_near_device_deadlines(void) {
    static const char *const prog[NCPU] = {mp_svc, mp_idle, mp_idle, mp_idle};
    refresh_on = 1;
    memset(&vclock, 0, sizeof vclock);
    poll_due = 0;
    HvStats *st = &m.percpu[0].own.stats;
    uint64_t refused0 = st->fr_fail[3], fast0 = st->fast_resumes, r0 = atomic_load(&refreshes);
    kicker_start();
    start(prog, 3000000, 0, NULL);
    pthread_join(threads[0], NULL), threads[0] = 0;
    __atomic_store_n(flag, 1, __ATOMIC_SEQ_CST);
    for (int i = 1; i < NCPU; i++) hv_cpu_wake(&cpus[i]);
    for (int i = 1; i < NCPU; i++) pthread_join(threads[i], NULL), threads[i] = 0;
    kicker_end();
    refresh_on = 0;
    uint64_t refused = st->fr_fail[3] - refused0, fast = st->fast_resumes - fast0, r = atomic_load(&refreshes) - r0;
    printf("resume: cpu 0 took 3M SVCs over %llu refreshes: %llu fast resumes, %llu refused for its timer\n",
           (unsigned long long)r, (unsigned long long)fast, (unsigned long long)refused);
    check("resume: every SVC reached the vector", cpus[0].x[20] == 3000000);
    if (fast && r) check("resume: no fast resume refused for a device deadline (guest timer off)", refused == 0);
    else printf("resume: (fast resumes or refreshes missing here: nothing to check)\n");
}

/* A wake for a running CPU is exit_req, SEV and wake_pending: it never takes the CPU's wake_mu. One for a CPU that is
   not running signals it under wake_mu (the lost-wakeup argument is at hv_cpu_wake; pv_locks runs it 6000 times). */
static _Atomic int woke;
static void *wake_one(void *c) {
    hv_cpu_wake(c);
    atomic_store(&woke, 1);
    return NULL;
}
static int woke_within(int ms) {
    for (int i = 0; i < ms && !atomic_load(&woke); i++) usleep(1000);
    return atomic_load(&woke);
}
static void wake_running(void) {
    HvCpu *c = &cpus[1];
    HvPerCpu *p = c->pc_state;
    pthread_t t;
    pthread_mutex_lock(&p->wake_mu);
    __atomic_store_n(&p->active, 1, __ATOMIC_SEQ_CST);
    __atomic_store_n(&p->wake_pending, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&c->exit_req, 0, __ATOMIC_SEQ_CST);
    atomic_store(&woke, 0);
    pthread_create(&t, NULL, wake_one, c);
    int done = woke_within(1000);
    check("wake: a running CPU is woken without its wake_mu", done);
    check("wake: ...with exit_req and wake_pending", __atomic_load_n(&c->exit_req, __ATOMIC_SEQ_CST) == 1 &&
          __atomic_load_n(&p->wake_pending, __ATOMIC_SEQ_CST) == 1);
    pthread_mutex_unlock(&p->wake_mu);
    pthread_join(t, NULL);
    pthread_mutex_lock(&p->wake_mu);
    __atomic_store_n(&p->active, 0, __ATOMIC_SEQ_CST);
    atomic_store(&woke, 0);
    pthread_create(&t, NULL, wake_one, c);
    done = woke_within(50);
    check("wake: a parked CPU is signalled under its wake_mu", !done);
    pthread_mutex_unlock(&p->wake_mu);
    pthread_join(t, NULL);
    __atomic_store_n(&p->wake_pending, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&c->exit_req, 0, __ATOMIC_SEQ_CST);
}

static void pv_setup(HvCpu *c, int i) {
    if (i >= 2) return;
    c->x[9] = ADDR(flag + 16);
    c->x[10] = (uint64_t)i;
    c->x[11] = (uint64_t)(1 - i); /* the other one's MPIDR */
    c->x[15] = 3000;
}

/* PLAT-1: the vmapple OEM calls xnu's lck_init_pv probes, register by register (an HVC at EL1 straight into
   hv_exception_insn), and its UID as xnu turns it into text (regs_to_uuid, uuid_unparse) against VMAPPLE_HVC_UID. */
static uint64_t hvc(HvCpu *c, uint64_t x0, uint64_t x1) {
    c->x[0] = x0, c->x[1] = x1, c->x[2] = c->x[3] = 0;
    hv_exception_insn(c, 0xd4000002u, ADDR(mp_done)); /* hvc #0 */
    return c->x[0];
}

static void pv_calls(void) {
    HvCpu *c = &cpus[2];
    hv_cpu_reset_index(c, &m, 2);
    c->el = 1;
    check("pv: PAC_NOP succeeds (not 0xffffffff, not negative)", hvc(c, 0xc10000f0u, 0) == 0);
    uint32_t w[4] = {(uint32_t)hvc(c, 0x8300ff01u, 0), (uint32_t)c->x[1], (uint32_t)c->x[2], (uint32_t)c->x[3]};
    uint8_t uuid[16];
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) uuid[15 - i * 4 - j] = (uint8_t)(w[i] >> (j * 8));
    char text[40];
    snprintf(text, sizeof text, "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X", uuid[0], uuid[1],
             uuid[2], uuid[3], uuid[4], uuid[5], uuid[6], uuid[7], uuid[8], uuid[9], uuid[10], uuid[11], uuid[12], uuid[13],
             uuid[14], uuid[15]);
    printf("pv: OEM UID %s\n", text);
    check("pv: the OEM UID is Apple's (VMAPPLE_HVC_UID)", !strcmp(text, "3B878185-AA62-4E1F-9DC9-D6799CBB6EBB"));
    check("pv: revision 1.0", (int32_t)hvc(c, 0x8300ff03u, 0) == 1 && (uint32_t)c->x[1] == 0);
    check("pv: features: WFK there", (int32_t)hvc(c, 0x8300feffu, 0xc3000005u) >= 0);
    check("pv: features: KICK there", (int32_t)hvc(c, 0x8300feffu, 0xc3000006u) >= 0);
    check("pv: features: GET_MABS_OFFSET not there", (int32_t)hvc(c, 0x8300feffu, 0xc3000003u) < 0);
    check("pv: features: GET_BOOTSESSIONUUID not there", (int32_t)hvc(c, 0x8300feffu, 0xc3000004u) < 0);
    check("pv: KICK of a CPU that does not exist fails", (int64_t)hvc(c, 0xc3000006u, 7) < 0);
    __atomic_store_n(&m.percpu[1].wake_pending, 0, __ATOMIC_SEQ_CST);
    check("pv: KICK of CPU 1 succeeds", hvc(c, 0xc3000006u, 1) == 0);
    check("pv: ...and leaves it woken (a wait after it ends at once)", __atomic_load_n(&m.percpu[1].wake_pending, __ATOMIC_SEQ_CST) == 1);
    c->pc = 0;
    c->x[0] = 0xc3000005u, c->x[1] = 0;
    check("pv: WFK succeeds and leaves the block to wait", hv_exception_insn(c, 0xd4000002u, 0x1000) == 1 && c->x[0] == 0 &&
          c->exit_reason == HV_EXIT_WFI && c->pc == 0x1004);
}

/* The probe through the JIT, then two CPUs handing a lock back and forth 3000 times, waiting with WFK and kicking with
   KICK. A kick is never lost (one that comes before the wait ends it at once): no wait lasts anywhere near the 100 ms
   WFI cap, and every call is counted. */
static void pv_locks(void) {
    static const char *const probe[NCPU] = {mp_pv_probe, mp_idle, mp_idle, mp_idle};
    start(probe, 0, 0, NULL);
    while (cpus[0].pc != ADDR(mp_done)) usleep(1000);
    finish("pv probe");
    check("pv: xnu's probe finds WFK and KICK (has_lock_pv)", cpus[0].x[20] == 1);
    check("pv: the probe saw revision 1.0", (uint32_t)cpus[0].x[25] == 1 && (uint32_t)cpus[0].x[26] == 0);

    const uint64_t n = 3000;
    static const char *const prog[NCPU] = {mp_pv_pingpong, mp_pv_pingpong, mp_idle, mp_idle};
    static HvStats before, after;
    hv_stats_total(&m, &before);
    flag[16] = 0; /* the token: CPU 0's */
    kicker_start();
    uint64_t t0 = mach_absolute_time();
    start(prog, 0, 0, pv_setup);
    for (int i = 0; i < 2; i++) pthread_join(threads[i], NULL), threads[i] = 0;
    double secs = (double)(mach_absolute_time() - t0) / 24e6;
    __atomic_store_n(flag, 1, __ATOMIC_SEQ_CST);
    for (int i = 2; i < NCPU; i++) hv_cpu_wake(&cpus[i]);
    for (int i = 2; i < NCPU; i++) pthread_join(threads[i], NULL), threads[i] = 0;
    kicker_end();
    hv_stats_total(&m, &after);
    uint64_t waits = cpus[0].x[21] + cpus[1].x[21];
    double longest = (double)(cpus[0].x[23] > cpus[1].x[23] ? cpus[0].x[23] : cpus[1].x[23]) / 24.0;
    printf("pv: %llu hand-overs each in %.2f s, %llu waits for a kick, longest %.0f us; counted %llu waits, %llu kicks\n",
           (unsigned long long)n, secs, (unsigned long long)waits, longest,
           (unsigned long long)(after.pv_waits - before.pv_waits), (unsigned long long)(after.pv_kicks - before.pv_kicks));
    for (int i = 0; i < 2; i++) {
        char msg[120];
        snprintf(msg, sizeof msg, "pv: cpu %d handed over every time, every call succeeded (x15 %llu, x17 %llx)", i,
                 (unsigned long long)cpus[i].x[15], (unsigned long long)cpus[i].x[17]);
        check(msg, cpus[i].x[15] == 0 && cpus[i].x[17] == 0 && cpus[i].pc == ADDR(mp_done));
    }
    check("pv: the CPUs did wait for kicks", waits > 0);
    check("pv: no kick was lost (no wait reached 80 ms)", longest < 80000);
    check("pv: every wait and kick counted", after.pv_waits - before.pv_waits == waits && after.pv_kicks - before.pv_kicks == 2 * n);
}

static void lock_setup(HvCpu *c, int i) {
    if (i < 2) c->x[9] = ADDR(flag + 32); /* the lock; the count after it */
}

/* A1/A4: two CPUs taking turns at an LDAXR/STXR spinlock, waiting in WFE while the other holds it: the light path's
   WFE waits for the holder's release in place (never the full helper), and the count the lock guards comes out exact. */
static void spinlock(void) {
    const uint64_t n = 200000;
    static const char *const prog[NCPU] = {mp_lock, mp_lock, mp_idle, mp_idle};
    static HvStats before, after;
    hv_stats_total(&m, &before);
    flag[32] = 0;
    memset(&flag[34], 0, 8);
    uint64_t t0 = mach_absolute_time();
    start(prog, n, 0, lock_setup);
    for (int i = 0; i < 2; i++) pthread_join(threads[i], NULL), threads[i] = 0;
    double secs = (double)(mach_absolute_time() - t0) / 24e6;
    __atomic_store_n(flag, 1, __ATOMIC_SEQ_CST);
    for (int i = 2; i < NCPU; i++) hv_cpu_wake(&cpus[i]);
    for (int i = 2; i < NCPU; i++) pthread_join(threads[i], NULL), threads[i] = 0;
    hv_stats_total(&m, &after);
    uint64_t count;
    memcpy(&count, &flag[34], 8);
    printf("spinlock: %llu turns each in %.2f s, %llu WFE waits in place, %llu dispatcher entries\n", (unsigned long long)n, secs,
           (unsigned long long)(after.wfe_waits - before.wfe_waits), (unsigned long long)(after.blocks - before.blocks));
    for (int i = 0; i < 2; i++) {
        char msg[120];
        snprintf(msg, sizeof msg, "spinlock: cpu %d took every turn (x0 %llu, x17 %llx)", i, (unsigned long long)cpus[i].x[0],
                 (unsigned long long)cpus[i].x[17]);
        check(msg, cpus[i].x[0] == 0 && cpus[i].x[17] == 0 && cpus[i].pc == ADDR(mp_done));
    }
    check("spinlock: the count is exact (the lock excluded)", count == 2 * n);
    check("spinlock: released at the end", flag[32] == 0);
    check("spinlock: no WFE through the full helper", after.helper[HV_OP_WFE] == before.helper[HV_OP_WFE]);
}

/* A hang: where each CPU is and what the kicker last did, then fail. */
static void hung(int sig) {
    (void)sig;
    uint64_t now = mach_absolute_time();
    for (int i = 0; i < NCPU; i++) {
        HvCpu *c = &cpus[i];
        HvPerCpu *p = &m.percpu[i];
        printf("hung: cpu %d pc %llx el%u daif %llx x0 %llu x21 %llu ctl %llx cval %+lld us timer_due %+lld us guest_due %+lld us "
               "exit_req %u active %d irq %u wake_pending %d wfi %llu\n", i, (unsigned long long)c->pc, c->el,
               (unsigned long long)c->daif, (unsigned long long)c->x[0], (unsigned long long)c->x[21], (unsigned long long)c->cntv_ctl,
               (long long)((int64_t)(c->cntv_cval - (now - c->cntvoff)) / 24), (long long)((int64_t)(c->timer_due - now) / 24),
               (long long)((int64_t)(p->guest_due - now) / 24), (unsigned)c->exit_req, p->active, (unsigned)p->irq_line,
               p->wake_pending, (unsigned long long)p->own.stats.wfi);
    }
    printf("hung: kicker wakes %llu kicks %llu polls %llu, kick_at %+lld us, on %d\n", (unsigned long long)m.stats.kicker_wakes,
           (unsigned long long)m.stats.kicker_kicks, (unsigned long long)m.stats.kicker_polls,
           (long long)((int64_t)(m.kick_at - now) / 24), m.kicker_on);
    _exit(3);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    signal(SIGALRM, hung);
    alarm(240); /* a multi-CPU test that hangs fails, saying where each CPU was */
    if (hv_machine_init(&m, 16 << 20) != 0) return 1;
    m.stats_interval = 3600; /* counted as on a device (HV_STATS), never printed here */
    m.tick = tick;
    flag = aligned_alloc(16384, 16384);
    hv_machine_add_ram(&m, ADDR(mp_programs_begin), (uint64_t)(mp_programs_finish - mp_programs_begin), (void *)mp_programs_begin, 1);
    hv_machine_add_ram(&m, ADDR(flag), 16384, flag, 0);
    counters();
    timers();
    refresh_and_idle();
    resume_near_device_deadlines();
    wake_running();
    pv_calls();
    pv_locks();
    spinlock();
    printf("%d checks, %d failures\n", checks, failures);
    return failures != 0;
}
