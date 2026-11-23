#ifndef HENGE_PVG_VBLANK_CLOCK_H
#define HENGE_PVG_VBLANK_CLOCK_H

#include <stdint.h>

typedef struct HvVblankClock {
    uint64_t next;
    int started;
} HvVblankClock;

/* A monotonic modulo-2^64 counter; deadlines must be less than 2^63 ticks away.
   Emit at most once per poll and preserve the original phase after late polls.
   The next deadline advances by less than one period from now, so there is no
   potentially overflowing (missed periods * period) multiplication. Unsigned
   additions/subtractions intentionally wrap with the underlying counter. */
static inline int hv_vblank_due(HvVblankClock *clock, uint64_t now, uint64_t period) {
    if (!period || period > INT64_MAX) return 0;
    if (!clock->started) {
        clock->started = 1;
        clock->next = now + period;
        return 1;
    }
    uint64_t late = now - clock->next;
    if (late > INT64_MAX) return 0; /* deadline is still ahead, including across wrap */
    clock->next = now + (period - late % period);
    return 1;
}

/* The refresh hv_vblank_due just reported, on its grid: the latest grid time at or before now (a whole number of
   periods after the first), so the guest's timestamps are a period apart however late the poll came. */
static inline uint64_t hv_vblank_at(const HvVblankClock *clock, uint64_t period) {
    return clock->next - period;
}

/* When the next refresh is due: a device deadline (0 before the first). */
static inline uint64_t hv_vblank_next(const HvVblankClock *clock) {
    return clock->started ? clock->next : 0;
}

/* The host's presents, apart from the guest's refreshes above: macOS is told the mode's rate and refreshed at it
   whatever the host shows. Seconds between presents for a mode refreshing every mode_every seconds, when at most
   cap_hz frames a second may go to the screen (0: no cap; a cap at or above the mode's rate changes nothing). */
static inline double hv_present_every(double mode_every, int cap_hz) {
    double capped = cap_hz > 0 ? 1.0 / cap_hz : 0;
    return capped > mode_every ? capped : mode_every;
}

/* How long the presenter waits before it takes the newest frame for its next present, every being what
   hv_present_every gave: under a cap, until a whole interval after the last present, so the frame shown is the newest
   there is then (not one queued behind three drawables, 100 ms at 30 Hz). At the mode's own rate, not at all: frames
   come no faster than that, and the layer holds each for the rest of the refresh (afterMinimumDuration) as before. */
static inline double hv_present_wait(double last_present, double now, double mode_every, double every) {
    if (every <= mode_every) return 0;
    double wait = last_present + every - now;
    return wait > 0 ? wait : 0;
}

#endif
