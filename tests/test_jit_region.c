#include "jit_region.h"
#include "knobs.h"

#include <stdio.h>
#include <stdlib.h>

/* Both shapes: macOS MAP_JIT, and the iOS split mapping (RX plus an RW alias). */
static int one(const char *what) {
    HvJitRegion region;
    if (hv_jit_region_open(&region, 1 << 20) != 0) {
        printf("%s: could not map the JIT region\n", what);
        return 1;
    }
    uint32_t *code = hv_jit_reserve(&region, 2);
    static const uint32_t body[2] = {0xd2800540, 0xd65f03c0}; /* mov x0, #42; ret */
    hv_jit_write(&region, code, body, sizeof body);
    hv_jit_finish(&region, code, 2);
    long (*fn)(void) = (long (*)(void))code;
    long got = fn();
    printf("%s: jit region returned %ld\n", what, got);
    hv_jit_region_close(&region);
    return got != 42;
}

/* A claim that only gets regions up to `most` bytes (the debugger finding no larger hole), or none at all. */
typedef struct {
    size_t most, smallest_asked;
    int calls, no_debugger;
} Seam;

static int seam_claim(size_t bytes, void *ctx) {
    Seam *s = ctx;
    s->calls++;
    if (!s->smallest_asked || bytes < s->smallest_asked) s->smallest_asked = bytes;
    if (s->no_debugger) return -1;
    return bytes <= s->most;
}

/* The region asked for at launch falls back to halves, down to the least (the device table's), when it cannot be had. */
static int fallback(void) {
    const size_t mb = 1u << 20, min = 128 * mb;
    int bad = 0;
    Seam s = {.most = 300 * mb};
    size_t got = hv_jit_claim_halving(1024 * mb, min, seam_claim, &s);
    printf("fallback: 1024 MB asked, 300 MB the most there is: %zu MB after %d tries\n", got / mb, s.calls);
    bad |= got != 256 * mb || s.calls != 3;
    s = (Seam){.most = 0};
    got = hv_jit_claim_halving(384 * mb, min, seam_claim, &s);
    printf("fallback: none at any size: %zu bytes, the smallest asked %zu MB\n", got, s.smallest_asked / mb);
    bad |= got != 0 || s.smallest_asked < min || s.smallest_asked % 16384;
    s = (Seam){.most = ~(size_t)0};
    got = hv_jit_claim_halving(384 * mb, min, seam_claim, &s);
    bad |= got != 384 * mb || s.calls != 1;
    s = (Seam){.no_debugger = 1};
    got = hv_jit_claim_halving(1024 * mb, min, seam_claim, &s);
    printf("fallback: no debugger: %d try\n", s.calls);
    bad |= got != 0 || s.calls != 1;
    printf("fallback: %s\n", bad ? "FAIL" : "ok");
    return bad;
}

int main(void) {
    int bad = fallback();
    bad |= one("MAP_JIT");
    setenv("HV_JIT_SPLIT", "1", 1);
    hv_knobs_load(); /* no machine here to load it */
    bad |= one("split");
    return bad;
}
