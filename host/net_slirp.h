#ifndef SOLSTICEVM_NET_SLIRP_H
#define SOLSTICEVM_NET_SLIRP_H

#include "machine.h"
#include "virtio_net.h"

/* Before hv_net_attach: the Unix socket behind the guest's 10.0.2.4:80 (share.c). */
void hv_net_set_share_socket(const char *path);
/* User-mode NAT for the guest's virtio-net (see net_slirp.c). Returns 0 on success. */
int hv_net_attach(HvMachine *m, HvVirtioNet *n);
/* CPUs must be stopped. Joins the network worker before its machine is freed. */
void hv_net_detach(void);
/* CPU thread, from the board's tick: hand frames for the guest to the device. */
void hv_net_poll(void);
/* The stats printer: frames each way over the last `seconds`, drops and how full the queues got. */
void hv_net_stats(double seconds);

extern uint64_t hv_net_tx_frames, hv_net_rx_frames;

#endif
