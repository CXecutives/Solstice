#include "virtio_net.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define F_CSUM (1ull << 0)       /* the driver may leave a frame's checksum for us (NEEDS_CSUM) */
#define F_GUEST_CSUM (1ull << 1) /* we may mark a frame's checksum as checked (DATA_VALID) */
#define F_MAC (1ull << 5)
#define F_STATUS (1ull << 16)
#define RXQ 0
#define TXQ 1
#define HDR_LEN 12 /* virtio_net_hdr with num_buffers (VERSION_1) */
#define HDR_F_NEEDS_CSUM 1
#define HDR_F_DATA_VALID 2
#define MAX_FRAME 65550

/* The Internet checksum (RFC 1071) of the frame from `start` on, into the 16 bits at start + off. The driver put the
   pseudo-header's sum there already, as the spec has it. */
void hv_virtio_net_finish_csum(uint8_t *frame, uint32_t len, uint32_t start, uint32_t off) {
    if (start > len || off + 2 > len - start) return;
    uint64_t sum = 0;
    uint32_t i = start;
    for (; i + 1 < len; i += 2) sum += (uint32_t)frame[i] << 8 | frame[i + 1];
    if (i < len) sum += (uint32_t)frame[i] << 8;
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    uint16_t c = (uint16_t)~sum;
    frame[start + off] = (uint8_t)(c >> 8);
    frame[start + off + 1] = (uint8_t)c;
}

static void log_features(HvVirtioNet *n) {
    if (n->features_logged || !(n->vio.status & 4)) return;
    n->features_logged = 1;
    uint64_t f = n->vio.driver_features;
    fprintf(stderr, "virtio-net: driver features %#llx (checksums: tx %s, rx %s)\n", (unsigned long long)f,
            f & F_CSUM ? "left to the host" : "by the guest", f & F_GUEST_CSUM ? "trusted" : "checked by the guest");
}

static void notify(HvVirtio *v, int q) {
    HvVirtioNet *n = v->dev;
    log_features(n);
    if (q == RXQ) { /* new receive buffers: frames that waited for them go in now, not at the next poll */
        if (n->rx_ready) n->rx_ready(n->opaque);
        return;
    }
    if (q != TXQ) return;
    static HvVirtqElem e;
    static uint8_t buf[HDR_LEN + MAX_FRAME];
    int any = 0;
    while (hv_virtq_pop(v, q, &e) > 0) {
        uint32_t got = hv_virtq_read(v, &e, 0, buf, sizeof buf);
        if (got >= HDR_LEN) {
            uint8_t *frame = buf + HDR_LEN;
            uint32_t len = got - HDR_LEN;
            if ((buf[0] & HDR_F_NEEDS_CSUM) && (v->driver_features & F_CSUM)) {
                uint16_t start, off;
                memcpy(&start, buf + 6, 2);
                memcpy(&off, buf + 8, 2);
                hv_virtio_net_finish_csum(frame, len, start, off);
            }
            if (n->transmit) n->transmit(n->opaque, frame, len);
            n->tx_frames++;
        }
        hv_virtq_push(v, q, &e, 0);
        any = 1;
    }
    if (any) hv_virtio_interrupt(v);
}

int hv_virtio_net_receive(HvVirtioNet *n, const uint8_t *frame, uint32_t len) {
    HvVirtio *v = &n->vio;
    static HvVirtqElem e;
    if (!(v->status & 4) || !v->q[RXQ].enabled || hv_virtq_pop(v, RXQ, &e) <= 0) return 0;
    n->rx_pending = 1;
    if (hv_virtq_writable(&e) < HDR_LEN + len) { /* too small for it: drop the frame, return the buffer */
        hv_virtq_push(v, RXQ, &e, 0);
        n->rx_dropped++;
        return 1;
    }
    uint8_t hdr[HDR_LEN] = {0};
    /* libslirp's frames carry correct checksums: a driver that may trust them need not check them again. */
    if (v->driver_features & F_GUEST_CSUM) hdr[0] = HDR_F_DATA_VALID;
    hdr[10] = 1; /* num_buffers */
    hv_virtq_write(v, &e, 0, hdr, HDR_LEN);
    hv_virtq_write(v, &e, HDR_LEN, frame, len);
    hv_virtq_push(v, RXQ, &e, HDR_LEN + len);
    n->rx_frames++;
    return 1;
}

void hv_virtio_net_rx_done(HvVirtioNet *n) {
    if (!n || !n->rx_pending) return;
    n->rx_pending = 0;
    hv_virtio_interrupt(&n->vio);
}

HvVirtioNet *hv_virtio_net_create(HvMachine *m, HvPcie *bus, const uint8_t mac[6]) {
    HvVirtioNet *n = calloc(1, sizeof *n);
    HvVirtio *v = &n->vio;
    hv_virtio_init(v, m, 1, 0x020000, 2, F_CSUM | F_GUEST_CSUM | F_MAC | F_STATUS);
    v->dev = n;
    v->notify = notify;
    memcpy(v->config, mac, 6);
    uint16_t status = 1, pairs = 1; /* link up */
    memcpy(v->config + 6, &status, 2);
    memcpy(v->config + 8, &pairs, 2);
    v->config_len = 12;
    hv_pcie_attach(bus, &v->pci);
    return n;
}

/* The cable out (up = 0) or back in: the guest is told its configuration changed. Device lock held. */
void hv_virtio_net_set_link(HvVirtioNet *n, int up) {
    if (!n) return;
    uint16_t status = up ? 1 : 0;
    memcpy(n->vio.config + 6, &status, 2);
    hv_virtio_config_changed(&n->vio);
}
