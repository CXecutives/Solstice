#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#include "pvg_lite.h"
#include "vmapple.h"
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

/* Exercise real Metal command completion while the guest board is destroyed.
   Empty execs avoid simulator limitations on guest buffer-backed textures. */
static HvMachine machine;
static HvCpu cpus[2];
static HvVmapple board;
static int failures;

static void check(const char *what, uint64_t got, uint64_t want) {
    if (got == want) return;
    printf("  FAIL %s: %llx, expected %llx\n", what, (unsigned long long)got, (unsigned long long)want);
    failures++;
}

/* A task the way the guest's driver lays one out: 16 KB pages, a root page {table page, depth}, a leaf table of page
   numbers, an object list of 12-byte entries {type | size << 8, offset}. Guest page numbers from G0 on. */
#define G0 ((VMAPPLE_MEM + (16ull << 20)) >> 14)
#define TASK 7
#define LIST 0x100   /* task offset of the object list */
#define SAMPLERS 64  /* refs 1...64 */
#define RESULT 100   /* a 16 KB buffer on task page 10 */
static uint8_t *gpage(uint64_t page) { return hv_phys_ptr(&machine, page << 14, 0x4000); }
static const uint64_t task_pages[11] = {
    G0 + 2,          /* 0: object list, sampler and buffer records */
    G0 + 3, G0 + 4,  /* 1, 2: one after the other in guest memory: a command buffer read where it is */
    G0 + 6, G0 + 5,  /* 3, 4: the other way round: one that has to be copied out */
    G0 + 7, G0 + 8, G0 + 9, G0 + 10, /* 5...8: 10,000 bindings */
    0,               /* 9: not mapped */
    G0 + 12,         /* 10: the result buffer */
};
static void task_write(uint64_t off, const void *from, uint64_t n) {
    const uint8_t *s = from;
    while (n) {
        uint64_t in = off & 0x3fff, c = 0x4000 - in < n ? 0x4000 - in : n;
        memcpy(gpage(task_pages[off >> 14]) + in, s, c);
        s += c, off += c, n -= c;
    }
}

/* Where pvg_lite keeps a field, found in its state blob by what the field does: the blob's layout is its own. */
static long find_field(uint8_t *blob, size_t size, unsigned width, uint64_t value, int (*works)(void)) {
    uint8_t *trial = malloc(size);
    long found = -1;
    for (size_t at = 0; at + width <= size && found < 0; at += width) {
        memcpy(trial, blob, size);
        memcpy(trial + at, &value, width);
        hv_pvg_lite_set_state(board.pvg, trial, size);
        if (works()) found = (long)at;
    }
    hv_pvg_lite_set_state(board.pvg, blob, size);
    free(trial);
    return found;
}
static int objects_named(void) { return hv_pvg_lite_task_objects(board.pvg, TASK) == LIST; }
static int root_named(void) { return hv_pvg_lite_task_page(board.pvg, TASK, 0) == task_pages[0]; }

static uint32_t *exec_cmd(uint32_t stamp, int nbuf, const void *bufs, uint32_t *len) {
    *len = 12 + 12 + 16u * (uint32_t)nbuf;
    uint32_t *cmd = calloc(1, *len);
    cmd[0] = 0x43, cmd[1] = *len, cmd[2] = stamp;
    cmd[3] = TASK, cmd[4] = 0, cmd[5] = (uint32_t)nbuf;
    memcpy(cmd + 6, bufs, 16u * (uint32_t)nbuf);
    return cmd;
}

/* The replay's object lookups, task memory walks and command buffer reads: every sampler named by an info record,
   from a command buffer read in place and from one copied out, is found and made; then 10,000 bindings an exec. */
static void test_replay(void) {
    HvCfgParams cfg = {.nr_cpus = 2};
    if (hv_machine_init(&machine, 4 << 20) ||
        hv_vmapple_reserve_ram(&board, 64 << 20) || hv_vmapple_create(&board, &machine, cpus, NULL, NULL, &cfg, NULL)) { failures++; return; }
    hv_vmapple_reset_cpu(&board);
    for (int i = 0; i < 16; i++) memset(gpage(G0 + (uint64_t)i), 0, 0x4000);
    uint32_t *root = (uint32_t *)gpage(G0), *table = (uint32_t *)gpage(G0 + 1);
    root[0] = (uint32_t)(G0 + 1), root[1] = 1;
    for (int v = 0; v < 11; v++) table[v] = (uint32_t)task_pages[v];
    for (uint32_t k = 1; k <= SAMPLERS; k++) {
        /* a sampler: {tag, size, ref, bits, lod min, lod max}; each its own LOD range, so Metal cannot hand back one
           object for two */
        float lod[2] = {(float)k, 1000.0f + (float)k};
        uint32_t rec[7] = {3, 28, k, 0, 0, 0, 0};
        memcpy(rec + 5, lod, 8);
        uint64_t at = 0x2000 + k * 32;
        uint32_t entry[3] = {7 | 28u << 8, (uint32_t)at, (uint32_t)(at >> 32)};
        task_write(at, rec, sizeof rec);
        task_write(LIST + k * 12ull, entry, 12);
    }
    uint32_t buffer[4] = {0x4000, 0, 10, 0}; /* {length, page, flags} */
    uint32_t entry[3] = {1 | 16u << 8, 0x3000, 0};
    task_write(0x3000, buffer, sizeof buffer);
    task_write(LIST + RESULT * 12ull, entry, 12);
    /* Two info segments, each across a page boundary: refs 1-32 where the pages follow each other, 33-64 where not.
       Info 460 writes each object's identifier into the result buffer at ref * 8. */
    uint64_t seg_at[2] = {0x4000 + 0x3f00, 3 * 0x4000 + 0x3f00}, bufs[3][2];
    for (int s = 0; s < 2; s++) {
        uint8_t seg[8 + 32 * 28];
        uint32_t head[2] = {32 * 28, 4}; /* {length, type 4} */
        memcpy(seg, head, 8);
        for (uint32_t i = 0; i < 32; i++) {
            uint32_t ref = 1 + (uint32_t)s * 32 + i, rec[7] = {460, 28, ref, 0, RESULT, ref * 8, 0};
            memcpy(seg + 8 + i * 28, rec, 28);
        }
        task_write(seg_at[s], seg, sizeof seg);
        bufs[s][0] = seg_at[s], bufs[s][1] = sizeof seg;
    }
    /* A compute segment of 625 records each binding 16 samplers. */
    enum { RECS = 625, REC = 8 + 8 + 64 };
    uint8_t *bind = malloc(8 + RECS * REC);
    uint32_t bhead[2] = {RECS * REC, 1};
    memcpy(bind, bhead, 8);
    for (uint32_t i = 0; i < RECS; i++) {
        uint32_t rec[REC / 4] = {204, REC, 0, 16};
        for (uint32_t j = 0; j < 16; j++) rec[4 + j] = 1 + (i * 16 + j) % SAMPLERS;
        memcpy(bind + 8 + i * REC, rec, REC);
    }
    task_write(5 * 0x4000, bind, 8 + RECS * REC);
    bufs[2][0] = 5 * 0x4000, bufs[2][1] = 8 + RECS * REC;
    free(bind);

    HvPvgMetal *metal = hv_pvg_metal_create(board.pvg);
    if (!metal) { failures++; return; }
    size_t size = hv_pvg_lite_state(board.pvg, NULL, 0);
    uint8_t *blob = malloc(size);
    hv_pvg_lite_state(board.pvg, blob, size);
    long objects_at = find_field(blob, size, 8, LIST, objects_named);
    if (objects_at >= 0) { uint64_t v = LIST; memcpy(blob + objects_at, &v, 8); }
    long root_at = find_field(blob, size, 4, G0, root_named);
    if (root_at >= 0) { uint32_t v = (uint32_t)G0; memcpy(blob + root_at, &v, 4); }
    check("task object list set up", objects_at >= 0, 1);
    check("task root set up", root_at >= 0, 1);
    hv_pvg_lite_set_state(board.pvg, blob, size);
    free(blob);

    uint32_t len, stamp = 1;
    hv_pvg_metal_submit(metal, board.pvg, 0, exec_cmd(stamp++, 3, bufs, &len), len);
    hv_pvg_metal_display_state(metal, NULL, 0); /* a round trip through the worker: the exec has run */
    const uint64_t *ids = (const uint64_t *)gpage(task_pages[10]);
    int found = 0;
    for (uint32_t k = 1; k <= SAMPLERS; k++) found += ids[k] != 0;
    check("every sampler found, in place and copied", (uint64_t)found, SAMPLERS);
    check("the identifiers are each object's own", ids[1] != ids[2] && ids[33] != ids[34], 1);
    /* Named again, a ref is the same object. */
    uint64_t first = ids[5];
    memset(gpage(task_pages[10]), 0, 0x4000);
    hv_pvg_metal_submit(metal, board.pvg, 0, exec_cmd(stamp++, 1, bufs, &len), len);
    hv_pvg_metal_display_state(metal, NULL, 0);
    check("a ref names the same object next time", ids[5], first);
    /* A deleted ref (op 0x25 {task, ref}) is made again, as a new object. */
    uint32_t *del = calloc(5, 4);
    del[0] = 0x25, del[1] = 20, del[2] = stamp++, del[3] = TASK, del[4] = 5;
    hv_pvg_metal_submit(metal, board.pvg, 0, del, 20);
    hv_pvg_metal_display_state(metal, NULL, 0);
    memset(gpage(task_pages[10]), 0, 0x4000);
    hv_pvg_metal_submit(metal, board.pvg, 0, exec_cmd(stamp++, 1, bufs, &len), len);
    hv_pvg_metal_display_state(metal, NULL, 0);
    check("a deleted ref is made again", ids[5] != 0, 1);

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < 20; i++)
        hv_pvg_metal_submit(metal, board.pvg, 0, exec_cmd(stamp++, 1, bufs[2], &len), len);
    hv_pvg_metal_display_state(metal, NULL, 0);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double us = ((t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec)) / 1e3 / 20;
    printf("replay: 10000 bindings an exec, %.0f us an exec (%.0f ns a binding)\n", us, us * 1000 / 10000);
    hv_pvg_metal_destroy(metal);
    hv_vmapple_destroy(&board);
    hv_machine_free(&machine);
}

int main(void) {
    alarm(60);
    for (int cycle = 0; cycle < 6; cycle++) @autoreleasepool {
        HvCfgParams cfg = {.nr_cpus = 2};
        if (hv_machine_init(&machine, 4 << 20) ||
            hv_vmapple_reserve_ram(&board, 64 << 20) || hv_vmapple_create(&board, &machine, cpus, NULL, NULL, &cfg, NULL)) return 1;
        hv_vmapple_reset_cpu(&board);
        HvPvgMetal *metal = hv_pvg_metal_create(board.pvg);
        if (!metal) { fprintf(stderr, "Metal replay unavailable; lifecycle test cannot run\n"); return 1; }
        CAMetalLayer *layer = [CAMetalLayer layer];
        hv_pvg_metal_set_layer(metal, (__bridge void *)layer);
        for (int i = 0; i < 64; i++) {
            uint32_t *cmd = calloc(6, sizeof *cmd);
            cmd[0] = 0x43; cmd[1] = 24; cmd[2] = i + 1;
            hv_pvg_metal_submit(metal, board.pvg, 0, cmd, 24);
        }
        hv_pvg_metal_cursor_moved(metal);
        hv_pvg_metal_set_layer(metal, NULL);
        hv_pvg_metal_destroy(metal);
        hv_vmapple_destroy(&board);
        hv_machine_free(&machine);
    }
    puts("Metal lifecycle: 6 cycles, 384 GPU completions drained");
    @autoreleasepool { test_replay(); }
    if (failures) printf("%d failures\n", failures);
    return failures != 0;
}
