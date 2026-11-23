#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include "pvg_vblank_clock.h"

#define TICKS_PER_SECOND 24000000ull

/* Polling at 1 ms is deliberately incommensurate with 30/60/120 Hz.
   Compare event counts against the requested frequency, not helper internals. */
static void cadence(unsigned hz) {
    HvVblankClock clock = {0};
    uint64_t period = TICKS_PER_SECOND / hz, old_next = 0;
    unsigned events = 0, old_events = 0;
    for (uint64_t now = 0; now < 10 * TICKS_PER_SECOND; now += TICKS_PER_SECOND / 1000) {
        events += hv_vblank_due(&clock, now, period);
        if (now >= old_next) { old_events++; old_next = now + period; }
    }
    assert(events == 10 * hz);
    assert(old_events < events);
    printf("%u Hz, 10 s of 1 ms polls: old %u events, phase-preserving %u\n", hz, old_events, events);
}

static void boundary_and_stall(void) {
    HvVblankClock clock = {0};
    uint64_t period = TICKS_PER_SECOND / 60;
    assert(hv_vblank_due(&clock, 17, period));
    assert(!hv_vblank_due(&clock, 17 + period - 1, period));
    assert(hv_vblank_due(&clock, 17 + period, period));
    assert(!hv_vblank_due(&clock, 17 + period, period));
    /* One late event after an hour, then silence until the next anchored slot. */
    uint64_t late = 17 + 3600 * TICKS_PER_SECOND + period / 2;
    assert(hv_vblank_due(&clock, late, period));
    assert(!hv_vblank_due(&clock, late, period));
    uint64_t expected = 17 + 3600 * TICKS_PER_SECOND + period;
    assert(!hv_vblank_due(&clock, expected - 1, period));
    assert(hv_vblank_due(&clock, expected, period));
    assert(!hv_vblank_due(&clock, expected, period));
}

static void wrap_and_invalid_period(void) {
    HvVblankClock clock = {0};
    assert(!hv_vblank_due(&clock, 0, 0) && !clock.started);
    assert(!hv_vblank_due(&clock, 0, UINT64_MAX) && !clock.started);
    /* A 40-tick schedule begins 20 ticks before wrap: deadline wraps to 19. */
    assert(hv_vblank_due(&clock, UINT64_MAX - 20, 40));
    assert(!hv_vblank_due(&clock, UINT64_MAX - 1, 40));
    assert(!hv_vblank_due(&clock, 18, 40));
    assert(hv_vblank_due(&clock, 19, 40));
    assert(!hv_vblank_due(&clock, 19, 40));
    assert(!hv_vblank_due(&clock, 58, 40));
    assert(hv_vblank_due(&clock, 59, 40));
    /* A late poll across wrap skips missed periods, retaining the same phase. */
    assert(hv_vblank_due(&clock, 150, 40));
    assert(!hv_vblank_due(&clock, 178, 40));
    assert(hv_vblank_due(&clock, 179, 40));
}

/* What +0x68 gets (hv_vblank_at) is on the grid of the first refresh, a whole number of periods apart and never after
   the poll, however irregular and late the polls; hv_vblank_next (CPU 0's device deadline) is the next grid time, after
   now and at most a period away. Polls exactly at that deadline (as the kicker and WFI make them) send every refresh. */
static void grid_times_and_deadline(void) {
    HvVblankClock clock = {0};
    const uint64_t period = TICKS_PER_SECOND / 60, first = 1000;
    assert(!hv_vblank_next(&clock));
    uint64_t now = first, last = 0, origin = 0, s = 12345;
    unsigned events = 0;
    for (int i = 0; i < 200000; i++) {
        s = s * 6364136223846793005ull + 1442695040888963407ull;
        now += (s >> 40) % (3 * period); /* 0 to 3 periods: early, on time, and late polls that skip refreshes */
        if (!hv_vblank_due(&clock, now, period)) continue;
        uint64_t at = hv_vblank_at(&clock, period), next = hv_vblank_next(&clock);
        if (!events) origin = at;
        assert(at <= now && now - at < period);
        assert((at - origin) % period == 0);
        assert(!events || at > last);
        assert(next == at + period && next > now);
        last = at;
        events++;
    }
    assert(events > 1000);
    HvVblankClock exact = {0};
    unsigned n = 0;
    for (now = 5; now < 10 * TICKS_PER_SECOND;) {
        n += hv_vblank_due(&exact, now, period);
        now = hv_vblank_next(&exact);
    }
    assert(n == 600);
    printf("vblank grid: %u refreshes at grid times over random polls; 600 in 10 s polled at each deadline\n", events);
}

/* The presenter (pvg_metal.m, presentLoop) over 10 s of a guest drawing at every refresh of its mode: woken by a new
   frame, it waits as hv_present_wait says and then shows the newest frame there is; the cap can change at switch_at
   (henge_vm_set_power_profile, live). Returns the presents; *stale is the oldest a shown frame was when it went out. */
static unsigned paced(unsigned mode_hz, int cap_before, int cap_after, double switch_at, double *stale) {
    const double mode_every = 1.0 / mode_hz;
    double last = -1e9, worst = 0;
    unsigned n = 0;
    for (uint64_t k = 0; k < 10ull * mode_hz;) { /* frame k is drawn at k * mode_every */
        double woke = (double)k * mode_every;
        double every = hv_present_every(mode_every, woke < switch_at ? cap_before : cap_after);
        double at = woke + hv_present_wait(last, woke, mode_every, every);
        uint64_t newest = (uint64_t)floor(at * mode_hz + 1e-6);
        assert(newest >= k);
        if (at - (double)newest * mode_every > worst) worst = at - (double)newest * mode_every;
        if (n && every > mode_every) assert(at - last >= every - 1e-9); /* never faster than the cap */
        last = at;
        n++;
        k = newest + 1; /* asleep until a frame newer than the one it showed */
    }
    *stale = worst;
    return n;
}

static void present_pacing(void) {
    assert(hv_present_every(1.0 / 60, 0) == 1.0 / 60);
    assert(hv_present_every(1.0 / 60, 30) == 1.0 / 30);
    assert(hv_present_every(1.0 / 30, 60) == 1.0 / 30); /* a cap above the mode's rate changes nothing */
    double stale;
    assert(paced(60, 0, 0, 99, &stale) == 600 && stale < 1e-9); /* uncapped: every frame, as it comes */
    assert(paced(60, 120, 120, 99, &stale) == 600);
    unsigned capped = paced(60, 30, 30, 99, &stale);
    assert(capped >= 299 && capped <= 301 && stale < 1.0 / 60); /* the newest frame, not a queued one */
    unsigned fast = paced(120, 30, 30, 99, &stale);
    assert(fast >= 299 && fast <= 301 && stale < 1.0 / 120);
    unsigned hot = paced(60, 0, 30, 5, &stale), cooled = paced(60, 30, 0, 5, &stale); /* the cap changes live */
    assert(hot >= 448 && hot <= 452 && cooled >= 448 && cooled <= 452);
    printf("present pacing: 60 Hz frames, %u presents in 10 s under a 30 Hz cap, %u and %u with it on and off halfway\n",
           capped, hot, cooled);
}

/* The refreshes as pvg_lite.c makes them, over 10 s: CPU 0 polls at its refresh deadline (hv_vblank_deadline: none
   while the guest masks event 8) and at least every 20 ms (HV_DEV_SAFETY); stalled (no poll) over [stall_at, +1 s) when
   stall_at >= 0. The cap is cap_before until switch_at, then cap_after; the guest masks event 8 over [mask_from,
   mask_to). Checks what the guest gets: an event only while it listens, the refresh times (+0x68) never after the poll
   and at least the shorter of the two periods apart, and no burst after a stall or an unmask. Returns the events. */
struct Run { unsigned mode_hz; int cap_before, cap_after; double switch_at, mask_from, mask_to, stall_at; };
static unsigned refreshes(struct Run r, unsigned *masked_polls) {
    const uint64_t safety = TICKS_PER_SECOND / 50, mode = TICKS_PER_SECOND / r.mode_hz;
    HvVblankClock clock = {0};
    uint64_t now = 0, last_poll = 0, last_at = 0, last_event = 0, end = 10 * TICKS_PER_SECOND;
    uint64_t shortest = hv_vblank_period(mode, r.cap_before, TICKS_PER_SECOND), other = hv_vblank_period(mode, r.cap_after, TICKS_PER_SECOND);
    if (other < shortest) shortest = other;
    unsigned events = 0, stamps = 0;
    *masked_polls = 0;
    while (now < end) {
        double t = (double)now / TICKS_PER_SECOND;
        int listening = !(t >= r.mask_from && t < r.mask_to);
        if (!listening) ++*masked_polls;
        uint64_t period = hv_vblank_period(mode, t < r.switch_at ? r.cap_before : r.cap_after, TICKS_PER_SECOND);
        if (hv_vblank_due(&clock, now, period)) {
            uint64_t at = hv_vblank_at(&clock, period);
            assert(at <= now);
            assert(!stamps || at - last_at >= shortest); /* +0x68 moves on by whole refreshes, never back */
            last_at = at;
            stamps++;
            if (listening) {
                /* No burst: one event per refresh time, never two inside the shorter period (after a stall or an unmask
                   the late one comes at once, the next on the grid: still a period after the late one's time). */
                assert(!events || now > last_event);
                events++;
                last_event = now;
            }
        }
        last_poll = now;
        uint64_t next = last_poll + safety, due = hv_vblank_deadline(&clock, listening);
        if (due && due < next) next = due;
        if (r.stall_at >= 0 && t < r.stall_at && (double)next / TICKS_PER_SECOND >= r.stall_at)
            next = (uint64_t)((r.stall_at + 1) * TICKS_PER_SECOND); /* the CPU was away for a second */
        now = next > now ? next : now + 1;
    }
    return events;
}

static void cap_and_mask(void) {
    unsigned mp, mpm;
    assert(hv_vblank_period(0, 30, TICKS_PER_SECOND) == 0);                                 /* no refreshes stay none */
    assert(hv_vblank_period(TICKS_PER_SECOND / 60, 0, TICKS_PER_SECOND) == TICKS_PER_SECOND / 60);
    assert(hv_vblank_period(TICKS_PER_SECOND / 60, 30, TICKS_PER_SECOND) == TICKS_PER_SECOND / 30);
    assert(hv_vblank_period(TICKS_PER_SECOND / 30, 60, TICKS_PER_SECOND) == TICKS_PER_SECOND / 30); /* a faster cap: the mode */
    HvVblankClock c = {0};
    assert(hv_vblank_due(&c, 100, 1000) && hv_vblank_deadline(&c, 1) == 1100 && hv_vblank_deadline(&c, 0) == 0);
    unsigned n60 = refreshes((struct Run){60, 0, 0, 99, 99, 99, -1}, &mp);
    unsigned n30 = refreshes((struct Run){60, 30, 30, 99, 99, 99, -1}, &mp);
    unsigned n120 = refreshes((struct Run){120, 30, 30, 99, 99, 99, -1}, &mp);
    assert(n60 >= 599 && n60 <= 601);
    assert(n30 >= 299 && n30 <= 301 && n120 >= 299 && n120 <= 301); /* at the cap's rate under a cap */
    unsigned hot = refreshes((struct Run){60, 0, 30, 5, 99, 99, -1}, &mp), cooled = refreshes((struct Run){60, 30, 0, 5, 99, 99, -1}, &mp);
    assert(hot >= 448 && hot <= 452 && cooled >= 448 && cooled <= 452); /* the cap switched live */
    unsigned masked = refreshes((struct Run){60, 0, 0, 99, 2, 4, -1}, &mpm);
    assert(masked >= 478 && masked <= 482); /* 8 s listening */
    assert(mpm <= 2 * 50 + 2);             /* while masked: the 20 ms polls only, no 60 Hz deadline */
    unsigned stalled = refreshes((struct Run){60, 0, 0, 99, 99, 99, 3.5}, &mp);
    assert(stalled >= 539 && stalled <= 542); /* a second missing, one late refresh after it, then the grid */
    printf("cap and mask: 60 Hz %u, capped to 30 %u (120 Hz mode %u), cap on and off halfway %u and %u, masked 2 s %u "
           "(%u polls meanwhile), a 1 s stall %u\n", n60, n30, n120, hot, cooled, masked, mpm, stalled);
}

int main(void) {
    cadence(30); cadence(60); cadence(120);
    boundary_and_stall();
    wrap_and_invalid_period();
    grid_times_and_deadline();
    present_pacing();
    cap_and_mask();
    puts("vblank clock: cadence, exact deadlines, long stalls, counter wrap and present pacing passed");
    return 0;
}
