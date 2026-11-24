#ifndef SOLSTICEVM_VIRTIO_NET_H
#define SOLSTICEVM_VIRTIO_NET_H

#include "virtio.h"

/* virtio-net with one queue pair. The host side of the network is a pair of
   hooks: `transmit` gets every frame the guest sends, and frames for the guest
   go in through hv_virtio_net_receive. No backend is attached yet. */
typedef struct HvVirtioNet {
    HvVirtio vio;
    void (*transmit)(void *opaque, const uint8_t *frame, uint32_t len);
    /* The guest posted receive buffers: frames waiting for them can go in now (device lock held). */
    void (*rx_ready)(void *opaque);
    void *opaque;
    uint64_t tx_frames, rx_frames, rx_dropped;
    int rx_pending, features_logged;
} HvVirtioNet;

HvVirtioNet *hv_virtio_net_create(HvMachine *m, HvPcie *bus, const uint8_t mac[6]);
/* Returns 0 if the guest had no receive buffer posted (the caller keeps the frame for later). The guest's interrupt
   for a batch of them comes with hv_virtio_net_rx_done. */
int hv_virtio_net_receive(HvVirtioNet *n, const uint8_t *frame, uint32_t len);
void hv_virtio_net_rx_done(HvVirtioNet *n);
/* A transmitted frame whose checksum the guest left to the host (NEEDS_CSUM): the sum from `start` into start + off. */
void hv_virtio_net_finish_csum(uint8_t *frame, uint32_t len, uint32_t start, uint32_t off);
void hv_virtio_net_set_link(HvVirtioNet *n, int up);

#endif
