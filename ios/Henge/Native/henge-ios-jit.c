/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Henge -- iOS dual-mapped JIT memory for QEMU's TCG.  See henge-ios-jit.h.
 *
 * Derived from AetherPS4-iOS's src/core/ios/ios_jit_allocator.cpp
 * (shadPS4 Emulator Project, GPL-2.0-or-later), ported C++ -> C.
 */

#include "henge-ios-jit.h"
#include "jit_region.h"

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && TARGET_OS_IPHONE

#include <errno.h>
#include <mach/mach.h>
#include <mach/vm_map.h>        /* vm_remap/vm_protect: mach_vm.h is absent from the iOS SDK */
#include <os/log.h>
#include <os/proc.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <mach/task.h>
#include <mach/task_info.h>
#include <libkern/OSCacheControl.h>
#include <sys/ucontext.h>   /* not <ucontext.h>: that one #errors without _XOPEN_SOURCE */
#include <unistd.h>
#include <fcntl.h>

/*
 * Provide pipe2 for iOS systems where libc does not export it.
 */
__attribute__((visibility("default")))
int pipe2(int fds[2], int flags)
{
    if (!fds) {
        errno = EFAULT;
        return -1;
    }
    if (pipe(fds) < 0) {
        return -1;
    }
    if (flags & O_CLOEXEC) {
        if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 ||
            fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0) {
            int err = errno;
            close(fds[0]);
            close(fds[1]);
            errno = err;
            return -1;
        }
    }
    if (flags & O_NONBLOCK) {
        int f0 = fcntl(fds[0], F_GETFL);
        int f1 = fcntl(fds[1], F_GETFL);
        if (f0 < 0 || f1 < 0 ||
            fcntl(fds[0], F_SETFL, f0 | O_NONBLOCK) < 0 ||
            fcntl(fds[1], F_SETFL, f1 | O_NONBLOCK) < 0) {
            int err = errno;
            close(fds[0]);
            close(fds[1]);
            errno = err;
            return -1;
        }
    }
    return 0;
}

/* Maximum verbosity by default: this path is nearly impossible to debug after the
 * fact on device, and every line here is printed at most a handful of times per
 * session. Goes to os_log (visible in Console.app) and stderr both. */
static double henge_now_ms(void)
{
    static double base = 0;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    double t = tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
    if (base == 0) { base = t; }
    return t - base;
}

#define HENGE_LOG(fmt, ...)                                                     \
    do {                                                                       \
        os_log(OS_LOG_DEFAULT, "[solstice-jit] " fmt, ##__VA_ARGS__);              \
        fprintf(stderr, "[%9.2fms][solstice-jit] " fmt "\n",                       \
                henge_now_ms(), ##__VA_ARGS__);                                 \
        fflush(stderr);                                                        \
    } while (0)

/* ------------------------------------------------------------------ symbols */
/*
 * The trap sequences live in henge-brk.S, compiled straight into this binary.
 * Henge deliberately does NOT link or dlopen Stossy11's BreakpointJIT.framework:
 * it has no stated license, and any embedded framework carrying entitlements is
 * rejected by AMFI at launch on sideloaded builds. See henge-brk.S for the
 * verification that our encoding matches theirs exactly.
 */
extern void    *henge_brk_get_jit_mapping(void *addr, size_t len);
extern void     henge_brk_jit_detach(void);
extern uint64_t henge_brk_probe(void);

/*
 * StikDebug answers brk #0x69 by writing a constant into x0. Two encodings are
 * seen in the wild:
 *
 *   0xE0000069  -- the value as written in the script
 *   0x690000E0  -- that value byte-reversed, which is what universal.js actually
 *                  produces: it sends the gdb-remote packet `P0=E0000069`, but P
 *                  takes the register in TARGET byte order, and ARM64 is little
 *                  endian. It also supplies only 4 bytes for an 8-byte register,
 *                  so the upper half keeps whatever poison was there (0xcccccccc
 *                  observed on iPhone18,1 / iOS 27).
 *
 * Matching on an exact value is therefore the wrong test. What actually
 * distinguishes "serviced" from "not serviced" is far simpler: when StikDebug is
 * absent, our own SIGTRAP handler steps over the brk and sets x0 to exactly 0.
 * So any non-zero answer means something serviced the trap.
 */
#define HENGE_PROBE_MAGIC    0xE0000069ull
#define HENGE_PROBE_MAGIC_LE 0x690000E0ull

static atomic_bool           g_jit_available;
static atomic_uint_least64_t g_alloc_counter;

/* ------------------------------------------------------- unserviced-trap guard */
/*
 * Set for exactly the duration of the BreakGetJITMapping call. If StikDebug is
 * not there to service the brk, the trap is a real SIGTRAP that would otherwise
 * kill the process outright -- there is no "call returned an error" to recover
 * from. The handler below turns that into a NULL return, which the allocation
 * path already handles.
 */
static _Thread_local bool g_expecting_jit_trap;

static struct sigaction g_prev_sigtrap;
static struct sigaction g_prev_sigbus;

static void henge_trap_handler(int sig, siginfo_t *info, void *ctx)
{
    (void)info;
    if (g_expecting_jit_trap && ctx != NULL) {
        ucontext_t *uc = (ucontext_t *)ctx;
        /* Step over the brk and report failure in x0, exactly as the
         * StikDebug-serviced path would have written a result there. */
        uc->uc_mcontext->__ss.__pc += 4;
        uc->uc_mcontext->__ss.__x[0] = 0;
        return;
    }

    /* Not ours: restore and re-raise so a genuine breakpoint or bus error is
     * not silently swallowed. */
    struct sigaction *prev = (sig == SIGTRAP) ? &g_prev_sigtrap : &g_prev_sigbus;
    sigaction(sig, prev, NULL);
    raise(sig);
}

void henge_ios_jit_install_trap_handler(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK; /* a CPU thread's SP may hold a guest address */
    sa.sa_sigaction = henge_trap_handler;
    sigemptyset(&sa.sa_mask);

    if (sigaction(SIGTRAP, &sa, &g_prev_sigtrap) != 0) {
        HENGE_LOG("sigaction(SIGTRAP) failed: %s", strerror(errno));
    }
    if (sigaction(SIGBUS, &sa, &g_prev_sigbus) != 0) {
        HENGE_LOG("sigaction(SIGBUS) failed: %s", strerror(errno));
    }
    HENGE_LOG("trap guard installed (SIGTRAP, SIGBUS)");
}

/* ---------------------------------------------------------------- footprint */
/*
 * phys_footprint is the figure jetsam judges us on, so it is the one worth
 * logging around every large allocation. An iOS app with the
 * increased-memory-limit entitlement still dies silently when this crosses the
 * device's cap, and a silent kill with no crash log is otherwise very hard to
 * tell apart from any other sudden death.
 */
void henge_ios_jit_log_footprint(const char *tag)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count)
        != KERN_SUCCESS) {
        HENGE_LOG("footprint[%s]: task_info failed", tag ? tag : "");
        return;
    }
    /*
     * os_proc_available_memory() is the number that actually matters: how much
     * more this process may allocate before jetsam kills it. phys_footprint alone
     * says how much we have used but not how close to the edge that is, and the
     * limit varies by device and by whether the increased-memory-limit entitlement
     * is honoured. A jetsam kill is a SIGKILL -- no handler runs and the log simply
     * stops -- so the only way to see it coming is to watch this fall.
     */
    size_t avail = os_proc_available_memory();

    HENGE_LOG("footprint[%s]: phys=%.1f MiB  resident=%.1f MiB  "
             "available-before-jetsam=%.1f MiB",
             tag ? tag : "",
             info.phys_footprint / (1024.0 * 1024.0),
             info.resident_size  / (1024.0 * 1024.0),
             avail / (1024.0 * 1024.0));
    /* What the footprint is made of, and what is resident beside it: internal is Henge's own memory (the code
       cache, the translator's tables), compressed what iOS has squeezed of it, external the file-backed pages (a
       Mac's RAM file: outside the footprint, but real memory all the same, which is what an 8 GB device runs out
       of), graphics the GPU's (the Mac's surfaces and textures). */
    if (count >= TASK_VM_INFO_COUNT)
        HENGE_LOG("footprint[%s]: internal=%.0f compressed=%.0f external(file-backed)=%.0f graphics=%.0f peak=%.0f MiB",
                 tag ? tag : "", info.internal / (1024.0 * 1024.0), info.compressed / (1024.0 * 1024.0),
                 info.external / (1024.0 * 1024.0), info.ledger_tag_graphics_footprint / (1024.0 * 1024.0),
                 info.ledger_phys_footprint_peak / (1024.0 * 1024.0));
}

size_t henge_ios_available_memory(void)
{
    return os_proc_available_memory();
}

/* ---------------------------------------------------------------- self-test */
/*
 * The decisive check. StikDebug can hand back an address, and vm_remap can
 * succeed, while the pages were never actually prepared -- `_M,rx` allocating
 * without prepare_memory_region walking each page looks identical from here.
 * In that case nothing goes wrong until TCG branches into generated code, and
 * the app dies somewhere deep in the emulator with no useful context.
 *
 * So: write a two-instruction function through the RW alias, then CALL it
 * through the RX alias. If JIT works at all, this returns 42.
 */
static bool henge_jit_selftest(const HengeDualMapping *m)
{
    /* movz w0, #42  ;  ret */
    static const uint32_t kCode[2] = { 0x52800540u, 0xD65F03C0u };

    if (m->rw_addr == NULL || m->rx_addr == NULL) {
        return false;
    }

    HENGE_LOG("selftest: writing %zu bytes through RW alias %p", sizeof(kCode),
             (void *)m->rw_addr);
    memcpy(m->rw_addr, kCode, sizeof(kCode));

    /* Flush the write through to the RX view before executing it. */
    sys_icache_invalidate(m->rx_addr, sizeof(kCode));
    HENGE_LOG("selftest: icache invalidated on RX alias %p", (void *)m->rx_addr);

    /* Read back through RX to confirm the two aliases really share pages. */
    uint32_t readback[2];
    memcpy(readback, m->rx_addr, sizeof(readback));
    if (readback[0] != kCode[0] || readback[1] != kCode[1]) {
        HENGE_LOG("selftest: FAIL -- RX alias does not reflect RW writes "
                 "(read 0x%08x 0x%08x, expected 0x%08x 0x%08x). The two mappings "
                 "are not backed by the same pages.",
                 readback[0], readback[1], kCode[0], kCode[1]);
        return false;
    }
    HENGE_LOG("selftest: RX alias reflects RW writes (0x%08x 0x%08x) -- aliasing OK",
             readback[0], readback[1]);

    HENGE_LOG("selftest: CALLING generated code at %p ...", (void *)m->rx_addr);
    int (*fn)(void) = (int (*)(void))(void *)m->rx_addr;
    int result = fn();

    if (result != 42) {
        HENGE_LOG("selftest: FAIL -- generated code ran but returned %d, expected 42",
                 result);
        return false;
    }
    HENGE_LOG("selftest: PASS -- executed generated code from the RX alias, got 42. "
             "JIT is genuinely live.");
    return true;
}

/* ------------------------------------------------------------- allocation */

/*
 * Henge: take the JIT region early, before anything slow happens.
 *
 * StikDebug does not stay attached indefinitely. A first run downloads about
 * 1.1 GB of guest image before QEMU starts, and by the time qemu_init() reached
 * alloc_code_gen_buffer the debugger had let go:
 *
 *   StikDebug is NOT servicing traps -- probe returned 0
 *   could not obtain 268435456 bytes of JIT memory
 *
 * Nothing can recover from that in-process: without a debugger there is no way
 * to get executable memory, and asking again later is exactly what does not
 * work. So the region is claimed at app launch, while the attachment is fresh,
 * and held until QEMU asks for it.
 */
/* Where the JIT region can work. iOS gives an app with extended-virtual-addressing room
   above 0x7000000000, but generated code placed there never runs (the self-test's call
   hangs), while below it the room is what is left between the app, its heap and its
   thread stacks in the 0x100000000-0x180000000 window, which varies from launch to launch
   and is often split into pieces under the 1 GB region. So the app's own image holds the
   room: a zero-fill block in __DATA, mapped with the executable before anything else can
   land in between, which costs nothing until it is touched. It is handed back just before
   the debugger allocates, and the debugger's first-fit allocation takes the hole. */
#define HENGE_JIT_LOW_LIMIT 0x7000000000ull
#define HENGE_JIT_HOLD_BYTES ((size_t)3 << 29) /* the largest JITBootstrap.jitBytes (1.5 GB); a 1 GB region takes part of the hole */
__attribute__((used, aligned(16384))) static uint8_t g_jit_reserve[HENGE_JIT_HOLD_BYTES + (16u << 10)];
static bool g_jit_reserve_released;

/* Give the reserved block back for the debugger's allocation, if it is the size asked for. */
static void henge_ios_jit_release_low_hold(size_t bytes)
{
    if (g_jit_reserve_released || bytes > HENGE_JIT_HOLD_BYTES) return;
    vm_address_t start = ((vm_address_t)g_jit_reserve + 16383) & ~(vm_address_t)16383;
    kern_return_t kr = vm_deallocate(mach_task_self(), start, HENGE_JIT_HOLD_BYTES);
    HENGE_LOG("released the reserved block at %#lx for the JIT region: %s", (unsigned long)start, mach_error_string(kr));
    g_jit_reserve_released = true;
}

/* The address space, for working out where a JIT region can go: every mapping, and the gaps of 256 MiB or more. */
static void henge_ios_jit_log_map(const char *tag)
{
    mach_vm_address_t addr = 0, prev_end = 0x100000000ull;
    for (int i = 0; i < 4096; i++) {
        vm_size_t size = 0;
        vm_address_t a = (vm_address_t)addr;
        natural_t depth = 0;
        struct vm_region_submap_info_64 info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &a, &size, &depth, (vm_region_recurse_info_t)&info, &count) != KERN_SUCCESS) break;
        if (a > prev_end && a - prev_end >= (256ull << 20))
            HENGE_LOG("map[%s]: gap %#llx-%#llx (%llu MiB)", tag, (unsigned long long)prev_end, (unsigned long long)a,
                      (unsigned long long)((a - prev_end) >> 20));
        if (size >= (256ull << 20))
            HENGE_LOG("map[%s]: big %#llx-%#llx prot %d/%d tag %u", tag, (unsigned long long)a, (unsigned long long)(a + size),
                      info.protection, info.max_protection, info.user_tag);
        if (a + size > prev_end) prev_end = a + size;
        addr = a + size;
    }
    HENGE_LOG("map[%s]: highest mapped end %#llx", tag, (unsigned long long)prev_end);
}

static HengeDualMapping henge_ios_jit_allocate_real(size_t bytes);

static HengeDualMapping henge_prewarmed;
static bool henge_prewarm_done;
static bool g_no_debugger;

/* One size for hv_jit_claim_halving: the region into ctx. */
static int henge_ios_jit_claim(size_t bytes, void *ctx)
{
    HengeDualMapping *out = ctx;
    *out = henge_ios_jit_allocate_real(bytes);
    return out->rw_addr ? 1 : g_no_debugger ? -1 : 0;
}

HENGE_EXPORT bool henge_ios_jit_prewarm(size_t bytes, size_t min_bytes)
{
    if (henge_prewarm_done) {
        return henge_prewarmed.rw_addr != NULL;
    }
    henge_prewarm_done = true;
    /* A smaller region when the one asked for cannot be had (no hole that large under 0x7000000000, say): the cache
       empties more often, where without one the Mac does not start. Everything after reads the size obtained
       (henge_ios_jit_get_mapping, henge_ios_jit_region_bytes). */
    size_t got = hv_jit_claim_halving(bytes, min_bytes, henge_ios_jit_claim, &henge_prewarmed);
    fprintf(stderr, "[solstice-jit] prewarm %s: %zu bytes (asked for %zu)\n", got ? "OK" : "FAILED", got, bytes);
    return got != 0;
}

HENGE_EXPORT size_t henge_ios_jit_region_bytes(void)
{
    return henge_prewarmed.rw_addr ? henge_prewarmed.size : 0;
}

/* The held region, for the machine (henge-vm.c). */
HENGE_EXPORT HengeDualMapping *henge_ios_jit_get_mapping(void)
{
    return henge_prewarmed.rw_addr ? &henge_prewarmed : NULL;
}

static HengeDualMapping henge_ios_jit_allocate_real(size_t bytes)
{
    HengeDualMapping region = { NULL, NULL, 0 };
    uint64_t n = atomic_fetch_add(&g_alloc_counter, 1) + 1;

    /* Cheap attach probe: brk #0x69 is answered with a constant when StikDebug
     * is live, and swallowed by our trap handler as 0 when it is not. Doing this
     * first turns "no debugger" into a clean diagnostic instead of three slow
     * retries of the real request. */
    g_expecting_jit_trap = true;
    uint64_t probe = henge_brk_probe();
    g_expecting_jit_trap = false;
    if (probe == 0) {
        g_no_debugger = true; /* no size can be had: no smaller one is asked for */
        HENGE_LOG("#%llu: StikDebug is NOT servicing traps -- probe returned 0, which "
                 "is our own SIGTRAP handler stepping over an unanswered brk.",
                 (unsigned long long)n);
        return region;
    }

    uint32_t probe_lo = (uint32_t)probe;
    if (probe_lo == (uint32_t)HENGE_PROBE_MAGIC ||
        probe_lo == (uint32_t)HENGE_PROBE_MAGIC_LE) {
        HENGE_LOG("#%llu: StikDebug attach probe OK (0x%llx)",
                 (unsigned long long)n, (unsigned long long)probe);
    } else {
        /* Serviced, but by something that answers differently. Proceed -- the
         * allocation itself is the real test -- and record the value so an
         * unfamiliar StikDebug build is identifiable from the log alone. */
        HENGE_LOG("#%llu: trap was serviced but the answer is unrecognised (0x%llx). "
                 "Continuing anyway; the allocation below is the real test.",
                 (unsigned long long)n, (unsigned long long)probe);
    }

    /*
     * Ask for a FRESH region (x0 == 0) so StikDebug allocates it with
     * debugserver `_M<size>,rx` and then walks every 16 KiB page with
     * `M<addr>,1:69`. Requesting a fresh region is the only branch that gets
     * those pages prepared; handing in an address we allocated ourselves does not.
     *
     * StikDebug can be momentarily unresponsive (busy, or briefly suspended by
     * iOS) rather than permanently gone, and the two are indistinguishable from
     * here, so retry a few times before giving up.
     */
    henge_ios_jit_log_map("before");
    henge_ios_jit_release_low_hold(bytes);
    enum { kMaxAttempts = 3 };
    void *rx = NULL;
    for (int attempt = 1; attempt <= kMaxAttempts; attempt++) {
        HENGE_LOG("#%llu: requesting execute-capable region, size=%zu (%.1f MiB), "
                 "attempt %d/%d",
                 (unsigned long long)n, bytes, (double)bytes / (1024.0 * 1024.0),
                 attempt, kMaxAttempts);

        g_expecting_jit_trap = true;
        rx = henge_brk_get_jit_mapping(NULL, bytes);
        g_expecting_jit_trap = false;

        HENGE_LOG("#%llu: BreakGetJITMapping returned %p", (unsigned long long)n, rx);
        if (rx != NULL) {
            break;
        }
        if (attempt < kMaxAttempts) {
            usleep(50 * 1000);
        }
    }

    henge_ios_jit_log_map("after");
    if (rx != NULL && (uint64_t)(uintptr_t)rx + bytes > HENGE_JIT_LOW_LIMIT) {
        /* Calling into it would hang the app with the debugger still attached. */
        HENGE_LOG("#%llu: the JIT region came back at %p, above %#llx where generated code does not run; "
                  "giving it back. Quit Solstice and open it again.", (unsigned long long)n, rx, HENGE_JIT_LOW_LIMIT);
        vm_deallocate(mach_task_self(), (vm_address_t)rx, bytes);
        return region;
    }
    if (rx == NULL) {
        HENGE_LOG("#%llu: FAILED after %d attempts. StikDebug must be attached with "
                 "the Universal JIT script BEFORE the guest is started.",
                 (unsigned long long)n, kMaxAttempts);
        return region;
    }

    /* Writable alias of the same physical pages. Purely local -- no debugger
     * involvement, and therefore still available after detach. */
    /* Near the executable view: a kernel left to choose (VM_FLAGS_ANYWHERE) can put it hundreds of GiB away (seen on iOS 27).
     * Free addresses after the region, then before it, in 16 MiB steps out to 2 GiB; anywhere only if none is free. */
    vm_address_t rw = 0;
    vm_prot_t cur_prot = VM_PROT_NONE, max_prot = VM_PROT_NONE;
    kern_return_t kr = KERN_NO_SPACE;
    const uintptr_t step = 16u << 20, reach = (uintptr_t)2 << 30;
    for (uintptr_t off = 0; off <= reach && kr != KERN_SUCCESS; off += step) {
        for (int side = 0; side < 2 && kr != KERN_SUCCESS; side++) {
            uintptr_t want = side == 0 ? (uintptr_t)rx + bytes + off : (uintptr_t)rx - bytes - off;
            if (side == 1 && (uintptr_t)rx < bytes + off + step) continue;
            rw = (vm_address_t)want;
            kr = vm_remap(mach_task_self(), &rw, (vm_size_t)bytes, /*mask=*/0, VM_FLAGS_FIXED,
                          mach_task_self(), (vm_address_t)rx, /*copy=*/FALSE, &cur_prot, &max_prot, VM_INHERIT_NONE);
        }
    }
    if (kr != KERN_SUCCESS) {
        HENGE_LOG("#%llu: no free space within 2 GiB of rx=%p for the writable view: placing it anywhere", (unsigned long long)n, rx);
        rw = 0;
        kr = vm_remap(mach_task_self(), &rw, (vm_size_t)bytes,
                      /*mask=*/0, VM_FLAGS_ANYWHERE,
                      mach_task_self(), (vm_address_t)rx,
                      /*copy=*/FALSE, &cur_prot, &max_prot,
                      VM_INHERIT_NONE);
    }
    if (kr != KERN_SUCCESS) {
        HENGE_LOG("#%llu: vm_remap failed for rx=%p size=%zu: %d (%s)",
                 (unsigned long long)n, rx, bytes, (int)kr, mach_error_string(kr));
        return region;
    }

    kr = vm_protect(mach_task_self(), rw, (vm_size_t)bytes, /*set_maximum=*/FALSE,
                    VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        HENGE_LOG("#%llu: vm_protect(RW) failed for rw=%p size=%zu: %d (%s)",
                 (unsigned long long)n, (void *)rw, bytes, (int)kr,
                 mach_error_string(kr));
        vm_deallocate(mach_task_self(), rw, (vm_size_t)bytes);
        return region;
    }

    region.rw_addr = (uint8_t *)rw;
    region.rx_addr = (uint8_t *)rx;
    region.size    = bytes;
    atomic_store(&g_jit_available, true);

    HENGE_LOG("#%llu: dual mapping established: rw=%p rx=%p size=%zu diff=%+lld",
             (unsigned long long)n, (void *)region.rw_addr, (void *)region.rx_addr,
             region.size, (long long)(region.rx_addr - region.rw_addr));
    henge_ios_jit_log_footprint("after-jit-alloc");

    if (!henge_jit_selftest(&region)) {
        HENGE_LOG("#%llu: SELFTEST FAILED -- the region is not usable as JIT memory. "
                 "Refusing to hand it to TCG; QEMU would crash on its first "
                 "generated block instead of failing here.",
                 (unsigned long long)n);
        henge_ios_jit_release(&region);
        return region;
    }

    return region;
}

void henge_ios_jit_release(HengeDualMapping *m)
{
    if (m == NULL) {
        return;
    }
    if (m->rw_addr != NULL) {
        vm_deallocate(mach_task_self(), (vm_address_t)m->rw_addr, (vm_size_t)m->size);
        m->rw_addr = NULL;
    }
    if (m->rx_addr != NULL) {
        vm_deallocate(mach_task_self(), (vm_address_t)m->rx_addr, (vm_size_t)m->size);
        m->rx_addr = NULL;
    }
    m->size = 0;
}

void henge_ios_jit_detach(void)
{
    HENGE_LOG("detaching debugger; RX mappings persist after this");
    g_expecting_jit_trap = true;
    henge_brk_jit_detach();
    g_expecting_jit_trap = false;
    HENGE_LOG("debugger detached");
}

bool henge_ios_jit_is_available(void)
{
    return atomic_load(&g_jit_available);
}

#else /* !iOS: keep the symbols so host builds and tests link */

void henge_ios_jit_install_trap_handler(void) {}
bool henge_ios_jit_prewarm(size_t bytes, size_t min_bytes) { (void)bytes; (void)min_bytes; return false; }
size_t henge_ios_jit_region_bytes(void) { return 0; }
void henge_ios_jit_release(HengeDualMapping *m) { (void)m; }
void henge_ios_jit_detach(void) {}
bool henge_ios_jit_is_available(void) { return false; }
void henge_ios_jit_log_footprint(const char *tag) { (void)tag; }
size_t henge_ios_available_memory(void) { return 0; }

#endif
