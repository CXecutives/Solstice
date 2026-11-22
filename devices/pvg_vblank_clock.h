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

#endif
