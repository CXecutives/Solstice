#include "net_queue.h"

#include <stdlib.h>
#include <string.h>

void hv_netq_init(HvNetQueue *q) {
    pthread_mutex_init(&q->mu, NULL);
    q->head = q->tail = 0;
    q->nfree = HV_NETQ_SLAB;
    for (uint32_t i = 0; i < HV_NETQ_SLAB; i++) q->free[i] = (uint16_t)(HV_NETQ_SLAB - 1 - i);
    q->dropped = 0;
    q->peak = 0;
}

static void release(HvNetQueue *q, HvNetFrame *f) {
    if (f->slab >= 0) q->free[q->nfree++] = (uint16_t)f->slab;
    else free(f->data);
    f->data = NULL;
}

void hv_netq_destroy(HvNetQueue *q) {
    pthread_mutex_lock(&q->mu);
    while (q->head != q->tail) release(q, &q->f[q->head++ % HV_NETQ_LEN]);
    pthread_mutex_unlock(&q->mu);
    pthread_mutex_destroy(&q->mu);
}

int hv_netq_push(HvNetQueue *q, const uint8_t *data, uint32_t len) {
    pthread_mutex_lock(&q->mu);
    uint32_t n = q->tail - q->head;
    int ok = n < HV_NETQ_LEN ? (n == 0 ? 2 : 1) : 0;
    if (ok) {
        HvNetFrame *f = &q->f[q->tail % HV_NETQ_LEN];
        if (len <= HV_NETQ_BUF && q->nfree) {
            f->slab = q->free[--q->nfree];
            f->data = q->slab[f->slab];
        } else {
            f->slab = -1;
            f->data = malloc(len ? len : 1);
            if (!f->data) ok = 0;
        }
        if (ok) {
            memcpy(f->data, data, len);
            f->len = len;
            q->tail++;
            if (n + 1 > __atomic_load_n(&q->peak, __ATOMIC_RELAXED)) __atomic_store_n(&q->peak, n + 1, __ATOMIC_RELAXED);
        }
    }
    if (!ok) __atomic_store_n(&q->dropped, q->dropped + 1, __ATOMIC_RELAXED);
    pthread_mutex_unlock(&q->mu);
    return ok;
}

uint32_t hv_netq_waiting(HvNetQueue *q) {
    pthread_mutex_lock(&q->mu);
    uint32_t n = q->tail - q->head;
    pthread_mutex_unlock(&q->mu);
    return n;
}

void hv_netq_pop(HvNetQueue *q, uint32_t n) {
    if (!n) return;
    pthread_mutex_lock(&q->mu);
    for (uint32_t i = 0; i < n && q->head != q->tail; i++) release(q, &q->f[q->head++ % HV_NETQ_LEN]);
    pthread_mutex_unlock(&q->mu);
}
