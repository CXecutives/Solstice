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

#include "exception.h"
#include "pvg_vblank_clock.h"

extern const char mp_programs_begin[], mp_programs_finish[], mp_done[], mp_svc[], mp_timer_spin[], mp_timer_wfi[],
    mp_idle[], mp_spin[], mp_pv_probe[], mp_pv_pingpong[];
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

/* O9: timer interrupts 1 ms after they are set, 300 each on four CPUs: two spin in a loop that never leaves by itself
   (only a kick gets them out: the kicker's, at their deadline), two wait in WFI (until their deadline). On time, as
   far as the host's own timed waits allow; the spinning ones by a kick at nearly every deadline. */
static void timers(void) {
    const uint64_t n = 300, delay = 24000;
    static const char *const prog[NCPU] = {mp_timer_spin, mp_timer_spin, mp_timer_wfi, mp_timer_wfi};
    double slack_kicker = overshoot_us(QOS_CLASS_USER_INTERACTIVE, delay), slack_cpu = overshoot_us(QOS_CLASS_DEFAULT, delay);
    printf("timers: this host's 1 ms timed waits come back %.0f us late (kicker's QoS), %.0f us (CPU threads')\n", slack_kicker, slack_cpu);
    uint64_t kicks0 = m.stats.kicker_kicks;
    kicker_start();
    start(prog, n, delay, NULL);
    for (int i = 0; i < NCPU; i++) pthread_join(threads[i], NULL), threads[i] = 0;
    kicker_end();
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
        check(msg, max < 100000 + 3 * (i < 2 ? slack_kicker : slack_cpu));
    }
    printf("timers: the kicker kicked %llu CPUs at their deadline for %llu interrupts of the spinning CPUs\n",
           (unsigned long long)kicks, (unsigned long long)(2 * n));
    check("timers: the kicker brought the spinning CPUs out at their deadlines (nearly every interrupt)", kicks >= 2 * n * 8 / 10);
}

/* O9 + GFX-3: CPU 0's refresh deadline. A second with CPU 0 spinning (the kicker brings it out at each refresh and polls
   it every millisecond), then a second with every CPU in WFI (they wake at their own deadlines: the refresh, the 100 ms
   cap; the kicker looks only after those). Every refresh comes (60 a second), and the idle machine wakes rarely. */
static void refresh_and_idle(void) {
    const uint64_t period = 24000000 / 60;
    double slack_kicker = overshoot_us(QOS_CLASS_USER_INTERACTIVE, HV_POLL_BUSY), slack_wfi = overshoot_us(QOS_CLASS_DEFAULT, period);
    /* What the host's timed waits allow: one refresh per wakeup at most, one wakeup per period plus how late it comes. */
    double want_asleep = 1e6 / ((double)period / 24.0 + slack_wfi), want_polls = 1e6 / ((double)HV_POLL_BUSY / 24.0 + slack_kicker);
    if (want_asleep > 60) want_asleep = 60;
    printf("refresh: this host's timed waits come back %.0f us late after 1 ms (kicker), %.0f us after 16.7 ms (CPU threads)\n",
           slack_kicker, slack_wfi);
    refresh_on = 1;
    memset(&vclock, 0, sizeof vclock);
    poll_due = 0;
    kicker_start();
    for (int phase = 0; phase < 2; phase++) {
        static const char *const busy[NCPU] = {mp_spin, mp_idle, mp_idle, mp_idle}, *const idle[NCPU] = {mp_idle, mp_idle, mp_idle, mp_idle};
        start(phase ? idle : busy, 0, 0, NULL);
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
        if (!phase) { /* kicked at each refresh deadline: the kicker wakes far more often than 60 times a second */
            snprintf(msg, sizeof msg, "refresh, cpu 0 spinning: every 60 Hz refresh came (%.1f/s)", r);
            check(msg, r >= 57 && r <= 61.5);
            /* How often the kicker gets to run is the host's call (a busy CI VM gave 84/s against 181 it promised a
               moment before), so check what the engine decides: a poll at each kicker wakeup, not just at refreshes. */
            snprintf(msg, sizeof msg, "refresh, cpu 0 spinning: devices polled at each kicker wakeup (%.0f/s, %.0f wakeups/s; %.0f allowed by this host)", p, k, want_polls);
            check(msg, p >= 0.9 * k && p > r);
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
        finish(phase ? "idle" : "refresh");
    }
    kicker_end();
    refresh_on = 0;
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
    pv_calls();
    pv_locks();
    printf("%d checks, %d failures\n", checks, failures);
    return failures != 0;
}
