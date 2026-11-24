/* The engine (SolsticeVM, ../host/vm.h) as the Swift side sees it. */
#ifndef SOLSTICE_VM_H
#define SOLSTICE_VM_H

#include <stddef.h>
#include <stdint.h>

/* Builds the machine from imported files, on the JIT region the app holds
   (solstice_ios_jit_prewarm), and starts it. 0, or -1 with a reason in err. */
int solstice_vm_boot(const char *rom, const char *disk, const char *aux, uint64_t ecid, uint64_t seed, uint64_t ram_mb,
                  int cpus, char *err, size_t errlen);
/* Installs macOS from an IPSW onto a new machine (blank disk and auxiliary
   storage): boots the ROM in DFU mode and runs the restore over its USB port,
   as Virtualization.framework's installer does. workdir is scratch space.
   0, or -1 with a reason in err; progress below. */
int solstice_vm_install(const char *rom, const char *disk, const char *aux, uint64_t ecid, const char *ipsw,
                     const char *workdir, uint64_t ram_mb, int cpus, char *err, size_t errlen);
/* The restore's step (0 detect, 1 prepare, 2 system image, 3 verify, 4 firmware,
   6 FUD, 7 personalized images; 100 done, 101 failed) and how far it is (0..1). */
int solstice_install_step(void);
double solstice_install_progress(void);
/* Writes a blank auxiliary storage file (what VZMacAuxiliaryStorage makes). 0 or -1. */
int solstice_make_aux(const char *path);

/* Instant resume (../host/snapshot.h). solstice_vm_suspend stops a running Mac where it is and writes it to path; it
   stays paused (SOLSTICE_VM_PAUSED) until solstice_vm_continue runs it on, or solstice_vm_stop ends it. 0 if saved; -1 with a
   reason if not (the Mac then still runs, unless it stopped by itself meanwhile). solstice_vm_resume is solstice_vm_boot
   from a saved Mac: the same settings, and the disk exactly as it was saved, or it fails and nothing runs. ident is
   what the file is valid for (the app's build, the Mac, its disk). solstice_vm_saved_ok: 0 if path is a whole saved
   Mac for ident, and its size and save time. */
int solstice_vm_suspend(const char *path, const char *ident, char *err, size_t errlen);
/* The two halves of solstice_vm_suspend. Pausing needs the GPU (what only it holds goes back into the Mac's memory), which
   iOS refuses an app in the background: pause when Solstice stops being active, save once it is in the background. */
int solstice_vm_pause(char *err, size_t errlen);
/* Paused (SOLSTICE_VM_PAUSED): drops the translated code and gives the engine's tables back, so the waiting Mac costs only its
   own memory until it runs on (it translates again). 0, or -1 if it is not paused. */
int solstice_vm_trim(void);
int solstice_vm_save(const char *path, const char *ident, char *err, size_t errlen);
int solstice_vm_continue(void);
/* What solstice_vm_resume did. REFUSED: the file can never be resumed (damaged, another ident or build, the disk moved on);
   it is deleted and the Mac may start from cold. FAILED: something of the moment (memory, no JIT region, reading), or
   another shape than solstice_vm_saved_shape; the file is kept, and a cold boot stays safe (it moves the disk on, and the
   moved disk refuses the file). */
typedef enum SolsticeVmResume {
    SOLSTICE_VM_RESUME_REFUSED = -2,
    SOLSTICE_VM_RESUME_FAILED = -1,
    SOLSTICE_VM_RESUMED = 0
} SolsticeVmResume;
SolsticeVmResume solstice_vm_resume(const char *rom, const char *disk, const char *aux, uint64_t ecid, uint64_t seed,
                              uint64_t ram_mb, int cpus, const char *path, const char *ident, char *err, size_t errlen);
int solstice_vm_saved_ok(const char *path, const char *ident, uint64_t *bytes, int64_t *saved_at);
/* The shape a whole saved Mac for ident goes back into: its RAM in MB and its CPUs. A resume has to use exactly these
   (another shape is SOLSTICE_VM_RESUME_FAILED, the file kept), so ident need not name them. 0, or nonzero if no such save. */
int solstice_vm_saved_shape(const char *path, const char *ident, uint64_t *ram_mb, int *cpus);
/* A saved Mac is kept while the disk is as it was saved: after a resume (or running on after a save) the file goes
   once the Mac writes its disk, or a new save replaces it. Call now and then while it runs; 1 if the file was deleted
   now. A stop deletes it too if the disk moved. */
int solstice_vm_drop_spent_save(void);
/* 1 if the Mac is paused and has not run since its last save, which is still there: saving again would only rewrite it. */
int solstice_vm_saved_unchanged(void);

/* The machine's state. Normal guests are fully released before SOLSTICE_VM_STOPPED; installer sessions retain
   their restore stack and can_start stays false. */
typedef enum SolsticeVmState {
    SOLSTICE_VM_IDLE,                  /* not started */
    SOLSTICE_VM_RUNNING,
    SOLSTICE_VM_STOPPED,
    SOLSTICE_VM_STARTING_OR_STOPPING,  /* between states: being created, or shutting down and being released */
    SOLSTICE_VM_PAUSED                 /* saved, or being saved */
} SolsticeVmState;
SolsticeVmState solstice_vm_state(void);
/* A new generation starts with each successful boot, even in the same view. */
uint64_t solstice_vm_generation(void);
int solstice_vm_can_start(void);
/* Human-readable terminal reason, once SOLSTICE_VM_STOPPED. */
const char *solstice_vm_exit_reason(void);
/* Terminal outcome once SOLSTICE_VM_STOPPED. Generic HALT alone does not prove a
   guest shutdown (it also covers reset, host stop and guest panic). */
enum SolsticeVmOutcome {
    SOLSTICE_VM_OUTCOME_ERROR, SOLSTICE_VM_OUTCOME_SHUTDOWN, SOLSTICE_VM_OUTCOME_RESTART,
    SOLSTICE_VM_OUTCOME_HOST_STOP, SOLSTICE_VM_OUTCOME_PANIC
};
int solstice_vm_exit_outcome(void);
void solstice_vm_stop(void);
/* Presses the Mac's power button: macOS shuts down properly (or asks first). 0, or -1 if no Mac runs. */
int solstice_vm_power_button(void);
/* Testing: sets a whole-number engine setting (core/knobs.def) in the running machine; nonzero if it exists. */
int solstice_vm_knob(const char *name, int value);
/* The engine settings read again from the environment (EngineTuning.apply, after it sets them). */
void solstice_vm_knobs_load(void);
/* The power profile (PowerPolicy.swift), live and kept for the Macs started later: 0 normal; 1 (Low Power Mode) an
   idle CPU sleeps at once (no HV_WFI_SPIN); 2 (a serious thermal state) also at most HV_SAVING_HZ frames a second go
   to the screen (macOS is still refreshed at its mode's rate); 3 (critical) is the same here, the app pauses the Mac. */
void solstice_vm_set_power_profile(int level);
/* The memory balloon (only with HV_BALLOON set before boot): asks the guest to hand over target_mb (when >= 0)
   and returns how many MB it has handed over, or -1 without a balloon. */
long solstice_vm_balloon(long target_mb);
/* The RAM the Mac started last was given, in MB. */
uint64_t solstice_vm_ram_mb(void);

/* Progress, for the session screen. */
uint64_t solstice_vm_blocks(void);            /* blocks the CPUs entered */
double solstice_vm_blocks_per_second(void);   /* their average rate since the last call (0 the first time, or not running) */
uint64_t solstice_vm_net_frames(int sent);    /* Ethernet frames out (sent = 1) and in */
uint64_t solstice_vm_dns(int which);          /* guest DNS queries answered through iOS's resolver (0), handed to libslirp (1), unanswered in time (2) */
int solstice_vm_cpus_on(void);                /* CPUs the guest has started */
int solstice_vm_guest_el0(void);              /* any CPU running user code right now */

/* The audio session: 1 an interruption began (a call, Siri, an alarm), 0 it ended (the Mac's sound plays again),
   2 the media services were reset (the output is made anew), 3 the route changed. Any thread. */
void solstice_vm_audio_interrupted(int state);

/* Input: Linux key codes, relative pointer, buttons 0 left 1 right 2 middle. */
/* The shared folder and clipboard (host/share.c). solstice_vm_share goes before solstice_vm_boot; agent may be NULL.
   solstice_share_take_clipboard returns what the guest copied, once: a malloc'd string, or NULL. */
void solstice_vm_share(const char *folder, const char *socket_path, const char *agent);
void solstice_share_set_clipboard(const char *text);
char *solstice_share_take_clipboard(void);
long solstice_share_agent_seen(void);
/* 1 once the helper in macOS has the clipboard solstice_share_set_clipboard gave it. */
int solstice_share_clipboard_taken(void);

/* The size macOS is told its screen is. Before solstice_vm_boot. */
void solstice_vm_set_display(uint32_t width, uint32_t height);
/* What the guest's About This Mac says, for the next boot (NULL leaves the vmapple
   identity): the chip's name, the product name, and — experimental — the model
   identifier (hw.model). The chip goes through the config region; the other two
   are fixed up in the guest's device tree while iBoot runs (host/dt_fixup.c). */
void solstice_vm_set_identity(const char *soc_name, const char *product_name, const char *model_id);
/* The panel's physical size; 0, 0 for the default (a ~122 ppi, 1x screen). Before boot. */
void solstice_vm_set_display_mm(uint32_t width_mm, uint32_t height_mm);
void solstice_vm_key(uint16_t code, int down);
void solstice_vm_key_hid(uint8_t usage, int down); /* a hardware keyboard: iOS gives each key's HID usage */
void solstice_vm_mouse_move(int dx, int dy);
void solstice_vm_mouse_button(int button, int down);
/* Wheel units: dy > 0 up, dx > 0 right. */
void solstice_vm_mouse_scroll(int dx, int dy);
/* The Magic Trackpad 2 the Mac sees on its USB bus: a finger on it. phase: 0 down, 1 move, 2 up;
   finger a stable 1..15 per touch; x, y sensor units 0..8134, 0..5206. ts_ms is the touch
   sample's own clock in ms, so the guest computes finger speed from real sample timing. */
void solstice_vm_touch(int finger, int phase, int x, int y, uint32_t ts_ms);
void solstice_vm_touch_frame(uint32_t ts_ms); /* commit one frame with every finger that moved */
void solstice_vm_touch_button(int down); /* the pad's full press (a click) */
/* Put the Mac's pointer at x, y, each 0..1 across its screen: for an iPad pointer iPadOS won't lock. */
void solstice_vm_pointer_at(double x, double y);
/* Its buttons, pressed where it is now: bit 0 left, 1 right, 2 middle. */
void solstice_vm_pointer_buttons(int buttons);
/* Before boot: the Mac's USB keyboard is an ISO one (1) or ANSI (0), to match its keyboard layout. */
void solstice_vm_set_keyboard_iso(int iso);
/* Where the guest has its pointer, in display pixels. 0, or -1 before it has one. */
int solstice_vm_pointer(int *x, int *y);
/* A small picture of the display, BGRA, width * height * 4 bytes. 0, or -1 before anything shows. */
int solstice_vm_snapshot(uint8_t *bgra, int width, int height);

/* The boot framebuffer (Apple logo and progress bar), 32-bit BGRA, or -1 if
   the kernel has not got that far. A successful call returns an owned copy;
   release it with solstice_vm_free_display after use. */
/// Where the Mac's GPU frames go: a CAMetalLayer. Keep it alive while the machine runs.
void solstice_vm_set_display_layer(void *layer);
/// How many frames have gone to it.
uint64_t solstice_vm_gpu_frames(void);
int solstice_vm_boot_display(const uint8_t **pixels, int *width, int *height, int *stride);
void solstice_vm_free_display(const uint8_t *pixels);
/* The same, copied once into the caller's buffer of cap bytes: 0, or -1 (nothing to show, or too small: then width,
   height and stride say what it needs). */
int solstice_vm_boot_display_copy(uint8_t *dst, size_t cap, int *width, int *height, int *stride);

/* The largest single mapping the address space takes right now, in MB (the
   increased virtual addressing entitlement raises it). */
uint64_t solstice_largest_reservation_gb(void); /* measuring: the biggest PROT_NONE reservation, in GB */
uint64_t solstice_largest_mapping_mb(void);
/* The address space the engine's tables take beside guest RAM, in MB, for the JIT region there is now and this many
   CPUs (hv_machine_table_bytes): guest RAM is reserved first, then these. */
uint64_t solstice_engine_tables_mb(int cpus);
/* Bytes this process may still allocate before jetsam (os_proc_available_memory). */
size_t solstice_available_memory(void);
/* The whole system's available memory as jetsam counts it (free and file-backed pages: what iOS can hand out without
   compressing or closing apps), in MB, or -1 if it cannot say. A Mac's RAM is not in Solstice's own footprint, so this,
   not the line above, is what the balloon (MemoryRelief) answers to. */
long solstice_system_headroom_mb(void);

#endif
