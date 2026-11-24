/* SPDX-License-Identifier: GPL-2.0-or-later */
/* The engine as the simulator app for screenshots sees it (ios/screens.yml, ios/Screens/Screens.swift): every C function
   the Swift app calls, with canned answers and no Mac behind them. Never in the device build (ios/project.yml does not
   list ios/Screens). A Mac "boots" at once and shows a placeholder picture. What a screen needs differently comes from
   the environment, set by Screens.prepare before anything asks:
     SOLSTICE_STUB_JIT=0          JIT is off
     SOLSTICE_STUB_STOP=1         a started Mac has shut down at once
     SOLSTICE_STUB_BOOT_ERROR=..  a start fails with this reason */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "solstice-vm.h"
#include "solstice-ios-jit.h"
#include "HuskRPPairing.h"
#include "hvsparse.h"

static SolsticeVmState state = SOLSTICE_VM_IDLE;
static uint64_t generation;
static uint32_t display_w = 1470, display_h = 956;
static uint64_t ram_mb;

static int env_on(const char *name) {
    const char *v = getenv(name);
    return v && *v && strcmp(v, "0") != 0;
}

static void say(char *err, size_t errlen, const char *text) {
    if (err && errlen) snprintf(err, errlen, "%s", text);
}

/* The placeholder Mac: a blue-violet wallpaper, a menu bar and a Dock, w x h BGRA. */
static void draw(uint8_t *bgra, int w, int h, size_t stride) {
    int bar = h / 34 + 1, dock_h = h / 14 + 1, dock_w = w / 2, dock_x = (w - dock_w) / 2, dock_y = h - dock_h - h / 60;
    for (int y = 0; y < h; y++) {
        uint8_t *row = bgra + (size_t)y * stride;
        for (int x = 0; x < w; x++) {
            double t = (double)y / (h > 1 ? h - 1 : 1), s = (double)x / (w > 1 ? w - 1 : 1);
            double r = 40 + 120 * t + 40 * s, g = 70 + 40 * t, b = 170 + 60 * (1 - t);
            int in_dock = y >= dock_y && y < dock_y + dock_h && x >= dock_x && x < dock_x + dock_w;
            if (y < bar || in_dock) { r = r * 0.45 + 140; g = g * 0.45 + 140; b = b * 0.45 + 140; }
            row[4 * x + 0] = (uint8_t)(b > 255 ? 255 : b);
            row[4 * x + 1] = (uint8_t)(g > 255 ? 255 : g);
            row[4 * x + 2] = (uint8_t)(r > 255 ? 255 : r);
            row[4 * x + 3] = 255;
        }
    }
}

static int start(uint64_t ram, char *err, size_t errlen) {
    const char *fail = getenv("SOLSTICE_STUB_BOOT_ERROR");
    if (fail && *fail) { say(err, errlen, fail); return -1; }
    ram_mb = ram;
    generation++;
    state = env_on("SOLSTICE_STUB_STOP") ? SOLSTICE_VM_STOPPED : SOLSTICE_VM_RUNNING;
    return 0;
}

/* The Mac's lifecycle. */
int solstice_vm_boot(const char *rom, const char *disk, const char *aux, uint64_t ecid, uint64_t seed, uint64_t ram,
                  int cpus, char *err, size_t errlen) {
    (void)rom; (void)disk; (void)aux; (void)ecid; (void)seed; (void)cpus;
    return start(ram, err, errlen);
}
SolsticeVmResume solstice_vm_resume(const char *rom, const char *disk, const char *aux, uint64_t ecid, uint64_t seed,
                              uint64_t ram, int cpus, const char *path, const char *ident, char *err, size_t errlen) {
    (void)rom; (void)disk; (void)aux; (void)ecid; (void)seed; (void)cpus; (void)path; (void)ident;
    return start(ram, err, errlen) == 0 ? SOLSTICE_VM_RESUMED : SOLSTICE_VM_RESUME_FAILED;
}
int solstice_vm_install(const char *rom, const char *disk, const char *aux, uint64_t ecid, const char *ipsw,
                     const char *workdir, uint64_t ram, int cpus, char *err, size_t errlen) {
    (void)rom; (void)disk; (void)aux; (void)ecid; (void)ipsw; (void)workdir; (void)ram; (void)cpus;
    say(err, errlen, "There is no installer in the screen previews.");
    return -1;
}
int solstice_install_step(void) { return 2; }
double solstice_install_progress(void) { return 0.63; }
int solstice_make_aux(const char *path) { (void)path; return 0; }
SolsticeVmState solstice_vm_state(void) { return state; }
uint64_t solstice_vm_generation(void) { return generation; }
int solstice_vm_can_start(void) { return state == SOLSTICE_VM_RUNNING || state == SOLSTICE_VM_PAUSED ? 0 : 1; }
const char *solstice_vm_exit_reason(void) { return "the Mac shut down"; }
int solstice_vm_exit_outcome(void) { return SOLSTICE_VM_OUTCOME_SHUTDOWN; }
void solstice_vm_stop(void) { state = SOLSTICE_VM_STOPPED; }
int solstice_vm_power_button(void) { return state == SOLSTICE_VM_RUNNING ? 0 : -1; }
int solstice_vm_pause(char *err, size_t errlen) { (void)err; (void)errlen; if (state != SOLSTICE_VM_RUNNING) return -1; state = SOLSTICE_VM_PAUSED; return 0; }
int solstice_vm_continue(void) { if (state != SOLSTICE_VM_PAUSED) return -1; state = SOLSTICE_VM_RUNNING; return 0; }
int solstice_vm_trim(void) { return state == SOLSTICE_VM_PAUSED ? 0 : -1; }
int solstice_vm_save(const char *path, const char *ident, char *err, size_t errlen) {
    (void)path; (void)ident;
    say(err, errlen, "There is nothing to save in the screen previews.");
    return -1;
}
int solstice_vm_saved_ok(const char *path, const char *ident, uint64_t *bytes, int64_t *saved_at) {
    (void)path; (void)ident; (void)bytes; (void)saved_at;
    return -1;
}
int solstice_vm_saved_shape(const char *path, const char *ident, uint64_t *ram, int *cpus) {
    (void)path; (void)ident; (void)ram; (void)cpus;
    return -1;
}
void solstice_vm_knobs_load(void) {}
int solstice_vm_drop_spent_save(void) { return 0; }
int solstice_vm_saved_unchanged(void) { return 0; }
void solstice_vm_set_power_profile(int level) { (void)level; }
long solstice_vm_balloon(long target_mb) { (void)target_mb; return -1; }
uint64_t solstice_vm_ram_mb(void) { return ram_mb; }

/* What the session's details show. */
uint64_t solstice_vm_blocks(void) { return state == SOLSTICE_VM_RUNNING ? 48000000 : 0; }
double solstice_vm_blocks_per_second(void) { return state == SOLSTICE_VM_RUNNING ? 2.4e6 : 0; }
uint64_t solstice_vm_net_frames(int sent) { return sent ? 1824 : 2311; }
uint64_t solstice_vm_dns(int which) { return which == 0 ? 42 : 0; }
int solstice_vm_cpus_on(void) { return state == SOLSTICE_VM_RUNNING ? 4 : 0; }
int solstice_vm_guest_el0(void) { return state == SOLSTICE_VM_RUNNING; }
void solstice_vm_audio_interrupted(int s) { (void)s; }

/* Sharing. */
void solstice_vm_share(const char *folder, const char *socket_path, const char *agent) { (void)folder; (void)socket_path; (void)agent; }
void solstice_share_set_clipboard(const char *text) { (void)text; }
char *solstice_share_take_clipboard(void) { return NULL; }
long solstice_share_agent_seen(void) { return 0; }
int solstice_share_clipboard_taken(void) { return 0; }

/* The screen. */
void solstice_vm_set_display(uint32_t width, uint32_t height) {
    if (width && height) { display_w = width; display_h = height; }
}
void solstice_vm_set_identity(const char *soc_name, const char *product_name, const char *model_id) { (void)soc_name; (void)product_name; (void)model_id; }
void solstice_vm_set_display_mm(uint32_t width_mm, uint32_t height_mm) { (void)width_mm; (void)height_mm; }
void solstice_vm_set_display_layer(void *layer) { (void)layer; }
uint64_t solstice_vm_gpu_frames(void) { return 0; } /* so the session shows the boot picture: the placeholder */
int solstice_vm_snapshot(uint8_t *bgra, int width, int height) {
    if (!bgra || width <= 0 || height <= 0) return -1;
    draw(bgra, width, height, (size_t)width * 4);
    return 0;
}
int solstice_vm_boot_display_copy(uint8_t *dst, size_t cap, int *width, int *height, int *stride) {
    if (state != SOLSTICE_VM_RUNNING) return -1;
    *width = (int)display_w;
    *height = (int)display_h;
    *stride = (int)display_w * 4;
    if (!dst || cap < (size_t)display_w * 4 * display_h) return -1;
    draw(dst, (int)display_w, (int)display_h, (size_t)display_w * 4);
    return 0;
}

/* Input goes nowhere. */
void solstice_vm_set_keyboard_iso(int iso) { (void)iso; }
void solstice_vm_key(uint16_t code, int down) { (void)code; (void)down; }
void solstice_vm_key_hid(uint8_t usage, int down) { (void)usage; (void)down; }
void solstice_vm_mouse_move(int dx, int dy) { (void)dx; (void)dy; }
void solstice_vm_mouse_button(int button, int down) { (void)button; (void)down; }
void solstice_vm_touch(int finger, int phase, int x, int y, uint32_t ts_ms) { (void)finger; (void)phase; (void)x; (void)y; (void)ts_ms; }
void solstice_vm_touch_frame(uint32_t ts_ms) { (void)ts_ms; }
void solstice_vm_pointer_at(double x, double y) { (void)x; (void)y; }
void solstice_vm_pointer_buttons(int buttons) { (void)buttons; }
int solstice_vm_pointer(int *x, int *y) {
    if (state != SOLSTICE_VM_RUNNING) return -1;
    *x = (int)display_w / 2;
    *y = (int)display_h / 2;
    return 0;
}

/* Memory, as on a phone with room to spare. */
uint64_t solstice_largest_reservation_gb(void) { return 64; }
uint64_t solstice_largest_mapping_mb(void) { return 32768; }
uint64_t solstice_engine_tables_mb(int cpus) { return 256 + 32 * (uint64_t)cpus; }
size_t solstice_available_memory(void) { return (size_t)6 << 30; }
long solstice_system_headroom_mb(void) { return 3072; }

/* JIT (solstice-ios-jit.h). */
void solstice_ios_jit_install_trap_handler(void) {}
static size_t jit_region;
bool solstice_ios_jit_prewarm(size_t bytes, size_t min_bytes) {
    (void)min_bytes;
    if (!solstice_ios_jit_is_available()) return false;
    jit_region = bytes;
    return true;
}
size_t solstice_ios_jit_region_bytes(void) { return jit_region; }
void solstice_ios_jit_detach(void) {}
bool solstice_ios_jit_is_available(void) { const char *v = getenv("SOLSTICE_STUB_JIT"); return !(v && strcmp(v, "0") == 0); }
void solstice_ios_jit_log_footprint(const char *tag) { (void)tag; }

/* Pairing on the device (HuskRPPairing.h): never available here. */
HuskRPPairing *husk_rppairing_new(const char *name, char **error) {
    (void)name;
    if (error) *error = strdup("Pairing is not available in the screen previews.");
    return NULL;
}
uint16_t husk_rppairing_port(const HuskRPPairing *session) { (void)session; return 0; }
const char *husk_rppairing_service_name(const HuskRPPairing *session) { (void)session; return ""; }
size_t husk_rppairing_txt_count(const HuskRPPairing *session) { (void)session; return 0; }
const char *husk_rppairing_txt_key(const HuskRPPairing *session, size_t index) { (void)session; (void)index; return ""; }
const char *husk_rppairing_txt_value(const HuskRPPairing *session, size_t index) { (void)session; (void)index; return ""; }
int32_t husk_rppairing_accept(const HuskRPPairing *session, HuskRPPairingPinCallback pin_callback, void *pin_context,
                              uint8_t **out_plist, size_t *out_len, char **out_device_name, char **error) {
    (void)session; (void)pin_callback; (void)pin_context; (void)out_plist; (void)out_len; (void)out_device_name; (void)error;
    return 2;
}
void husk_rppairing_cancel(const HuskRPPairing *session) { (void)session; }
void husk_rppairing_free(HuskRPPairing *session) { (void)session; }
void husk_rppairing_bytes_free(uint8_t *bytes, size_t len) { (void)len; free(bytes); }
void husk_rppairing_string_free(char *string) { free(string); }

/* Packed disks (hvsparse.h). */
int hv_sparse_pack_progress(const char *src, const char *dst, void (*progress)(uint64_t, uint64_t, void *), void *opaque) {
    (void)src; (void)dst; (void)progress; (void)opaque;
    return -1;
}
int hv_sparse_unpack(const char *src, const char *dst, void (*progress)(uint64_t, uint64_t, void *), void *opaque) {
    (void)src; (void)dst; (void)progress; (void)opaque;
    return -1;
}
