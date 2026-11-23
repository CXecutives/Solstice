#define __ASSERT_MACROS_DEFINE_VERSIONS_WITHOUT_UNDERSCORES 0 /* no check() macro from AudioToolbox's headers */
#include "harness.h"

#include <fcntl.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "pvg_lite.h"
#include "sysreg.h"
#include "vmapple.h"

#include "../host/audio_mac.c" /* the player's queue state, for test_audio_lone_began */

DECLARE_PROGRAM(p_timer_irq);
DECLARE_PROGRAM(p_uart);
extern const char devices_programs_begin[], devices_programs_finish[];

/* HV_TEST_WORK, or the system temporary directory: two small disk images go there. */
static const char *work_dir(void) {
    const char *w = getenv("HV_TEST_WORK");
    if (w && *w) return w;
    w = getenv("TMPDIR");
    return w && *w ? w : "/tmp";
}
#define RAM_SIZE (384ull << 20)

static HvMachine m;
static HvCpu cpu;
static HvVmapple board;
static int checks, failures;

static void check(const char *what, uint64_t got, uint64_t want) {
    checks++;
    if (got != want) {
        printf("  FAIL %s: %llx, expected %llx\n", what, (unsigned long long)got, (unsigned long long)want);
        failures++;
    }
}

static uint32_t rd32(uint64_t pa) {
    uint32_t v = 0;
    hv_phys_read(&m, pa, &v, 4);
    return v;
}
static uint8_t rd8(uint64_t pa) {
    uint8_t v = 0;
    hv_phys_read(&m, pa, &v, 1);
    return v;
}
static void wr32(uint64_t pa, uint32_t v) { hv_phys_write(&m, pa, &v, 4); }
static void wr16(uint64_t pa, uint16_t v) { hv_phys_write(&m, pa, &v, 2); }
static void wr8(uint64_t pa, uint8_t v) { hv_phys_write(&m, pa, &v, 1); }
static void wr64(uint64_t pa, uint64_t v) { hv_phys_write(&m, pa, &v, 8); }
static uint8_t *ram(uint64_t pa) { return hv_phys_ptr(&m, pa, 1); }

#define ICC(op0, op1, crn, crm, op2) ((op0) << 14 | (op1) << 11 | (crn) << 7 | (crm) << 3 | (op2))
#define ICC_IAR1 ICC(3, 0, 12, 12, 0)
#define ICC_EOIR1 ICC(3, 0, 12, 12, 1)
#define ICC_PMR ICC(3, 0, 4, 6, 0)
#define ICC_IGRPEN1 ICC(3, 0, 12, 12, 7)
#define ICC_SGI1R ICC(3, 0, 12, 11, 5)

static void test_gic(void) {
    HvGic *g = board.gic;
    check("GICD_TYPER ITLines", rd32(VMAPPLE_GIC_DIST + 4) & 0x1f, HV_GIC_NUM_IRQS / 32 - 1);
    check("GICD_PIDR2 arch rev", (rd32(VMAPPLE_GIC_DIST + 0xffe8) >> 4) & 0xf, 3);
    check("GICR_TYPER Last", (rd32(VMAPPLE_GIC_REDIST + 8) >> 4) & 1, 1);
    check("GICR_WAKER asleep at reset", rd32(VMAPPLE_GIC_REDIST + 0x14), 6);
    wr32(VMAPPLE_GIC_DIST, 3);
    wr32(VMAPPLE_GIC_REDIST + 0x14, 0);
    check("GICR_WAKER awake", rd32(VMAPPLE_GIC_REDIST + 0x14), 0);
    m.icc_write(&m, &cpu, ICC_PMR, 0xff);
    m.icc_write(&m, &cpu, ICC_IGRPEN1, 1);

    /* SPI 33 (UART), level, group 1, priority 0x80 */
    wr32(VMAPPLE_GIC_DIST + 0x84, 1u << 1);
    wr32(VMAPPLE_GIC_DIST + 0x104, 1u << 1);
    wr8(VMAPPLE_GIC_DIST + 0x400 + 33, 0x80);
    check("ISENABLER1 reads back", rd32(VMAPPLE_GIC_DIST + 0x104) & 2, 2);
    hv_gicv3_set_irq(g, 33, 1);
    check("level SPI raises IRQ", m.percpu[0].irq_line, 1);
    check("ISPENDR1 shows it", (rd32(VMAPPLE_GIC_DIST + 0x204) >> 1) & 1, 1);
    check("IAR1 = 33", m.icc_read(&m, &cpu, ICC_IAR1), 33);
    check("active: line drops", m.percpu[0].irq_line, 0);
    check("nothing else pending", m.icc_read(&m, &cpu, ICC_IAR1), 1023);
    m.icc_write(&m, &cpu, ICC_EOIR1, 33);
    check("still-high level re-pends after EOI", m.percpu[0].irq_line, 1);
    hv_gicv3_set_irq(g, 33, 0);
    check("level low: no IRQ", m.percpu[0].irq_line, 0);

    /* With more CPUs, an interrupt raised for CPU 0 wakes it (its own timer's too) but asks for no device poll: every
       one of them polled all the devices. Device work does ask (hv_machine_wake). */
    int ncpus = m.ncpus;
    m.ncpus = 2;
    __atomic_store_n(&m.percpu[0].poll_req, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&cpu.exit_req, 0, __ATOMIC_SEQ_CST);
    hv_gicv3_set_irq(g, 33, 1);
    check("raised for cpu 0: woken", __atomic_load_n(&cpu.exit_req, __ATOMIC_SEQ_CST), 1);
    check("raised for cpu 0: no device poll asked", __atomic_load_n(&m.percpu[0].poll_req, __ATOMIC_SEQ_CST), 0);
    hv_gicv3_set_irq(g, 33, 0);
    hv_machine_wake(&m);
    check("device work: a poll asked of cpu 0", __atomic_load_n(&m.percpu[0].poll_req, __ATOMIC_SEQ_CST), 1);
    m.ncpus = ncpus;
    __atomic_store_n(&m.percpu[0].poll_req, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&cpu.exit_req, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&m.percpu[0].wake_pending, 0, __ATOMIC_SEQ_CST);

    /* PMR masks; a higher-priority interrupt preempts a running one. */
    wr32(VMAPPLE_GIC_DIST + 0x84, 3u << 1);
    wr32(VMAPPLE_GIC_DIST + 0x104, 1u << 2);
    wr8(VMAPPLE_GIC_DIST + 0x400 + 34, 0x40);
    m.icc_write(&m, &cpu, ICC_PMR, 0x80);
    hv_gicv3_set_irq(g, 33, 1);
    check("priority 0x80 masked by PMR 0x80", m.percpu[0].irq_line, 0);
    m.icc_write(&m, &cpu, ICC_PMR, 0xff);
    check("unmasked", m.icc_read(&m, &cpu, ICC_IAR1), 33);
    hv_gicv3_set_irq(g, 34, 1);
    check("higher priority preempts", m.percpu[0].irq_line, 1);
    check("IAR1 = 34", m.icc_read(&m, &cpu, ICC_IAR1), 34);
    m.icc_write(&m, &cpu, ICC_EOIR1, 34);
    hv_gicv3_set_irq(g, 34, 0);
    m.icc_write(&m, &cpu, ICC_EOIR1, 33);
    hv_gicv3_set_irq(g, 33, 0);

    /* Edge SPI: one pulse, one interrupt. */
    wr32(VMAPPLE_GIC_DIST + 0xc08, 2u << 2);  /* ICFGR2: INTID 33 edge */
    hv_gicv3_set_irq(g, 33, 1);
    hv_gicv3_set_irq(g, 33, 0);
    check("edge latched", m.icc_read(&m, &cpu, ICC_IAR1), 33);
    m.icc_write(&m, &cpu, ICC_EOIR1, 33);
    check("edge consumed", m.percpu[0].irq_line, 0);
    wr32(VMAPPLE_GIC_DIST + 0xc08, 0);

    /* SGI 5 to ourselves (redistributor bank) */
    wr32(VMAPPLE_GIC_REDIST + 0x10000 + 0x80, 1u << 5);
    wr32(VMAPPLE_GIC_REDIST + 0x10000 + 0x100, 1u << 5);
    m.icc_write(&m, &cpu, ICC_SGI1R, 5ull << 24 | 1);
    check("SGI to self", m.icc_read(&m, &cpu, ICC_IAR1), 5);
    m.icc_write(&m, &cpu, ICC_EOIR1, 5);
    check("ICENABLER1 clears", (wr32(VMAPPLE_GIC_DIST + 0x184, 6), rd32(VMAPPLE_GIC_DIST + 0x104) & 6), 0);
}

/* The idle storm seen on a device: an idle CPU taken out of WFI by an interrupt tens of thousands of times a second,
   writing its timer each time. The detector logs it once, with the interrupt and the register (printed from the
   dispatcher, not the GIC's register path), and ends the episode after two quiet windows in a row. n windows of SPI 33 acknowledged, each after a WFI if wfi, with a CNTV_CVAL write. */
static void storm_windows(HvGic *g, int n, int wfi) {
    HvStorm *s = &m.percpu[0].storm;
    for (uint32_t i = 0; i < (uint32_t)n * HV_STORM_WINDOW; i++) {
        if (wfi) m.percpu[0].own.stats.wfi++;
        hv_gicv3_set_irq(g, 33, 1);
        uint64_t id = m.icc_read(&m, &cpu, ICC_IAR1);
        hv_storm_msr(&cpu, 3u << 14 | 3u << 11 | 14u << 7 | 3u << 3 | 2u); /* CNTV_CVAL_EL0 */
        m.icc_write(&m, &cpu, ICC_EOIR1, id);
        hv_gicv3_set_irq(g, 33, 0);
        if (i == HV_STORM_WINDOW / 2 && s->armed) { /* recording: the interrupt and the register */
            check("storm: the interrupt counted", s->irq[0].id == 33 && s->irq[0].n == i + 1 && !s->irq[1].n, 1);
            check("storm: the timer write counted", s->msr[0].id == (3u << 14 | 3u << 11 | 14u << 7 | 3u << 3 | 2u), 1);
        }
    }
}

static void test_storm(void) {
    HvGic *g = board.gic;
    HvStorm *s = &m.percpu[0].storm;
    memset(s, 0, sizeof *s);
    wr32(VMAPPLE_GIC_DIST + 0x104, 1u << 1); /* SPI 33 on again (test_gic ended with it off) */
    hv_gicv3_set_irq(g, 33, 1);
    check("storm: SPI 33 is delivered", m.icc_read(&m, &cpu, ICC_IAR1), 33);
    m.icc_write(&m, &cpu, ICC_EOIR1, 33);
    hv_gicv3_set_irq(g, 33, 0);
    memset(s, 0, sizeof *s);
    storm_windows(g, 2, 1);
    check("storm: hot after a fast window with as many WFIs", s->armed, 1);
    check("storm: not logged before it has recorded a window", s->episodes, 0);
    storm_windows(g, 1, 1);
    check("storm: logged once", s->episodes, 1);
    check("storm: noted for the dispatcher to print", s->report, HV_STORM_BEGAN);
    hv_storm_flush(&cpu);
    check("storm: printed once", s->report, 0);
    storm_windows(g, 2, 1);
    check("storm: once per episode", s->episodes, 1);
    /* A rate hovering at the threshold: one cool window between hot ones does not end the episode. */
    storm_windows(g, 1, 0);
    check("storm: one window without WFIs does not end it", s->armed && s->logged && !s->report, 1);
    storm_windows(g, 1, 1);
    storm_windows(g, 1, 0);
    check("storm: hovering is one episode", s->episodes * 2 + s->logged, 3);
    storm_windows(g, 1, 0);
    check("storm: two windows without WFIs end it", s->armed + s->logged, 0);
    check("storm: its end noted for the dispatcher", s->report, HV_STORM_OVER);
    hv_storm_flush(&cpu);
    storm_windows(g, 2, 1);
    check("storm: the next episode is logged again", s->episodes, 2);
    storm_windows(g, 2, 0);
    memset(s, 0, sizeof *s);
    wr32(VMAPPLE_GIC_DIST + 0x184, 1u << 1);
}

/* Device work no thread signals (a display channel waiting for another channel's stamp) while CPU 0 sleeps: the
   kicker polls only a running CPU 0, so CPU 0's own tick keeps the HV_POLL_BUSY cadence while a bit is set; with none,
   no poll comes before the safety poll. A stamp finished while a channel waits asks for a poll at once (with more
   CPUs its interrupt alone wakes CPU 0 without one). Run last: it leaves a display interrupt pending. */
static void test_unsignalled_poll(void) {
    cpu.cntv_ctl = cpu.cntp_ctl = 0; /* no guest timer deadline in the way */
    board.poll_due = 0;
    m.tick(&m, &cpu); /* a poll now */
    uint64_t polled = mach_absolute_time(), polls = HV_ST(&cpu).dev_polls, due = m.tick(&m, &cpu);
    check("nothing flagged: no device poll before the safety poll", due >= polled + HV_DEV_SAFETY - HV_TICKS_MS, 1);
    hv_machine_unsignalled(&m, HV_UNSIG_PVG_CHAN, 1);
    due = m.tick(&m, &cpu);
    check("flagged: the next device poll within HV_POLL_BUSY", due && due <= polled + HV_POLL_BUSY, 1);
    check("flagged: no poll before it is due", HV_ST(&cpu).dev_polls, polls);
    while (mach_absolute_time() < due) {
    }
    m.tick(&m, &cpu);
    check("flagged: polled when it was due", HV_ST(&cpu).dev_polls, polls + 1);

    /* That poll cleared the bit (pvg_lite owns it: no channel waits here); a channel waiting again sets it. */
    check("polled: the bit follows the channels", __atomic_load_n(&m.dev_unsignalled, __ATOMIC_SEQ_CST), 0);
    hv_machine_unsignalled(&m, HV_UNSIG_PVG_CHAN, 1);

    int ncpus = m.ncpus;
    m.ncpus = 2;
    __atomic_store_n(&m.percpu[0].poll_req, 0, __ATOMIC_SEQ_CST);
    hv_pvg_lite_complete(board.pvg, 0, 1);
    check("stamp while a channel waits: a poll asked of cpu 0", __atomic_load_n(&m.percpu[0].poll_req, __ATOMIC_SEQ_CST), 1);
    hv_machine_unsignalled(&m, HV_UNSIG_PVG_CHAN, 0);
    __atomic_store_n(&m.percpu[0].poll_req, 0, __ATOMIC_SEQ_CST);
    hv_pvg_lite_complete(board.pvg, 0, 2);
    check("stamp with no channel waiting: no poll asked", __atomic_load_n(&m.percpu[0].poll_req, __ATOMIC_SEQ_CST), 0);
    m.ncpus = ncpus;
    __atomic_store_n(&cpu.exit_req, 0, __ATOMIC_SEQ_CST);
}

static int make_disk(const char *path, uint64_t size, uint8_t salt) {
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return -1;
    static uint8_t buf[4096];
    for (uint64_t off = 0; off < size; off += sizeof buf) {
        for (size_t i = 0; i < sizeof buf; i++) buf[i] = (uint8_t)((off + i) / 512 * 7 + i + salt);
        if (write(fd, buf, sizeof buf) != (ssize_t)sizeof buf) return -1;
    }
    close(fd);
    return 0;
}

static void test_simple_devices(void) {
    /* cfg region */
    check("cfg version", rd32(VMAPPLE_CONFIG + 0), 2);
    check("cfg nr_cpus", rd32(VMAPPLE_CONFIG + 4), 1);
    uint64_t rs = 0;
    hv_phys_read(&m, VMAPPLE_CONFIG + 0x20, &rs, 8);
    check("cfg ram_size", rs, RAM_SIZE);
    char soc[20];
    for (int i = 0; i < 19; i++) soc[i] = (char)rd8(VMAPPLE_CONFIG + 0x584 + i);
    check("cfg soc_name", memcmp(soc, "Apple M1 (Virtual)", 19), 0);
    check("cfg mac_en0", rd8(VMAPPLE_CONFIG + 0x40 + 5), 0x56);
    uint32_t r1 = rd32(VMAPPLE_CONFIG + 0x38), r2 = rd32(VMAPPLE_CONFIG + 0x38);
    check("cfg rnd changes on every read", r1 != r2, 1);
    wr32(VMAPPLE_CONFIG + 0x3ac, 0x290001);
    check("cfg scratch is writable", rd32(VMAPPLE_CONFIG + 0x3ac), 0x290001);

    /* PL031 */
    uint32_t t = rd32(VMAPPLE_RTC);
    check("RTC within 2 s of host time", (uint64_t)((int64_t)t - (int64_t)time(NULL) + 2) <= 4, 1);
    wr32(VMAPPLE_RTC + 8, 1000000);
    check("RTC load", rd32(VMAPPLE_RTC) - 1000000 <= 2, 1);
    check("RTC PeriphID0", rd32(VMAPPLE_RTC + 0xfe0), 0x31);
    wr32(VMAPPLE_RTC + 0x10, 1);
    wr32(VMAPPLE_RTC + 4, rd32(VMAPPLE_RTC)); /* match now */
    check("RTC alarm on SPI 2", board.gic->level[32 + VMAPPLE_IRQ_RTC], 1);
    wr32(VMAPPLE_RTC + 0x1c, 1);
    check("RTC alarm cleared", board.gic->level[32 + VMAPPLE_IRQ_RTC], 0);

    /* PL011 receive side */
    wr32(VMAPPLE_UART + 0x38, 1u << 4);  /* IMSC: RX */
    check("UART RX empty", (rd32(VMAPPLE_UART + 0x18) >> 4) & 1, 1);
    hv_pl011_receive(board.uart, 'Z');
    check("UART RX line", board.gic->level[32 + VMAPPLE_IRQ_UART], 1);
    check("UART DR", rd32(VMAPPLE_UART), 'Z');
    check("UART RX line drops", board.gic->level[32 + VMAPPLE_IRQ_UART], 0);
    wr32(VMAPPLE_UART + 0x38, 0);
}

static void test_bdif(HvDisk *root, HvDisk *aux) {
    /* request at RAM+0x1000: sector cmd, data, retval */
    uint64_t base = VMAPPLE_MEM;
    uint64_t req = base + 0x1000, sec = base + 0x2000, data = base + 0x3000, ret = base + 0x4000;
    uint32_t sector[4] = {0, 0, 3, 0};
    memcpy(ram(sec), sector, 16);
    uint8_t r[48] = {0};
    uint64_t a;
    uint32_t l, f;
    a = sec; l = 16; f = 0; memcpy(r, &a, 8); memcpy(r + 8, &l, 4); memcpy(r + 12, &f, 4);
    a = data; l = 1024; f = 0x00030001; memcpy(r + 16, &a, 8); memcpy(r + 24, &l, 4); memcpy(r + 28, &f, 4);
    a = ret; l = 1; f = 0; memcpy(r + 32, &a, 8); memcpy(r + 40, &l, 4); memcpy(r + 44, &f, 4);
    memcpy(ram(req), r, 48);
    check("bdif status", rd32(VMAPPLE_BDOOR), 1);
    check("bdif root capacity", rd32(VMAPPLE_BDOOR + 0x420), root->size / 512);
    check("bdif aux capacity", rd32(VMAPPLE_BDOOR + 0x10000 + 0x420), aux->size / 512);
    uint64_t original_size = root->size;
    root->size = 96ull << 30;
    check("bdif expanded root capacity", rd32(VMAPPLE_BDOOR + 0x420), (96ull << 30) / 512);
    root->size = original_size;
    for (int which = 0; which < 2; which++) {
        HvDisk *d = which ? aux : root;
        ram(ret)[0] = 0xee;
        wr64(VMAPPLE_BDOOR + (which ? 0x10000 : 0) + 0x408, req);
        static uint8_t want[1024];
        hv_disk_read(d, 3 * 512, want, 1024);
        check(which ? "bdif aux read ok" : "bdif root read ok", ram(ret)[0], 0);
        check(which ? "bdif aux data" : "bdif root data", memcmp(ram(data), want, 1024), 0);
    }

    /* The 27.3 upgrade firmware reads this asset in one request. */
    const uint32_t large_length = 285216768;
    const uint64_t disk_offset = 4ull << 20;
    const uint64_t large_data = base + (32ull << 20);
    const uint8_t marker = 0xa7;
    check("large boot disk fixture", ftruncate(root->fd, (off_t)(disk_offset + large_length)), 0);
    root->size = disk_offset + large_length;
    check("large boot asset first marker", pwrite(root->fd, &marker, 1, (off_t)disk_offset), 1);
    check("large boot asset last marker", pwrite(root->fd, &marker, 1, (off_t)(root->size - 1)), 1);
    sector[2] = (uint32_t)(disk_offset / 512);
    memcpy(ram(sec), sector, sizeof sector);
    memcpy(r + 16, &large_data, sizeof large_data);
    memcpy(r + 24, &large_length, sizeof large_length);
    memcpy(ram(req), r, sizeof r);
    ram(ret)[0] = 0xee;
    wr64(VMAPPLE_BDOOR + 0x408, req);
    check("bdif large boot asset read", ram(ret)[0], 0);
    check("bdif large read first byte", ram(large_data)[0], marker);
    check("bdif large read last byte", ram(large_data)[large_length - 1], marker);

    uint64_t invalid_buffer = base + RAM_SIZE - 1024;
    memcpy(r + 16, &invalid_buffer, sizeof invalid_buffer);
    memcpy(ram(req), r, sizeof r);
    wr64(VMAPPLE_BDOOR + 0x408, req);
    check("bdif rejects large read outside guest RAM", ram(ret)[0], 1);
    check("restore boot disk fixture", ftruncate(root->fd, (off_t)original_size), 0);
    root->size = original_size;
}

/* A small virtio driver, as a guest would do it. */
static uint64_t find_slot(uint16_t vendor, uint16_t device, int nth) {
    for (int s = 0; s < 32; s++) {
        uint32_t id = rd32(VMAPPLE_PCIE_ECAM + ((uint64_t)s << 15));
        if (id == ((uint32_t)device << 16 | vendor) && nth-- == 0) return (uint64_t)s;
    }
    return ~0ull;
}

static uint64_t setup_virtio(int slot, uint64_t bar, uint64_t ring) {
    uint64_t cfg = VMAPPLE_PCIE_ECAM + ((uint64_t)slot << 15);
    wr32(cfg + 0x20, 0xffffffff);
    check("BAR4 size 16 KB, 64-bit", rd32(cfg + 0x20), 0xffffc004);
    wr32(cfg + 0x20, (uint32_t)bar);
    wr32(cfg + 0x24, 0);
    wr16(cfg + 0x04, 0x6); /* memory, bus master */
    /* walk the capabilities to the common config */
    uint8_t cap = rd8(cfg + 0x34);
    int found = 0;
    while (cap) {
        if (rd8(cfg + cap) == 0x09 && rd8(cfg + cap + 3) == 1 && rd8(cfg + cap + 4) == 4) found = 1;
        cap = rd8(cfg + cap + 1);
    }
    check("virtio common cfg capability", found, 1);
    wr8(bar + 0x14, 0);
    wr8(bar + 0x14, 1 | 2); /* ACKNOWLEDGE, DRIVER */
    wr32(bar + 0x00, 1);
    check("VERSION_1 offered", rd32(bar + 0x04) & 1, 1);
    wr32(bar + 0x08, 1);
    wr32(bar + 0x0c, 1);
    wr8(bar + 0x14, 1 | 2 | 8);
    check("FEATURES_OK", rd8(bar + 0x14) & 8, 8);
    for (int q = 0; q < 2; q++) {
        uint64_t qr = ring + (uint64_t)q * 0x4000;
        memset(ram(qr), 0, 0x4000);
        wr16(bar + 0x16, (uint16_t)q);
        wr16(bar + 0x18, 16);
        wr64(bar + 0x20, qr);
        wr64(bar + 0x28, qr + 0x1000);
        wr64(bar + 0x30, qr + 0x2000);
        wr16(bar + 0x1c, 1);
    }
    wr8(bar + 0x14, 1 | 2 | 8 | 4);
    return ring;
}

static void put_desc(uint64_t table, int i, uint64_t addr, uint32_t len, uint16_t flags, uint16_t next) {
    uint8_t *d = ram(table + 16u * i);
    memcpy(d, &addr, 8);
    memcpy(d + 8, &len, 4);
    memcpy(d + 12, &flags, 2);
    memcpy(d + 14, &next, 2);
}

static void offer(uint64_t ring, uint16_t head) {
    uint16_t *avail = (uint16_t *)ram(ring + 0x1000);
    avail[2 + avail[1] % 16] = head;
    avail[1]++;
}

static uint16_t used_idx(uint64_t ring) {
    return ((uint16_t *)ram(ring + 0x2000))[1];
}

static void test_virtio_blk(HvDisk *aux) {
    int slot = (int)find_slot(0x106b, 0x1a00, 0);
    check("Apple virtio-blk (aux) enumerated", slot != (int)~0u, 1);
    if (slot < 0 || slot >= 32) return;
    check("class: SCSI storage", rd32(VMAPPLE_PCIE_ECAM + ((uint64_t)slot << 15) + 8) >> 8, 0x010000);
    /* Walk the capabilities as AppleVirtIO's transport does: vendor data, cfg_type 9, vendor 0x106b. */
    {
        uint64_t c = VMAPPLE_PCIE_ECAM + ((uint64_t)slot << 15);
        int found = 0;
        for (uint8_t at = rd8(c + 0x34); at; at = rd8(c + at + 1)) {
            if (rd8(c + at) != 0x09 || rd8(c + at + 3) != 9) continue;
            uint16_t vend = (uint16_t)(rd8(c + at + 4) | rd8(c + at + 5) << 8);
            if (vend == 0x106b && rd8(c + at + 2) >= 6 + 8 && (rd8(c + at + 6) & 1)) found = 1;
        }
        check("Apple vendor data says: not inline-encrypted", found, 1);
    }
    uint64_t bar = VMAPPLE_PCIE_MMIO + 0x100000;
    uint64_t ring = setup_virtio(slot, bar, VMAPPLE_MEM + 0x100000);
    check("blk capacity", rd32(bar + 0x2000), (uint32_t)(aux->size / 512));
    check("apple type in max_secure_erase_sectors", rd32(bar + 0x2000 + 60), HV_VBLK_AUX);

    uint64_t hdr = VMAPPLE_MEM + 0x200000, data = hdr + 0x1000, status = hdr + 0x3000;
    /* read sectors 5-6 */
    uint32_t h[4] = {0, 0, 5, 0};
    memcpy(ram(hdr), h, 16);
    put_desc(ring, 0, hdr, 16, 1, 1);
    put_desc(ring, 1, data, 1024, 1 | 2, 2);
    put_desc(ring, 2, status, 1, 2, 0);
    ram(status)[0] = 0xff;
    offer(ring, 0);
    wr16(bar + 0x3000, 0);
    hv_virtio_blk_drain(board.aux_blk); /* requests complete on the worker thread */
    static uint8_t want[1024];
    hv_disk_read(aux, 5 * 512, want, 1024);
    check("blk read completed", used_idx(ring), 1);
    check("blk read status", ram(status)[0], 0);
    check("blk read data", memcmp(ram(data), want, 1024), 0);
    int line = 32 + VMAPPLE_IRQ_PCIE + slot;
    check("INTx raised", board.gic->level[line], 1);
    check("ISR", rd8(bar + 0x1000), 1);
    check("ISR read drops INTx", board.gic->level[line], 0);

    /* write sector 9, then read it back from the file */
    h[0] = 1;
    h[2] = 9;
    memcpy(ram(hdr), h, 16);
    for (int i = 0; i < 512; i++) ram(data)[i] = (uint8_t)(i ^ 0x5a);
    put_desc(ring, 3, hdr, 16, 1, 4);
    put_desc(ring, 4, data, 512, 1, 5);
    put_desc(ring, 5, status, 1, 2, 0);
    offer(ring, 3);
    wr16(bar + 0x3000, 0);
    hv_virtio_blk_drain(board.aux_blk); /* requests complete on the worker thread */
    uint8_t back[512];
    hv_disk_read(aux, 9 * 512, back, 512);
    check("blk write status", ram(status)[0], 0);
    check("blk write reached the file", memcmp(back, ram(data), 512), 0);

    /* Apple barrier, then an unknown type */
    h[0] = 0x10000;
    memcpy(ram(hdr), h, 16);
    put_desc(ring, 6, hdr, 16, 1, 7);
    put_desc(ring, 7, status, 1, 2, 0);
    offer(ring, 6);
    wr16(bar + 0x3000, 0);
    hv_virtio_blk_drain(board.aux_blk); /* requests complete on the worker thread */
    check("Apple barrier OK", ram(status)[0], 0);
    h[0] = 77;
    memcpy(ram(hdr), h, 16);
    offer(ring, 6);
    wr16(bar + 0x3000, 0);
    hv_virtio_blk_drain(board.aux_blk); /* requests complete on the worker thread */
    check("unknown request UNSUPP", ram(status)[0], 2);
    check("four requests used", used_idx(ring), 4);

    /* Discard: DumpPanic clears the aux panic store with DKIOCUNMAP, and the
       range must then read as zeros or the old panic is reported every boot. */
    wr32(bar + 0x00, 0);
    check("aux offers DISCARD and WRITE_ZEROES", rd32(bar + 0x04) & (3u << 13), 3u << 13);
    check("max_discard_seg", rd32(bar + 0x2000 + 40), 32);
    h[0] = 11;
    h[2] = 0;
    memcpy(ram(hdr), h, 16);
    uint32_t range[4] = {9, 0, 1, 0}; /* sector 9 (low, high), 1 sector, no flags */
    memcpy(ram(data), range, 16);
    put_desc(ring, 8, hdr, 16, 1, 9);
    put_desc(ring, 9, data, 16, 1, 10);
    put_desc(ring, 10, status, 1, 2, 0);
    offer(ring, 8);
    wr16(bar + 0x3000, 0);
    hv_virtio_blk_drain(board.aux_blk);
    check("discard UNSUPP unless negotiated", ram(status)[0], 2);
    board.aux_blk->vio.driver_features |= 3ull << 13;
    offer(ring, 8);
    wr16(bar + 0x3000, 0);
    hv_virtio_blk_drain(board.aux_blk);
    static const uint8_t zero[512];
    hv_disk_read(aux, 9 * 512, back, 512);
    check("discard status", ram(status)[0], 0);
    check("discarded sector reads as zeros", memcmp(back, zero, 512), 0);
    rd8(bar + 0x1000);
}

/* The main disk. A request's buffers go to the file in one call and come back across other boundaries; a batch with
   flushes in it keeps its order with eight requests in flight (a write after a flush never lands before it, a read
   after it sees the last write); a flush with nothing written since does not reach the file system; a discard and a
   write-zeroes read back as zeros, the edges exactly, and the whole blocks in between become holes in the image. */
static void test_virtio_blk_root(HvDisk *root) {
    int slot = (int)find_slot(0x106b, 0x1a00, 1);
    check("Apple virtio-blk (root) enumerated", slot >= 0 && slot < 32, 1);
    if (slot < 0 || slot >= 32) return;
    uint64_t bar = VMAPPLE_PCIE_MMIO + 0x400000;
    uint64_t ring = setup_virtio(slot, bar, VMAPPLE_MEM + 0x600000);
    HvVirtioBlk *blk = board.root_blk;
    const uint64_t base = VMAPPLE_MEM + 0x700000, data = base + 0x10000;
#define HDR(i) (base + (uint64_t)(i) * 0x40)
#define ST(i) (base + 0x400 + (uint64_t)(i) * 0x10)
    uint16_t used = used_idx(ring);
    static uint8_t want[4096], back[4096];

    /* A write in three buffers of 100, 1948 and 2048 bytes, apart in guest memory... */
    for (int i = 0; i < 4096; i++) want[i] = (uint8_t)(i * 31 + 7) ^ (uint8_t)(i >> 8);
    uint32_t h[4] = {1, 0, 100, 0};
    memcpy(ram(HDR(0)), h, 16);
    memcpy(ram(data), want, 100);
    memcpy(ram(data + 0x1000), want + 100, 1948);
    memcpy(ram(data + 0x2000), want + 2048, 2048);
    put_desc(ring, 0, HDR(0), 16, 1, 1);
    put_desc(ring, 1, data, 100, 1, 2);
    put_desc(ring, 2, data + 0x1000, 1948, 1, 3);
    put_desc(ring, 3, data + 0x2000, 2048, 1, 4);
    put_desc(ring, 4, ST(0), 1, 2, 0);
    ram(ST(0))[0] = 0xff;
    offer(ring, 0);
    wr16(bar + 0x3000, 0);
    hv_virtio_blk_drain(blk);
    check("scattered write status", ram(ST(0))[0], 0);
    hv_disk_read(root, 100 * 512, back, 4096);
    check("scattered write reached the file whole", memcmp(back, want, 4096), 0);
    /* ...read back into buffers of 1000, 3000 and 96 bytes. */
    h[0] = 0;
    memcpy(ram(HDR(0)), h, 16);
    memset(ram(data + 0x4000), 0, 0x3000);
    put_desc(ring, 1, data + 0x4000, 1000, 1 | 2, 2);
    put_desc(ring, 2, data + 0x5000, 3000, 1 | 2, 3);
    put_desc(ring, 3, data + 0x6000, 96, 1 | 2, 4);
    ram(ST(0))[0] = 0xff;
    offer(ring, 0);
    wr16(bar + 0x3000, 0);
    hv_virtio_blk_drain(blk);
    check("scattered read status", ram(ST(0))[0], 0);
    int same = !memcmp(ram(data + 0x4000), want, 1000) && !memcmp(ram(data + 0x5000), want + 1000, 3000) &&
               !memcmp(ram(data + 0x6000), want + 4000, 96);
    check("scattered read: the same bytes across other boundaries", same, 1);
    check("two requests used", (uint16_t)(used_idx(ring) - used), 2);

    /* Write A, flush, write B to the same sector, flush, read it: all handed over at once, twenty times. */
    uint64_t syncs = root->syncs;
    int order_ok = 1, status_ok = 1;
    for (int k = 0; k < 20; k++) {
        uint8_t a = (uint8_t)(2 * k + 1), b = (uint8_t)(2 * k + 2);
        uint32_t wr[4] = {1, 0, 200, 0}, fl[4] = {4, 0, 0, 0}, rd[4] = {0, 0, 200, 0};
        memcpy(ram(HDR(1)), wr, 16), memcpy(ram(HDR(2)), fl, 16), memcpy(ram(HDR(3)), wr, 16), memcpy(ram(HDR(4)), fl, 16);
        memcpy(ram(HDR(5)), rd, 16);
        memset(ram(data + 0x8000), a, 512), memset(ram(data + 0x9000), b, 512), memset(ram(data + 0xa000), 0, 512);
        put_desc(ring, 0, HDR(1), 16, 1, 1), put_desc(ring, 1, data + 0x8000, 512, 1, 2), put_desc(ring, 2, ST(1), 1, 2, 0);
        put_desc(ring, 3, HDR(2), 16, 1, 4), put_desc(ring, 4, ST(2), 1, 2, 0);
        put_desc(ring, 5, HDR(3), 16, 1, 6), put_desc(ring, 6, data + 0x9000, 512, 1, 7), put_desc(ring, 7, ST(3), 1, 2, 0);
        put_desc(ring, 8, HDR(4), 16, 1, 9), put_desc(ring, 9, ST(4), 1, 2, 0);
        put_desc(ring, 10, HDR(5), 16, 1, 11), put_desc(ring, 11, data + 0xa000, 512, 1 | 2, 12), put_desc(ring, 12, ST(5), 1, 2, 0);
        for (int i = 1; i <= 5; i++) ram(ST(i))[0] = 0xff;
        offer(ring, 0), offer(ring, 3), offer(ring, 5), offer(ring, 8), offer(ring, 10);
        wr16(bar + 0x3000, 0);
        hv_virtio_blk_drain(blk);
        for (int i = 1; i <= 5; i++) status_ok &= ram(ST(i))[0] == 0;
        hv_disk_read(root, 200 * 512, back, 512);
        for (int i = 0; i < 512; i++) order_ok &= back[i] == b && ram(data + 0xa000)[i] == b;
    }
    check("batches with flushes: every status OK", status_ok, 1);
    check("batches with flushes: the later write wins, the read after the flush sees it", order_ok, 1);
    check("each flush after a write reached the file system", root->syncs - syncs, 40);
    /* A flush with nothing written since: answered at once. */
    syncs = root->syncs;
    put_desc(ring, 0, HDR(2), 16, 1, 1), put_desc(ring, 1, ST(2), 1, 2, 0);
    ram(ST(2))[0] = 0xff;
    offer(ring, 0);
    wr16(bar + 0x3000, 0);
    hv_virtio_blk_drain(blk);
    check("flush with nothing new: OK", ram(ST(2))[0], 0);
    check("flush with nothing new: no file system flush", root->syncs - syncs, 0);

    /* Discard sectors 65-192 of a written range, unaligned at both ends. */
    wr32(bar + 0x00, 0);
    check("root offers DISCARD and WRITE_ZEROES", rd32(bar + 0x04) & (3u << 13), 3u << 13);
    blk->vio.driver_features |= 3ull << 13;
    static uint8_t ones[128 << 10], got[128 << 10];
    static const uint8_t zero[128 << 10];
    memset(ones, 0xab, sizeof ones);
    hv_disk_write(root, 64 * 512, ones, sizeof ones); /* sectors 64-319 */
    fsync(root->fd);
    uint32_t dh[4] = {11, 0, 0, 0}, range[4] = {65, 0, 128, 0};
    memcpy(ram(HDR(6)), dh, 16);
    memcpy(ram(data + 0xb000), range, 16);
    put_desc(ring, 0, HDR(6), 16, 1, 1), put_desc(ring, 1, data + 0xb000, 16, 1, 2), put_desc(ring, 2, ST(6), 1, 2, 0);
    ram(ST(6))[0] = 0xff;
    offer(ring, 0);
    wr16(bar + 0x3000, 0);
    hv_virtio_blk_drain(blk);
    check("root discard status", ram(ST(6))[0], 0);
    hv_disk_read(root, 64 * 512, got, sizeof got);
    check("the sector before the discard kept", memcmp(got, ones, 512), 0);
    check("discarded sectors read as zeros", memcmp(got + 512, zero, 128 * 512), 0);
    check("the sectors after the discard kept", memcmp(got + 129 * 512, ones, sizeof got - 129 * 512), 0);
    uint64_t hb = root->hole, from = 65 * 512, to = (65 + 128) * 512;
    check("the test disk's file system makes holes", hb != 0, 1);
    if (hb) {
        uint64_t first = (from + hb - 1) / hb * hb, last = to / hb * hb;
        off_t hole = lseek(root->fd, (off_t)from, SEEK_HOLE);
        check("discarded blocks are a hole in the image", hole >= (off_t)first && hole < (off_t)last, 1);
        check("the stats count the bytes punched", root->punched, last > first ? last - first : 0);
    }
    check("the stats count the discard", blk->discards, 1);
    /* Write-zeroes, sectors 250-259. */
    dh[0] = 13, range[0] = 250, range[2] = 10;
    memcpy(ram(HDR(6)), dh, 16);
    memcpy(ram(data + 0xb000), range, 16);
    ram(ST(6))[0] = 0xff;
    offer(ring, 0);
    wr16(bar + 0x3000, 0);
    hv_virtio_blk_drain(blk);
    check("root write-zeroes status", ram(ST(6))[0], 0);
    check("a write-zeroes is no discard", blk->discards, 1);
    hv_disk_read(root, 249 * 512, got, 12 * 512);
    check("write-zeroes: zeros, neighbours kept", !memcmp(got, ones, 512) && !memcmp(got + 512, zero, 10 * 512) && !memcmp(got + 11 * 512, ones, 512), 1);
    /* A flush after a discard has something to make safe. */
    syncs = root->syncs;
    put_desc(ring, 0, HDR(2), 16, 1, 1), put_desc(ring, 1, ST(2), 1, 2, 0);
    offer(ring, 0);
    wr16(bar + 0x3000, 0);
    hv_virtio_blk_drain(blk);
    check("flush after a discard reached the file system", root->syncs - syncs, 1);
    rd8(bar + 0x1000);
#undef HDR
#undef ST
}

static uint8_t sent[2048];
static uint32_t sent_len;
static void capture_tx(void *opaque, const uint8_t *frame, uint32_t len) {
    (void)opaque;
    memcpy(sent, frame, len < sizeof sent ? len : sizeof sent);
    sent_len = len;
}

static int rx_ready_calls;
static void count_rx_ready(void *opaque) {
    (void)opaque;
    rx_ready_calls++;
}

static void test_virtio_net(void) {
    int slot = (int)find_slot(0x1af4, 0x1041, 0);
    check("virtio-net enumerated", slot >= 0 && slot < 32, 1);
    if (slot < 0 || slot >= 32) return;
    uint64_t bar = VMAPPLE_PCIE_MMIO + 0x200000;
    uint64_t ring = setup_virtio(slot, bar, VMAPPLE_MEM + 0x300000);
    check("net MAC in config", rd8(bar + 0x2000 + 5), 0x56);
    board.net->transmit = capture_tx;
    uint64_t rxq = ring, txq = ring + 0x4000, buf = VMAPPLE_MEM + 0x400000;
    /* transmit: 12-byte header + 60-byte frame */
    memset(ram(buf), 0, 12);
    for (int i = 0; i < 60; i++) ram(buf + 12)[i] = (uint8_t)i;
    put_desc(txq, 0, buf, 72, 0, 0);
    offer(txq, 0);
    wr16(bar + 0x3000 + 4, 1);
    check("TX frame length", sent_len, 60);
    check("TX frame bytes", sent[59], 59);
    /* receive */
    uint8_t frame[64];
    for (int i = 0; i < 64; i++) frame[i] = (uint8_t)(0xa0 + i);
    check("RX with no buffer drops", hv_virtio_net_receive(board.net, frame, 64), 0);
    put_desc(rxq, 0, buf + 0x1000, 2048, 2, 0);
    offer(rxq, 0);
    wr16(bar + 0x3000, 0);
    check("RX delivered", hv_virtio_net_receive(board.net, frame, 64), 1);
    hv_virtio_net_rx_done(board.net);
    check("RX bytes", memcmp(ram(buf + 0x1000 + 12), frame, 64), 0);
    check("RX header: checksum not vouched for unless negotiated", ram(buf + 0x1000)[0], 0);
    uint32_t used_len;
    memcpy(&used_len, ram(rxq + 0x2000 + 8), 4);
    check("RX used length", used_len, 76);

    /* New receive buffers bring the frames that waited for them at once, not at the next poll. */
    board.net->rx_ready = count_rx_ready;
    rx_ready_calls = 0;
    put_desc(rxq, 1, buf + 0x1800, 2048, 2, 0);
    offer(rxq, 1);
    wr16(bar + 0x3000, 0);
    check("RX buffers posted: waiting frames delivered", rx_ready_calls, 1);
    /* With GUEST_CSUM the guest is told libslirp's checksums are good (DATA_VALID). */
    board.net->vio.driver_features |= 1ull << 1;
    check("RX delivered into the new buffer", hv_virtio_net_receive(board.net, frame, 64), 1);
    hv_virtio_net_rx_done(board.net);
    check("RX header: DATA_VALID with GUEST_CSUM", ram(buf + 0x1800)[0], 2);
    board.net->rx_ready = NULL;

    /* With CSUM a frame may leave its checksum to the host (NEEDS_CSUM, csum_start, csum_offset): RFC 1071's example,
       whose sum is 0xddf2. */
    static const uint8_t rfc[10] = {0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7, 0, 0};
    board.net->vio.driver_features |= 1ull << 0;
    memset(ram(buf), 0, 12);
    ram(buf)[0] = 1;                             /* NEEDS_CSUM */
    wr16(buf + 6, 0), wr16(buf + 8, 8);          /* from byte 0, into bytes 8-9 */
    memcpy(ram(buf + 12), rfc, sizeof rfc);
    put_desc(txq, 0, buf, 12 + sizeof rfc, 0, 0);
    offer(txq, 0);
    wr16(bar + 0x3000 + 4, 1);
    check("TX NEEDS_CSUM: the checksum filled in", (uint32_t)sent[8] << 8 | sent[9], 0x220d);
    check("TX NEEDS_CSUM: the rest as sent", memcmp(sent, rfc, 8), 0);
    uint8_t odd[5] = {0x12, 0x34, 0x56, 0, 0}; /* an odd length pads with a zero byte */
    hv_virtio_net_finish_csum(odd, 5, 0, 3);
    check("checksum of an odd length", (uint32_t)odd[3] << 8 | odd[4], (uint16_t)~(0x1234 + 0x5600));
    hv_virtio_net_finish_csum(odd, 5, 4, 0); /* the field past the frame: left alone */
    check("checksum field out of the frame ignored", odd[4], (uint16_t)~(0x1234 + 0x5600) & 0xff);
    board.net->vio.driver_features &= ~3ull;
}

/* Sound whose host player stopped (iOS took the audio session for a call): the stream drains by the wall clock from
   that moment, at its rate, so the guest's buffers keep coming back; with the player back the clock stops again. */
static int fake_start(void *opaque, unsigned channels, unsigned format, unsigned rate_hz) {
    (void)opaque, (void)channels, (void)format, (void)rate_hz;
    return 0;
}
static void fake_stop(void *opaque) { (void)opaque; }

static void test_virtio_snd_drain(void) {
    HvVirtioSnd *d = board.snd;
    check("virtio-snd made", d != NULL, 1);
    if (!d) return;
    const unsigned rate = 48000, frame = 4;
    d->backend = (HvVirtioSndBackend){fake_start, fake_stop, d};
    d->running = 1, d->frame_bytes = frame, d->rate_hz = rate;
    atomic_store(&d->written, HV_VSND_RING / 2);
    atomic_store(&d->consumed, 0);
    d->clock_start_ns = 1, d->clock_start_consumed = 0; /* the stream began long ago */
    hv_virtio_snd_poll(d);
    check("snd: a playing host player drains, not the clock", atomic_load(&d->consumed), 0);
    atomic_store(&d->host_off, 1);
    hv_virtio_snd_poll(d);
    check("snd: the clock drain starts from now, not from the stream's start", atomic_load(&d->consumed), 0);
    usleep(20000);
    hv_virtio_snd_poll(d);
    uint64_t c = atomic_load(&d->consumed);
    check("snd: the player off, the stream drains by the clock", c >= (uint64_t)rate * frame / 100 && c < HV_VSND_RING / 2, 1);
    atomic_store(&d->host_off, 0);
    usleep(5000);
    hv_virtio_snd_poll(d);
    check("snd: the player back, the clock stops", atomic_load(&d->consumed), c);
    d->running = 0, d->backend = (HvVirtioSndBackend){0};
    atomic_store(&d->written, 0);
    atomic_store(&d->consumed, 0);
}

/* The player starting again while a poll that still saw it off drains by the clock: the render callback's pull and
   the poll both move `consumed`, and it only ever goes forward (a step back would play audio twice and return
   buffers out of step). While the clock drains, the kicker polls for it (nothing else signals its progress). */
static _Atomic int snd_race_stop, snd_race_back;

static void *snd_puller(void *arg) {
    HvVirtioSnd *d = arg;
    uint8_t buf[256];
    uint64_t last = 0;
    while (!atomic_load(&snd_race_stop)) {
        uint64_t c = atomic_load(&d->consumed);
        if (c < last) atomic_store(&snd_race_back, 1);
        last = c;
        hv_virtio_snd_pull(d, buf, sizeof buf);
    }
    return NULL;
}

/* iOS does not send an "ended" for every "began" (an app back from suspension gets a lone "began"): a new stream from
   the guest still tries the player, and either it plays or the stream drains by the clock, never silent and stuck. */
static void audio_queue_done(void *ctx) { (void)ctx; }

static void test_audio_lone_began(void) {
    HvVirtioSnd *d = board.snd;
    if (!d) return;
    hv_audio_attach(d);
    hv_audio_interrupted();
    d->backend.start(d->backend.opaque, 2, HV_VSND_FMT_S16, 48000);
    dispatch_sync_f(queue, NULL, audio_queue_done);
    check("sound: a stream start after a lone 'began' tries the player", atomic_load(&interrupted), 0);
    UInt32 playing = 0, size = sizeof playing;
    if (unit) AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &playing, &size);
    check("sound: the player plays, or the stream drains by the clock", playing ? !atomic_load(&d->host_off) : atomic_load(&d->host_off) != 0, 1);
    hv_audio_detach();
    d->backend = (HvVirtioSndBackend){0};
    atomic_store(&d->host_off, 0);
}

static void test_virtio_snd_forward(void) {
    HvVirtioSnd *d = board.snd;
    if (!d) return;
    d->backend = (HvVirtioSndBackend){fake_start, fake_stop, d};
    d->running = 1, d->frame_bytes = 4, d->rate_hz = 0; /* the clock's target: clock_start_consumed, set below */
    atomic_store(&d->written, 1ull << 40);               /* never runs dry */
    atomic_store(&d->consumed, 0);
    atomic_store(&d->host_off, 1);
    hv_virtio_snd_poll(d);
    check("snd: the clock drains with no buffer waiting: no polling for it", d->vio.m->dev_unsignalled & HV_UNSIG_SND_CLOCK, 0);
    uint32_t head = d->phead; /* one buffer waiting, its audio not all played yet */
    d->phead = head - 1, d->pending_end[(head - 1) % HV_VSND_PENDING] = UINT64_MAX;
    hv_virtio_snd_poll(d);
    check("snd: the clock drains with a buffer waiting: the kicker polls for it", (d->vio.m->dev_unsignalled & HV_UNSIG_SND_CLOCK) != 0, 1);
    d->phead = head;
    hv_virtio_snd_poll(d);
    check("snd: no buffer waiting any more: no polling for it", d->vio.m->dev_unsignalled & HV_UNSIG_SND_CLOCK, 0);
    d->phead = head - 1;
    hv_virtio_snd_poll(d);
    atomic_store(&snd_race_stop, 0);
    atomic_store(&snd_race_back, 0);
    pthread_t t;
    pthread_create(&t, NULL, snd_puller, d);
    for (int i = 0; i < 200000 && !atomic_load(&snd_race_back); i++) {
        d->clock_start_consumed = atomic_load(&d->consumed) + 512; /* just ahead: the pull may pass it meanwhile */
        hv_virtio_snd_poll(d);
    }
    atomic_store(&snd_race_stop, 1);
    pthread_join(t, NULL);
    check("snd: a poll and a pull together never move consumed backwards", atomic_load(&snd_race_back), 0);
    atomic_store(&d->host_off, 0);
    hv_virtio_snd_poll(d);
    check("snd: the player back, the kicker stops polling for the clock", d->vio.m->dev_unsignalled & HV_UNSIG_SND_CLOCK, 0);
    d->phead = head;
    d->running = 0, d->backend = (HvVirtioSndBackend){0};
    atomic_store(&d->written, 0);
    atomic_store(&d->consumed, 0);
}

/* The memory balloon: a new target reaches the driver (config change interrupt), inflated 16 KB pages go back
   to the OS (with the RAM file under the board, as holes: they read as zero at once), a page with only some
   of its 4 KB quarters stays, a driver listing one page number per 16 KB page works too, and deflate counts. */
static void put_pfns(uint64_t buf, const uint32_t *pfn, int n) { memcpy(ram(buf), pfn, 4u * n); }

static void test_virtio_balloon(void) {
    int slot = (int)find_slot(0x1af4, 0x1045, 0);
    check("virtio-balloon enumerated (HV_BALLOON)", slot >= 0 && slot < 32, 1);
    if (slot < 0 || slot >= 32 || !board.balloon) return;
    HvVirtioBalloon *b = board.balloon;
    check("balloon has the RAM file", b->ram_fd >= 0, 1);
    uint64_t bar = VMAPPLE_PCIE_MMIO + 0x300000;
    uint64_t ring = setup_virtio(slot, bar, VMAPPLE_MEM + 0x1000000);
    uint64_t inq = ring, deq = ring + 0x4000, list = VMAPPLE_MEM + 0x1800000, pages = VMAPPLE_MEM + 0x2000000;
    rd8(bar + 0x1000); /* clear the ISR */
    hv_virtio_balloon_set_target(b, 1 << 20);
    hv_virtio_balloon_poll(b);
    check("num_pages in 4 KB pages", rd32(bar + 0x2000), 256);
    check("config change in the ISR", rd8(bar + 0x1000) & 2, 2);
    /* three 16 KB pages of 0x5a: the first and third listed whole, the second missing a quarter */
    memset(ram(pages), 0x5a, 3 * 0x4000);
    uint32_t p0 = (uint32_t)(pages >> 12);
    uint32_t pfn[11] = {p0, p0 + 1, p0 + 2, p0 + 3, p0 + 4, p0 + 5, p0 + 7, p0 + 8, p0 + 9, p0 + 10, p0 + 11};
    put_pfns(list, pfn, 11);
    put_desc(inq, 0, list, 44, 0, 0);
    offer(inq, 0);
    wr16(bar + 0x3000, 0);
    check("inflate element used", used_idx(inq), 1);
    check("two whole pages given back", b->given_back, 2);
    check("the page missing a quarter kept", b->partial, 1);
    check("given-back page reads zero", rd32(pages), 0);
    check("given-back page's end reads zero", rd32(pages + 0x3ffc), 0);
    check("kept page keeps its bytes", rd8(pages + 0x4000), 0x5a);
    check("third page reads zero", rd32(pages + 0x8000), 0);
    /* a driver that lists one page number per 16 KB page (quarter 0 only) */
    memset(ram(pages + 0xc000), 0x77, 2 * 0x4000);
    uint32_t whole[2] = {p0 + 12, p0 + 16};
    put_pfns(list, whole, 2);
    put_desc(inq, 1, list, 8, 0, 0);
    offer(inq, 1);
    wr16(bar + 0x3000, 0);
    check("one number per 16 KB page: both given back", b->given_back, 4);
    check("...and read zero", rd8(pages + 0x10000) | rd8(pages + 0xc000), 0);
    /* the driver says how much it holds */
    wr32(bar + 0x2000 + 4, 256);
    check("actual read back", hv_virtio_balloon_actual(b), 1 << 20);
    check("num_pages stays the host's", (wr32(bar + 0x2000, 7), rd32(bar + 0x2000)), 256);
    /* deflate the first page */
    put_pfns(list, pfn, 4);
    put_desc(deq, 0, list, 16, 0, 0);
    offer(deq, 0);
    wr16(bar + 0x3000 + 4, 1);
    check("deflate element used", used_idx(deq), 1);
    check("deflated page taken back", b->taken_back, 1);
    check("page numbers outside RAM ignored", b->out_of_ram, 0);
    /* anonymous RAM (the phone's): pages are marked reusable */
    HvVirtioBalloon *a = hv_virtio_balloon_create(&m, board.pcie, board.ram, VMAPPLE_MEM, RAM_SIZE, -1);
    int aslot = (int)find_slot(0x1af4, 0x1045, 1);
    uint64_t abar = VMAPPLE_PCIE_MMIO + 0x380000;
    uint64_t aring = setup_virtio(aslot, abar, VMAPPLE_MEM + 0x1100000);
    put_pfns(list + 0x1000, pfn, 4);
    put_desc(aring, 0, list + 0x1000, 16, 0, 0);
    offer(aring, 0);
    wr16(abar + 0x3000, 0);
    check("anonymous: page given back", a->given_back, 1);
    check("anonymous: madvise did not fail", a->failed, 0);

    /* CPU 0's tick polls the devices only when woken for them or at a device deadline (O9): a new balloon target (work
       no device thread signals) waits for a wake or HV_DEV_SAFETY, not for every tick, e.g. a timer register write. */
    hv_cpu_wake(&cpu);
    m.tick(&m, &cpu); /* woken: polls, and the next poll is due HV_DEV_SAFETY from now */
    hv_virtio_balloon_set_target(b, 2 << 20);
    uint64_t t0 = mach_absolute_time();
    uint64_t due = m.tick(&m, &cpu);
    if (mach_absolute_time() - t0 < HV_DEV_SAFETY / 2) check("a tick without a wake or deadline polls nothing", rd32(bar + 0x2000), 256);
    check("CPU 0's deadline is the next poll at the latest", due && due <= t0 + HV_DEV_SAFETY, 1);
    hv_machine_wake(&m);
    m.tick(&m, &cpu);
    check("a wake for device work polls", rd32(bar + 0x2000), 512);
    hv_virtio_balloon_set_target(b, 1 << 20);
    hv_machine_wake(&m);
    m.tick(&m, &cpu);
    rd8(bar + 0x1000); /* the config change in the ISR */
}

/* M1: guest RAM in a file is read in ahead of the guest, not written (that made the kernel owe the file the whole RAM in
   writeback to flash): every page comes in, none is dirty. mincore tells dirty pages apart (one written on purpose). */
static void test_prefault(void) {
    char path[1024];
    snprintf(path, sizeof path, "%s/hv-test-prefault", work_dir());
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) { check("prefault: test file", 0, 1); return; }
    unlink(path);
    const size_t page = (size_t)getpagesize(), n = 64, size = n * page;
    uint8_t *p = ftruncate(fd, (off_t)size) == 0 ? mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) : MAP_FAILED;
    if (p == MAP_FAILED) { check("prefault: test mapping", 0, 1); close(fd); return; }
    p[size - page] = 1; /* the last page: written */
    hv_vmapple_prefault(p, size - page);
    char vec[64];
    int in = 0, dirty = 0;
    if (mincore(p, size, vec) == 0) {
        for (size_t i = 0; i + 1 < n; i++) in += (vec[i] & MINCORE_INCORE) != 0, dirty += (vec[i] & (MINCORE_MODIFIED | MINCORE_MODIFIED_OTHER)) != 0;
        check("prefault: every page read in", (uint64_t)in, n - 1);
        if (vec[n - 1] & (MINCORE_MODIFIED | MINCORE_MODIFIED_OTHER)) check("prefault: no page dirtied", (uint64_t)dirty, 0);
        else printf("prefault: mincore does not report dirty file pages here; %d of %zu read in\n", in, n - 1);
    } else {
        check("prefault: mincore", 0, 1);
    }
    munmap(p, size);
    close(fd);
}

/* FIPS-197 appendix C.1: AES-128, key 000102..0f, plaintext 00112233..ff. */
static void test_aes(void) {
    const uint64_t fifo = VMAPPLE_AES_1 + 0x200, src = VMAPPLE_MEM + 0x500000, dst = src + 0x100;
    static const uint8_t pt[16] = {0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                                   0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff};
    static const uint8_t ct[16] = {0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30,
                                   0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a};
    memcpy(ram(src), pt, 16);
    check("aes status at reset", rd32(VMAPPLE_AES_1 + 0x0c), 0x3f80);
    wr32(fifo, 1u << 28 | 1u << 20); /* KEY: context 0, AES-128, encrypt, ECB */
    for (int i = 0; i < 4; i++) wr32(fifo, 0x03020100u + 0x04040404u * (uint32_t)i);
    wr32(fifo, 5u << 28 | 16); /* DATA: 16 bytes */
    wr32(fifo, 0);
    wr32(fifo, (uint32_t)src);
    wr32(fifo, (uint32_t)dst);
    check("aes-128 ECB known answer", memcmp(ram(dst), ct, 16), 0);
    wr32(VMAPPLE_AES_1 + 0x1c, 1u << 5);
    wr32(fifo, 8u << 28 | 1u << 27 | 0x42); /* FLAG with interrupt */
    check("aes flag raises SPI 0x12", board.gic->level[32 + VMAPPLE_IRQ_AES], 1);
    check("aes flag info", rd32(VMAPPLE_AES_1 + 0x30), 0x42);
    wr32(VMAPPLE_AES_1 + 0x18, 1u << 5);
    check("aes interrupt cleared", board.gic->level[32 + VMAPPLE_IRQ_AES], 0);
}

static char uart_out[128];
static int uart_n;
static void capture_uart(void *opaque, uint8_t c) {
    (void)opaque;
    if (uart_n < (int)sizeof uart_out - 1) uart_out[uart_n++] = (char)c;
}

/* The trackpad's reports, as they wait for the guest: the newest, n back from the end. */
static const uint8_t *tp_back(HvXhci *x, uint32_t n, unsigned *len) {
    unsigned at = (x->tp_rtail - 1 - n) % HV_TP_REPORTS;
    *len = x->tp_rlen[at];
    return x->tp_reports[at];
}
static uint32_t tp_stamp(const uint8_t *r) { return (uint32_t)(r[9] >> 3) | (uint32_t)r[10] << 5 | (uint32_t)r[11] << 13; }
static int tp_state(const uint8_t *r, int finger) { return (r[12 + 9 * finger + 3] >> 5) & 7; }

/* The USB input devices with a guest that reads nothing (as one under load): what waits for it. */
static void test_xhci_input(HvXhci *x) {
    unsigned len;
    /* A long drag, then the lift: the lift and the final "no fingers" report are what count. */
    x->tp_rhead = x->tp_rtail;
    uint32_t t = 1000;
    hv_xhci_touch(x, 1, 0, 4000, 2500, t);
    for (int i = 0; i < 200; i++) {
        hv_xhci_touch(x, 1, 1, 4000 + i, 2500, t += 8);
        hv_xhci_touch_frame(x, t);
    }
    hv_xhci_touch(x, 1, 2, 0, 0, t += 8);
    check("trackpad: no more waiting than the ring holds", x->tp_rtail - x->tp_rhead <= HV_TP_REPORTS, 1);
    const uint8_t *r = tp_back(x, 0, &len);
    check("trackpad: a lift after a long drag ends in no fingers", len, 12);
    r = tp_back(x, 1, &len);
    check("trackpad: ... after the finger's stop", len == 21 && tp_state(r, 0) == 7, 1);
    r = tp_back(x, 2, &len);
    check("trackpad: ... after its newest place", len == 21 && r[12] == (uint8_t)(4199 - HV_TP_SENSOR_X / 2), 1);
    r = x->tp_reports[x->tp_rhead % HV_TP_REPORTS];
    check("trackpad: the touch still comes first", x->tp_rlen[x->tp_rhead % HV_TP_REPORTS] == 21 && tp_state(r, 0) == 4, 1);
    int increasing = 1;
    for (uint32_t i = x->tp_rhead + 1; i != x->tp_rtail; i++)
        increasing &= tp_stamp(x->tp_reports[i % HV_TP_REPORTS]) > tp_stamp(x->tp_reports[(i - 1) % HV_TP_REPORTS]);
    check("trackpad: stamps keep increasing", increasing, 1);
    /* Nothing but taps: the newest still gets in. */
    for (int i = 0; i < 100; i++) {
        hv_xhci_touch(x, 2, 0, 4000, 2500, t += 8);
        hv_xhci_touch(x, 2, 2, 0, 0, t += 8);
    }
    check("trackpad: taps fill the ring", x->tp_rtail - x->tp_rhead, HV_TP_REPORTS);
    tp_back(x, 0, &len);
    check("trackpad: the last tap's lift is there", len, 12);

    /* The secondary click: two fingers rest, the pad is pressed, released, the fingers lift. */
    x->tp_rhead = x->tp_rtail;
    hv_xhci_secondary_click(x, 1);
    r = tp_back(x, 0, &len);
    check("secondary click: pressed with two fingers", len == 30 && (r[1] & 1) && tp_state(r, 0) == 4 && tp_state(r, 1) == 4, 1);
    r = tp_back(x, 1, &len);
    check("secondary click: the fingers rest first", len == 30 && !(r[1] & 1), 1);
    hv_xhci_secondary_click(x, 0);
    r = tp_back(x, 2, &len);
    check("secondary click: released with the fingers down", len == 30 && !(r[1] & 1), 1);
    r = tp_back(x, 1, &len);
    check("secondary click: the fingers stop", len == 30 && tp_state(r, 0) == 7, 1);
    tp_back(x, 0, &len);
    check("secondary click: and lift", len, 12);
    check("secondary click: five reports", x->tp_rtail - x->tp_rhead, 5);
    x->tp_rhead = x->tp_rtail;

    /* The absolute pointer: a click's press and release each reach the guest, where they happened. */
    x->ptr_rhead = x->ptr_rtail;
    hv_xhci_pointer(x, 100, 200);
    hv_xhci_pointer_buttons(x, 1);
    hv_xhci_pointer_buttons(x, 0);
    hv_xhci_pointer(x, 300, 400);
    hv_xhci_pointer(x, 500, 600);
    check("pointer: moves merge, buttons queue", x->ptr_rtail - x->ptr_rhead, 4);
    const uint8_t *p = x->ptr_reports[(x->ptr_rhead + 1) % HV_PTR_REPORTS];
    check("pointer: pressed at the first place", p[0] == 1 && (p[1] | p[2] << 8) == 100, 1);
    p = x->ptr_reports[(x->ptr_rhead + 2) % HV_PTR_REPORTS];
    check("pointer: released there too", p[0] == 0 && (p[1] | p[2] << 8) == 100, 1);
    p = x->ptr_reports[(x->ptr_rhead + 3) % HV_PTR_REPORTS];
    check("pointer: then the newest place", p[0] == 0 && (p[1] | p[2] << 8) == 500 && (p[3] | p[4] << 8) == 600, 1);
    x->ptr_rhead = x->ptr_rtail;

    /* The ISO key beside the left Shift (Linux KEY_102ND) is HID usage 0x64. */
    hv_xhci_key_linux(x, 86, 1);
    check("keyboard: the ISO key", x->state[2], 0x64);
    hv_xhci_key_linux(x, 86, 0);
    /* Forward delete (KEY_DELETE), for the on-screen key row. */
    hv_xhci_key_linux(x, 111, 1);
    check("keyboard: forward delete", x->state[2], 0x4c);
    hv_xhci_key_linux(x, 111, 0);
    x->rhead = x->rtail;
}

static void test_guest_programs(void) {
    static HvCpu init;
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)devices_programs_begin, devices_programs_finish - devices_programs_begin,
                       (void *)devices_programs_begin, 1);
    static const TestProgram timer = TEST_PROGRAM(p_timer_irq), uart = TEST_PROGRAM(p_uart);

    /* Fresh GIC state for the guest to configure. */
    HvGic *g = board.gic;
    memset(g->enabled, 0, sizeof g->enabled);
    memset(g->cpu[0].enabled, 0, sizeof g->cpu[0].enabled);
    g->ctlr = 0;
    g->cpu[0].igrpen1 = 0;
    g->cpu[0].waker = 6;
    memset(&init, 0, sizeof init);
    seed_cpu(&init, 3, VMAPPLE_MEM + 0x10000);
    uint64_t t0 = hv_counter();
    if (run_jit(&m, &timer, &init, &cpu, NULL) == 0) {
        check("timer IRQ INTID", cpu.x[20], 27);
        check("one IRQ", cpu.x[21], 1);
        check("waited about 1 ms (counter delta >= 24000)", cpu.x[11] - cpu.x[10] >= 24000, 1);
        check("not absurdly long (< 50 ms)", hv_counter() - t0 < 24000 * 50, 1);
        check("no stray exceptions", cpu.x[23], 0);
        check("RPR idle after EOI", cpu.x[12], 0xff);
    } else {
        failures++;
    }

    board.uart->output = capture_uart;
    memset(&init, 0, sizeof init);
    seed_cpu(&init, 4, VMAPPLE_MEM + 0x10000);
    if (run_jit(&m, &uart, &init, &cpu, NULL) == 0) {
        check("UART output", strcmp(uart_out, "hello from the guest\n"), 0);
        check("PL011 PeriphID0", cpu.x[4], 0x11);
    } else {
        failures++;
    }
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (hv_machine_init(&m, 4 << 20) != 0) return 1;
    char root_path[1024], aux_path[1024];
    snprintf(root_path, sizeof root_path, "%s/hv-test-root.img", work_dir());
    snprintf(aux_path, sizeof aux_path, "%s/hv-test-aux.img", work_dir());
    if (make_disk(root_path, 1 << 20, 1) || make_disk(aux_path, 256 << 10, 2)) {
        printf("cannot create test disks in %s\n", work_dir());
        return 1;
    }
    static HvDisk root, aux;
    hv_disk_open(&root, root_path, 0, 0);
    hv_disk_open(&aux, aux_path, 16384, 0); /* as with auxiliary.bin: skip the 16 KB header */
    HvCfgParams cfg = {.nr_cpus = 1, .ecid = 0x1234, .mac_en0 = {2, 0, 0, 0x12, 0x34, 0x56}};
    /* The balloon, over guest RAM in a file (holes read as zero at once) */
    char ram_path[1024];
    snprintf(ram_path, sizeof ram_path, "%s/hv-test-ram", work_dir());
    setenv("HV_BALLOON", "0", 1);
    setenv("HV_RAM_FILE", ram_path, 1);
    setenv("HV_RAM_NO_LEDGER", "1", 1);
    setenv("HV_RAM_NO_PREFAULT", "1", 1);
    static const uint8_t mac[6] = {2, 0, 0, 0x12, 0x34, 0x56};
    if (hv_vmapple_reserve_ram(&board, RAM_SIZE) != 0 || hv_vmapple_create(&board, &m, &cpu, &root, &aux, &cfg, mac) != 0) return 1;
    hv_vmapple_reset_cpu(&board);
    check("reset pc", cpu.pc, VMAPPLE_FIRMWARE);
    check("aux disk skips its 16 KB header", aux.size, (256 << 10) - 16384);

    test_gic();
    test_storm();
    test_simple_devices();
    test_bdif(&root, &aux);
    test_virtio_blk(&aux);
    test_virtio_blk_root(&root);
    test_virtio_net();
    test_virtio_snd_drain();
    test_virtio_snd_forward();
    test_audio_lone_began();
    test_virtio_balloon();
    puts("devices done; aes, msi, gpio"); /* where a trap under SAN=1 is, without a debugger */
    test_aes();
    test_prefault();
    /* xHCI: the Supported Protocol capability names as many ports (a count, bits 15:8) as HCSPARAMS1 has */
    HvPciDev *usb = &board.usb->pci;
    check("xhci MaxPorts", usb->bar_read(usb, 0, 4, 4) >> 24, HV_XHCI_PORTS);
    check("xhci USB 2 protocol covers every port, from port 1",
          usb->bar_read(usb, 0, 0x800 + 8, 4) & 0xffff, 1u | (uint32_t)HV_XHCI_PORTS << 8);
    test_xhci_input(board.usb);
    /* MSI frame: valid type register, doorbell pends the INTID */
    check("msi type valid", rd32(VMAPPLE_GIC_MSI + 8) >> 31, 1);
    check("msi base", (rd32(VMAPPLE_GIC_MSI + 8) >> 16) & 0x1fff, VMAPPLE_MSI_BASE);
    wr32(VMAPPLE_GIC_MSI + 0x40, VMAPPLE_MSI_BASE + 3);
    check("msi doorbell pends the INTID", board.gic->latch[VMAPPLE_MSI_BASE + 3], 1);
    /* PL061: power button on pin 3, rising edge */
    wr32(VMAPPLE_GPIO + 0x40c, 1u << 3); /* IEV: rising edge */
    wr32(VMAPPLE_GPIO + 0x410, 1u << 3);
    check("gpio PeriphID0", rd32(VMAPPLE_GPIO + 0xfe0), 0x61);
    hv_pl061_set_input(board.gpio, 3, 1);
    check("gpio pin 3 reads high", rd32(VMAPPLE_GPIO + (1u << 3 << 2)), 1u << 3);
    check("gpio edge raises SPI 5", board.gic->level[32 + VMAPPLE_IRQ_GPIO], 1);
    wr32(VMAPPLE_GPIO + 0x41c, 1u << 3);
    check("gpio interrupt cleared", board.gic->level[32 + VMAPPLE_IRQ_GPIO], 0);
    /* The guest programs run on the JIT, whose own tests (test_jit, test_mem) cover it under SAN=1; here they are the
       devices' interrupts seen from a guest. */
#if defined(__has_feature)
#if __has_feature(undefined_behavior_sanitizer)
#define TEST_UB_TRAPS 1
#endif
#endif
#ifdef TEST_UB_TRAPS
    puts("guest programs: left to the JIT's own tests under undefined-behaviour traps");
#else
    puts("guest programs");
    test_guest_programs();
#endif
    test_unsignalled_poll();

    hv_disk_close(&root);
    hv_disk_close(&aux);
    unlink(root_path);
    unlink(aux_path);
    printf("%d checks, %d failures\n", checks, failures);
    return failures != 0;
}
