#ifndef SOLSTICEVM_STATS_H
#define SOLSTICEVM_STATS_H

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

/* The stats line, every HvMachine.stats_interval seconds: each CPU's dispatcher loop asks every 4096 of its entries
   whether it is due, and the CPU that finds it due prints it. */
void hv_stats_tick(HvCpu *cpu);
/* Set by the host: more lines for the stats, from the devices' data paths (network, sound), over `seconds`. */
extern void (*hv_stats_io)(double seconds);
/* Stats lines printed, for the tests. */
extern uint64_t hv_stats_lines;
/* Deep stats: MRS/MSR/SYS by op0:op1:CRn:CRm:op2 (the helper counts them); reads low, writes high 32 bits. */
extern uint64_t hv_reg_hist[65536];

#endif
