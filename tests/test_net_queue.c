// The queue between the network thread and the CPU (host/net_queue.c): a wake only into an empty queue, frames come
// out whole and in order through many laps of the ring, big frames and an exhausted slab fall back to malloc, a full
// queue drops and counts, the peak is kept, and a producer on another thread loses nothing.
#include "../host/net_queue.h"

#include <pthread.h>
#include <stdio.h>
#include <string.h>

static int failures, checks;

static void check(const char *what, unsigned long long got, unsigned long long want) {
    checks++;
    if (got != want) printf("  FAIL %s: got %llu, want %llu\n", what, got, want), failures++;
}

static HvNetQueue q;

static void fill(uint8_t *p, uint32_t len, uint32_t seed) {
    for (uint32_t i = 0; i < len; i++) p[i] = (uint8_t)(seed * 31 + i);
}

static int matches(const HvNetFrame *f, uint32_t len, uint32_t seed) {
    if (f->len != len) return 0;
    for (uint32_t i = 0; i < len; i++)
        if (f->data[i] != (uint8_t)(seed * 31 + i)) return 0;
    return 1;
}

#define THREAD_FRAMES 100000
static void *producer(void *arg) {
    (void)arg;
    uint8_t frame[64];
    for (uint32_t i = 0; i < THREAD_FRAMES;) {
        fill(frame, sizeof frame, i);
        if (hv_netq_push(&q, frame, sizeof frame)) i++; /* full: try again, the consumer drains */
    }
    return NULL;
}

int main(void) {
    static uint8_t frame[HV_NETQ_BUF * 4];
    hv_netq_init(&q);
    check("empty", hv_netq_waiting(&q), 0);
    fill(frame, 60, 1);
    check("into an empty queue: wake", hv_netq_push(&q, frame, 60), 2);
    fill(frame, 70, 2);
    check("behind another: no wake", hv_netq_push(&q, frame, 70), 1);
    check("two waiting", hv_netq_waiting(&q), 2);
    check("first frame whole", matches(hv_netq_at(&q, 0), 60, 1), 1);
    check("second frame whole", matches(hv_netq_at(&q, 1), 70, 2), 1);
    hv_netq_pop(&q, 1);
    check("one left", hv_netq_waiting(&q), 1);
    check("the second is now first", matches(hv_netq_at(&q, 0), 70, 2), 1);
    hv_netq_pop(&q, 1);
    fill(frame, 60, 3);
    check("empty again: wake again", hv_netq_push(&q, frame, 60), 2);
    hv_netq_pop(&q, 1);

    /* Many laps, sizes on both sides of a slab buffer. */
    int ok = 1;
    for (uint32_t i = 0; i < 5000; i++) {
        uint32_t len = i % 7 == 0 ? HV_NETQ_BUF + 1 + i % 100 : 14 + i % HV_NETQ_BUF;
        fill(frame, len, i);
        if (!hv_netq_push(&q, frame, len)) ok = 0;
        if (i % 3 == 2) {
            uint32_t n = hv_netq_waiting(&q);
            for (uint32_t k = 0; k < n; k++) {
                uint32_t j = i + 1 - n + k;
                uint32_t want = j % 7 == 0 ? HV_NETQ_BUF + 1 + j % 100 : 14 + j % HV_NETQ_BUF;
                if (!matches(hv_netq_at(&q, k), want, j)) ok = 0;
            }
            hv_netq_pop(&q, n);
        }
    }
    hv_netq_pop(&q, hv_netq_waiting(&q));
    check("5000 frames through the ring, whole and in order", ok, 1);
    check("every slab buffer back", q.nfree, HV_NETQ_SLAB);

    /* Full: more slots than slab buffers, so the last ones are malloc'd; then drops, counted. */
    q.peak = 0;
    for (uint32_t i = 0; i < HV_NETQ_LEN; i++) {
        fill(frame, 100, i);
        hv_netq_push(&q, frame, 100);
    }
    check("full queue holds them all", hv_netq_waiting(&q), HV_NETQ_LEN);
    check("slab used up", q.nfree, 0);
    check("past the slab: malloc'd", hv_netq_at(&q, HV_NETQ_LEN - 1)->slab, (unsigned long long)-1);
    check("past the slab: whole", matches(hv_netq_at(&q, HV_NETQ_LEN - 1), 100, HV_NETQ_LEN - 1), 1);
    uint64_t dropped = q.dropped;
    check("full: dropped", hv_netq_push(&q, frame, 100), 0);
    check("the drop counted", q.dropped - dropped, 1);
    check("peak", q.peak, HV_NETQ_LEN);
    hv_netq_pop(&q, HV_NETQ_LEN);
    check("all slab buffers back after a full queue", q.nfree, HV_NETQ_SLAB);

    /* A producer thread against this consumer: nothing lost, nothing reordered. */
    pthread_t t;
    pthread_create(&t, NULL, producer, NULL);
    uint32_t seen = 0;
    ok = 1;
    while (seen < THREAD_FRAMES) {
        uint32_t n = hv_netq_waiting(&q);
        for (uint32_t k = 0; k < n; k++)
            if (!matches(hv_netq_at(&q, k), 64, seen + k)) ok = 0;
        hv_netq_pop(&q, n);
        seen += n;
    }
    pthread_join(t, NULL);
    check("two threads: every frame, in order", ok, 1);
    check("two threads: all of them", seen, THREAD_FRAMES);

    /* What is still queued at the end is freed. */
    fill(frame, HV_NETQ_BUF * 2, 9);
    hv_netq_push(&q, frame, HV_NETQ_BUF * 2);
    hv_netq_destroy(&q);
    printf("net queue: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
