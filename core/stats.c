/* The engine's measurements read as rates (stats.h). */
#include "stats.h"

double hv_stats_blocks_rate(HvMachine *m, HvRateMark *mark, uint64_t now) {
    uint64_t blocks = hv_stat_blocks(m);
    double rate = mark->ticks && now > mark->ticks && blocks >= mark->blocks /* (another machine since) */
                      ? (double)(blocks - mark->blocks) * 24e6 / (double)(now - mark->ticks)
                      : 0;
    mark->blocks = blocks;
    mark->ticks = now;
    return rate;
}
