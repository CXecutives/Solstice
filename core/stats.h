#ifndef HENGEVM_STATS_H
#define HENGEVM_STATS_H

#include <stdint.h>

#include "machine.h"

/* The engine's measurements as rates (stats.c). */

/* Where a rate was last read: the caller keeps it, one per reader. */
typedef struct HvRateMark {
    uint64_t blocks, ticks;
} HvRateMark;

/* Dispatcher entries per second, all CPUs, averaged since the mark (now: mach_absolute_time ticks, 24 MHz); the mark
   moves to now. 0 on the first read of a mark, or when no time passed. */
double hv_stats_blocks_rate(HvMachine *m, HvRateMark *mark, uint64_t now);

#endif
