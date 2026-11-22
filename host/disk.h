#ifndef HENGEVM_DISK_H
#define HENGEVM_DISK_H

#include <stdint.h>
#include <sys/uio.h>

/* A raw disk image file, optionally starting `offset` bytes in (QEMU's vmapple
   notes say the first 16 KB of auxiliary.bin is metadata the guest never sees). */
typedef struct HvDisk {
    int fd;
    int wfd;         /* writes, past the host's cache (F_NOCACHE); -1: through fd */
    uint64_t offset;
    uint64_t size;   /* bytes visible to the guest */
    int readonly;
    uint32_t hole;   /* the file system's block: aligned runs of these become holes when zeroed; 0: zeros written */
    uint64_t writes; /* writes completed (atomic), and how many a flush had made safe: a flush with none since is free */
    uint64_t flushed;
    uint64_t syncs;  /* flushes that went to the file system (tests, stats) */
} HvDisk;

int hv_disk_open(HvDisk *d, const char *path, uint64_t offset, int readonly);
void hv_disk_close(HvDisk *d);
/* Return 0, or -1 on an I/O error or an access past the end. */
int hv_disk_read(HvDisk *d, uint64_t off, void *buf, uint64_t len);
int hv_disk_write(HvDisk *d, uint64_t off, const void *buf, uint64_t len);
/* The same with the buffers of one request: one system call for all of them (up to 128 MB at a time). */
int hv_disk_readv(HvDisk *d, uint64_t off, const struct iovec *iov, int n);
int hv_disk_writev(HvDisk *d, uint64_t off, const struct iovec *iov, int n);
/* Make a range read back as zeros (a discard or write-zeroes request): the whole blocks in it become holes, so the
   image gives the storage back. */
int hv_disk_zero(HvDisk *d, uint64_t off, uint64_t len);
int hv_disk_flush(HvDisk *d);

#endif
