#include <fcntl.h>
#include <errno.h>
#include "../core/machine.h"
#include "knobs.h"
#include "disk.h"

#include <fcntl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <unistd.h>

#define DISK_IO_CHUNK (128u << 20)
#define DISK_IOV 128 /* buffers a system call takes at a time (a request has at most HV_VIRTQ_MAX_SEGS) */

int hv_disk_open(HvDisk *d, const char *path, uint64_t offset, int readonly) {
    d->wfd = -1;
    d->fd = open(path, readonly ? O_RDONLY : O_RDWR);
    if (d->fd < 0) return -1;
    struct stat st;
    if (fstat(d->fd, &st) != 0 || (uint64_t)st.st_size < offset) {
        close(d->fd);
        d->fd = -1;
        return -1;
    }
    d->offset = offset;
    d->size = (uint64_t)st.st_size - offset;
    d->readonly = readonly;
    d->writes = d->syncs = 0;
    d->flushed = ~0ull; /* the first flush goes to the file system, whatever came before this open */
    /* Holes need the file system's block size (APFS: 4 KB); a file system that cannot punch any falls back to
       writing zeros (hv_disk_zero). */
    struct statfs fs;
    d->hole = 0;
    if (!readonly && fstatfs(d->fd, &fs) == 0 && fs.f_bsize >= 512 && fs.f_bsize <= (1u << 20) && !(fs.f_bsize & (fs.f_bsize - 1)))
        d->hole = (uint32_t)fs.f_bsize;
    /* HV_WRITE_CACHE=0: writes skip the host's cache (F_NOCACHE), so a long run of them cannot pile up
       gigabytes of dirty pages; reads stay cached, and the kernel keeps the two coherent. Off by default:
       on the Mac bench big writes took 2-3x as long that way (2 GB + sync 4-6 s -> 9-17 s) and everyday
       work was no faster. The phone's installer turns it on for the restore, which writes ~15 GB at once. */
    if (!readonly && !hv_knob.write_cache) {
        d->wfd = open(path, O_RDWR);
        if (d->wfd >= 0 && fcntl(d->wfd, F_NOCACHE, 1) == -1) {
            close(d->wfd);
            d->wfd = -1;
        }
    }
    return 0;
}

void hv_disk_close(HvDisk *d) {
    if (d->fd >= 0) close(d->fd);
    if (d->wfd >= 0) close(d->wfd);
    d->fd = d->wfd = -1;
}

/* One request's buffers in as few system calls as there can be: preadv/pwritev, each up to DISK_IO_CHUNK bytes and
   DISK_IOV buffers, going on where a short transfer stopped. */
static int disk_rwv(HvDisk *d, int write, uint64_t off, const struct iovec *iov, int n) {
    uint64_t len = 0;
    for (int i = 0; i < n; i++) len += iov[i].iov_len;
    if ((write && d->readonly) || off > d->size || len > d->size - off) return -1;
    int fd = write && d->wfd >= 0 ? d->wfd : d->fd;
    int i = 0;       /* the first buffer not done yet */
    size_t done = 0; /* bytes of it done */
    for (;;) {
        while (i < n && done == iov[i].iov_len) i++, done = 0;
        if (i == n) break;
        struct iovec batch[DISK_IOV];
        int k = 0;
        size_t total = 0;
        for (int j = i; j < n && k < DISK_IOV && total < DISK_IO_CHUNK; j++) {
            size_t skip = j == i ? done : 0, c = iov[j].iov_len - skip;
            if (c > DISK_IO_CHUNK - total) c = DISK_IO_CHUNK - total;
            if (!c) continue;
            batch[k].iov_base = (uint8_t *)iov[j].iov_base + skip;
            batch[k].iov_len = c;
            k++, total += c;
        }
        ssize_t r = write ? pwritev(fd, batch, k, (off_t)(d->offset + off)) : preadv(fd, batch, k, (off_t)(d->offset + off));
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        off += (uint64_t)r;
        for (size_t left = (size_t)r; left;) {
            size_t rest = iov[i].iov_len - done;
            if (left < rest) done += left, left = 0;
            else left -= rest, i++, done = 0;
        }
    }
    if (write) __atomic_fetch_add(&d->writes, 1, __ATOMIC_RELEASE);
    return 0;
}

int hv_disk_readv(HvDisk *d, uint64_t off, const struct iovec *iov, int n) { return disk_rwv(d, 0, off, iov, n); }
int hv_disk_writev(HvDisk *d, uint64_t off, const struct iovec *iov, int n) { return disk_rwv(d, 1, off, iov, n); }

int hv_disk_read(HvDisk *d, uint64_t off, void *buf, uint64_t len) {
    struct iovec v = {buf, (size_t)len}; /* size_t is 64 bits here */
    return disk_rwv(d, 0, off, &v, 1);
}

int hv_disk_write(HvDisk *d, uint64_t off, const void *buf, uint64_t len) {
    struct iovec v = {(void *)buf, (size_t)len};
    return disk_rwv(d, 1, off, &v, 1);
}

static int write_zeros(HvDisk *d, uint64_t off, uint64_t len) {
    static const uint8_t zeros[64 << 10];
    while (len) {
        uint64_t n = len > sizeof zeros ? sizeof zeros : len;
        if (hv_disk_write(d, off, zeros, n) != 0) return -1;
        off += n;
        len -= n;
    }
    return 0;
}

/* The whole file blocks of the range become holes (fcntl F_PUNCHHOLE: they read as zeros and use no storage, so a
   TRIM gives the image's space back to the device); the partial blocks at its ends are written with zeros. Where the
   file system cannot punch holes, all of it is written. */
int hv_disk_zero(HvDisk *d, uint64_t off, uint64_t len) {
    if (d->readonly || off > d->size || len > d->size - off) return -1;
#ifdef F_PUNCHHOLE
    uint64_t b = __atomic_load_n(&d->hole, __ATOMIC_RELAXED), at = d->offset + off, end = at + len;
    uint64_t first = b ? (at + b - 1) / b * b : 0, last = b ? end / b * b : 0; /* file offsets */
    if (b && first < last) {
        struct fpunchhole ph = {.fp_flags = 0, .reserved = 0, .fp_offset = (off_t)first, .fp_length = (off_t)(last - first)};
        if (fcntl(d->fd, F_PUNCHHOLE, &ph) == 0) {
            __atomic_fetch_add(&d->writes, 1, __ATOMIC_RELEASE);
            __atomic_fetch_add(&d->punched, last - first, __ATOMIC_RELAXED);
            return write_zeros(d, off, first - at) || write_zeros(d, last - d->offset, end - last) ? -1 : 0;
        }
        /* Not here (another file system): zeros from now on. */
        __atomic_store_n(&d->hole, 0, __ATOMIC_RELAXED);
    }
#endif
    return write_zeros(d, off, len);
}

/* HV_FLUSH: 0 fsync; 1 nothing here, what was written is safe in the host's cache as long as the
   host runs; 2 fcntl(F_BARRIERFSYNC). A flush with no write completed since the last one that went through has
   nothing to make safe, and returns at once (APFS and sqlite flush often, after a write or not). */
int hv_disk_flush(HvDisk *d) {
    if (d->readonly) return 0;
    uint64_t writes = __atomic_load_n(&d->writes, __ATOMIC_ACQUIRE);
    if (writes == __atomic_load_n(&d->flushed, __ATOMIC_RELAXED)) return 0;
    int r;
    switch (hv_knob.flush) {
    case 1: return 0;
    case 2: r = fcntl(d->fd, F_BARRIERFSYNC) == -1 ? -1 : 0; break;
    default: r = fsync(d->fd); break;
    }
    if (r == 0) {
        __atomic_store_n(&d->flushed, writes, __ATOMIC_RELAXED);
        __atomic_fetch_add(&d->syncs, 1, __ATOMIC_RELAXED);
    }
    return r;
}
