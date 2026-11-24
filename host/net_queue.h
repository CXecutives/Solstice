#ifndef SOLSTICEVM_NET_QUEUE_H
#define SOLSTICEVM_NET_QUEUE_H

#include <pthread.h>
#include <stdint.h>

/* A queue of Ethernet frames between two threads (net_slirp.c: the guest's to the network thread, and back).
   One producer side, under the lock; one consumer, which takes a whole batch under one lock, works on it unlocked
   (nothing else touches those slots until it pops them) and pops it under one more. Frames up to HV_NETQ_BUF bytes
   live in the queue's own buffers, larger ones (or with all of those in use) in malloc'd memory. */
#define HV_NETQ_LEN 512
#define HV_NETQ_BUF 2048
#define HV_NETQ_SLAB 256

typedef struct HvNetFrame {
    uint32_t len;
    int32_t slab; /* the buffer's index, or -1: malloc'd */
    uint8_t *data;
} HvNetFrame;

typedef struct HvNetQueue {
    pthread_mutex_t mu;
    uint32_t head, tail;
    HvNetFrame f[HV_NETQ_LEN];
    uint32_t nfree;
    uint16_t free[HV_NETQ_SLAB];
    uint8_t slab[HV_NETQ_SLAB][HV_NETQ_BUF];
    /* For the stats (atomics, read without the lock): frames dropped because the queue was full, and the most it held
       (the stats set it back to 0 for each interval). */
    uint64_t dropped;
    uint32_t peak;
} HvNetQueue;

void hv_netq_init(HvNetQueue *q);
/* Frees what is still queued. */
void hv_netq_destroy(HvNetQueue *q);
/* 0: full or out of memory (dropped, counted); 1: queued; 2: queued into an empty queue, so the consumer needs waking.
   A consumer drains until it finds the queue empty, so a frame behind others needs no wake of its own. */
int hv_netq_push(HvNetQueue *q, const uint8_t *data, uint32_t len);
/* Consumer: how many frames wait; the i-th of them stays put until hv_netq_pop takes it. */
uint32_t hv_netq_waiting(HvNetQueue *q);
static inline const HvNetFrame *hv_netq_at(const HvNetQueue *q, uint32_t i) { return &q->f[(q->head + i) % HV_NETQ_LEN]; }
/* Consumer: the first n frames are done with. */
void hv_netq_pop(HvNetQueue *q, uint32_t n);

#endif
