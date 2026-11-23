/* Runs the guest's GPU commands on the host's Metal, on any Apple platform.
   The guest driver serializes Metal calls: an exec names command buffers in a
   task's memory, each a segment holding {tag, size} records, one per call, in
   the formats worked out from the guest driver and listed by the decoders
   below. Objects are named by a number (a ref); the task's object list says
   what each is, and they are made the first time they are used. */

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <stdatomic.h>
#include <os/lock.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <TargetConditionals.h>
#import <IOSurface/IOSurfaceRef.h>
#include <string.h>
#include <sys/utsname.h>
#include <sys/sysctl.h>
#include <mach/mach_time.h>

/* 1080p shrunk onto a phone would make a normal pointer a few dots across; an iPad's screen needs less. */
/* The pointer's settings, read at most once a second: the presenter asks for them every frame. */
/* And the screen's brightness (Details › Display), in thousandths: the presenter dims the frame itself, so the layer
   can be opaque and the system compositor need not blend it. */
static _Atomic uint64_t cursor_settings_next;
static _Atomic int cursor_saved_scale, cursor_sharp = 1, screen_brightness = 1000;
static void cursor_settings_refresh(void) {
    uint64_t now = mach_absolute_time();
    if (now < atomic_load_explicit(&cursor_settings_next, memory_order_relaxed)) return;
    atomic_store_explicit(&cursor_settings_next, now + 24000000, memory_order_relaxed); /* 1 s of 24 MHz ticks */
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    atomic_store(&cursor_saved_scale, (int)[d integerForKey:@"henge.cursor.scale"]);
    NSNumber *sharp = [d objectForKey:@"henge.cursor.sharp"];
    atomic_store(&cursor_sharp, !sharp || sharp.boolValue);
    id bright = [d objectForKey:@"henge.display.brightness"];
    double b = [bright isKindOfClass:[NSNumber class]] ? [bright doubleValue] : 1;
    b = b >= 0.4 ? (b <= 1 ? b : 1) : 0.4; /* the range the app's slider has */
    atomic_store(&screen_brightness, (int)(b * 1000 + 0.5));
}
/* Read the settings again at the next use: the app changed one and wants the screen shown again. */
static void cursor_settings_now(void) { atomic_store_explicit(&cursor_settings_next, 0, memory_order_relaxed); }
static float brightness_now(void) {
    cursor_settings_refresh();
    return atomic_load(&screen_brightness) / 1000.0f;
}
static int cursor_scale(void) {
#if TARGET_OS_IPHONE
    cursor_settings_refresh();
    int saved = atomic_load(&cursor_saved_scale);
    if (saved >= 1 && saved <= 3) return saved;
    static int defaultScale;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct utsname u;
        uname(&u);
        defaultScale = strncmp(u.machine, "iPad", 4) ? 3 : 1;
    });
    return defaultScale;
#else
    return 1;
#endif
}

#include <mach/mach.h>
#include <stdatomic.h>
#include <mach/vm_map.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "pvg_lite.h"
#include "pvg_vblank_clock.h"
#include "metallib.h"

#if !TARGET_OS_IPHONE
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif

/* Metal's own pipeline serialization, on _MTLDevice. The guest's Metal wrote the data. */
@protocol HvMetalSPI
- (id)newRenderPipelineDescriptorWithSerializedData:(dispatch_data_t)d deserializationContext:(id)c;
- (id)newTileRenderPipelineDescriptorWithSerializedData:(dispatch_data_t)d deserializationContext:(id)c;
- (id)newComputePipelineDescriptorWithSerializedData:(dispatch_data_t)d deserializationContext:(id)c;
@end

enum { OBJ_BUFFER = 1, OBJ_TEXTURE = 2, OBJ_FUNCTION = 6, OBJ_SERIALIZED = 7, OBJ_LINEAR_TEXTURE = 8, OBJ_MAPPED_TEXTURE = 0xb };

/* What is known about a made object, so a reused ref is noticed. */
@interface HvObject : NSObject {
@public
    id object;
    uint32_t entry[3];
    /* A buffer's guest pages, mapped contiguously. */
    uint8_t *mapped;
    BOOL mapping_in_buffer; /* the buffer over them frees them */
    BOOL plain_buffer; /* the object is that buffer */
    uint32_t generation; /* a new mapping since: what was made from it is out of date */
    HvObject *follows; /* made from this one's buffer */
    uint32_t follows_generation;
    uint64_t length;
    uint32_t vpage;
    uint32_t *pages;
    /* A texture's layout in guest memory. */
    uint32_t tex_mips, tex_slices;
    uint64_t tex_base, tex_stride;
    uint8_t tex_block_h;
    uint8_t *tex_layout; /* the mip table, 36 bytes each */
    BOOL guest_backed;
    uint32_t retries; /* a mapped texture made before its surface was described: tried again on later uses */
    uint8_t described[0x30]; /* a surface: the older driver's compact description it was made from */
    uint64_t on_mapping; /* a mapped texture: the surface id it is over */
    /* A surface: */
    HvObject *surface;
    uint64_t row;
    uint32_t first;
    uint32_t surface_w, surface_h, fourcc; /* its own, whatever views the guest makes of it */
    id<MTLTexture> scanout; /* the same pixels, as the display reads them */
    /* A multi-plane surface whose view cannot sit on its pages: a real IOSurface, kept up to date from them (newIOSurface). */
    IOSurfaceRef iosurface;
    uint64_t alloc, content_hash;
    /* Source layout for a multi-plane video surface. */
    uint32_t plane_count;
    uint64_t plane_from[4], plane_row[4], plane_h[4];
    /* Each plane's sampled guest bytes when last copied: only the planes the guest changed are copied, so a CPU
       write to one plane (a decoder refilling luma) does not wipe what the GPU drew into another (chroma, alpha). */
    uint64_t plane_hash[4];
    /* For a host IOSurface shared by several mappings (see planar): the same four hashes, kept once for all of
       them, since they describe what the one host surface holds. */
    NSMutableData *shared_hashes;
    /* A heap: private memory, a buffer over all of it. */
    id<MTLBuffer> heap_whole;
    /* A heap's or a private texture's copy in guest memory, and which side has the newest bytes. */
    id<MTLBuffer> guest_copy;
    BOOL host_valid, guest_stale;
    /* What this one is made from, kept for as long as it lives. */
    HvObject *parent;
    /* A multi-plane surface's key in the replay's planar table, while it counts as one of its users. */
    NSString *planar_key;
    /* A multi-plane surface whose planes sit on its guest pages (planar_desc is its description, kept in case a
       view needs the host IOSurface after all), and the key it would have in the planar table. */
    NSData *planar_desc;
    NSString *planar_want;
    BOOL planar_compact;
    /* The command its pages were last checked against the guest's table in (refresh_pages): once is enough. */
    uint32_t checked;
}
@end

@implementation HvObject
- (void)dealloc {
    if (mapped && !mapping_in_buffer) vm_deallocate(mach_task_self(), (vm_address_t)mapped, (length + 0x3fff) & ~0x3fffull);
    if (iosurface) CFRelease(iosurface);
    free(pages);
    free(tex_layout);
}
@end

@class HvContext;

/* A task's objects by ref: each draw names 5 to 15 of them, so a lookup is an index, not two dictionary searches.
   Slots come in pages of OBJ_PAGE, made as refs are met; a ref indexes the task's object list (12 bytes an entry),
   so they are dense. */
#define HV_TASKS 512        /* task ids, as pvg_lite keeps them */
#define OBJ_PAGE 512
#define OBJ_REFS (1u << 22) /* past this a ref is not the guest's: that object list would be 48 MB */
typedef struct HvTaskObjects {
    HvObject *__strong **page; /* page[ref / OBJ_PAGE][ref % OBJ_PAGE] */
    uint32_t pages;
} HvTaskObjects;

/* Task memory pages found while one command runs (task_page): its tables are walked once per page, not once per
   object lookup. Only for that command: the guest may map its memory differently by the next. */
#define HV_WALK 64
typedef struct HvWalk {
    uint64_t vpn;
    uint8_t *host;
    uint32_t task, epoch;
} HvWalk;

@interface HvReplay : NSObject {
@public
    HvPvgLite *lite;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    dispatch_queue_t worker;
    HvTaskObjects task_objs[HV_TASKS]; /* worker only */
    HvWalk walk[HV_WALK];
    uint32_t walk_epoch; /* the command running, for walk and HvObject.checked */
    /* Reused scratch: a command buffer that is not in one piece in host memory, and a range's page numbers. */
    uint8_t *cmd_scratch;
    size_t cmd_cap;
    uint32_t *pages_scratch;
    uint64_t pages_cap;
    NSMutableDictionary<NSNumber *, id<MTLTexture>> *mapped_textures;
    NSMutableDictionary<NSNumber *, HvObject *> *surfaces;
    /* Multi-plane surfaces' host IOSurfaces by the guest memory they stand for: each process maps a surface
       under its own mapping id, and what one draws (macOS 27's WebKit draws pages into b3a8 tiles in its GPU
       process) has to be what another reads (WindowServer). */
    NSMutableDictionary<NSString *, id> *planar;
    NSMutableDictionary<NSString *, NSNumber *> *planar_uses; /* mappings using each: the entry goes with the last one */
    NSMutableDictionary<NSString *, NSMutableData *> *planar_hashes; /* and what its planes held when last copied */
    NSMutableSet<NSString *> *complaints;
    uint64_t execs, draws, failed, heap_bytes, synced, remaps;
    /* Work the GPU has not finished. Stamps are given back in the order they came: the
       GPU's completion handlers run in the order of commit. */
    _Atomic int inflight;
    _Atomic int stopping;
    dispatch_group_t completions;
    id<MTLCommandBuffer> last_cb;
    double encode_time, gpu_wait_time;
    BOOL pipeline_set; /* in the open encoder */
    BOOL tess_factors; /* so is a tessellation factor buffer */
    uint32_t pre_raster_samples, pre_imageblock, pre_threadgroup, pre_tile_w, pre_tile_h; /* for the next pass */
    BOOL tracing; /* HV_PVG_TRACE_FILE exists: say what each exec draws */
    /* The newest frame, BGRA, for hv_pvg_metal_frame, and the same without the pointer on it. */
    uint8_t *frame, *base;
    NSMutableArray<NSValue *> *retired_frames;
    uint32_t frame_w, frame_h;
    /* The pointer: macOS sends it apart from the screen, for the display hardware to overlay. */
    uint8_t *cursor;
    uint32_t cursor_w, cursor_h, cursor_stride;
    int cursor_hot_x, cursor_hot_y;
    BOOL cursor_shown;
    int drawn_x, drawn_y, drawn_w, drawn_h; /* where it is on the frame now */
    double last_capture;
    /* A frame that came too soon after the last: shown shortly, for it may be the last for a long while. */
    uint64_t late_mapping;
    BOOL late, late_queued;
    uint64_t frames, frames_shot;
    /* Showing frames with the GPU: a layer the app gave us. No copies, no conversion on a CPU. */
    CAMetalLayer *layer; /* screen_lock protects the target and its generation */
    uint64_t layer_generation;
    __weak CAMetalLayer *prepared_layer; /* presenter only: each target needs its own setup */
    id<MTLRenderPipelineState> screen_pipe, linear_pipe, cursor_pipe;
    id<MTLFunction> stand_in; /* computeStandIn */
    /* Compiled pipelines kept across sessions (pipelineState:descriptor:). iOS clears its own shader cache between
       launches, so without this every boot compiles each of macOS's pipelines again, about half a second apiece. */
    id<MTLBinaryArchive> archive; /* being filled */
    NSArray<id<MTLBinaryArchive>> *archives; /* saved: earlier boots' files, and this session's saves */
    NSURL *archive_dir;
    NSString *archive_prefix;
    int archive_next; /* the next file's number */
    unsigned long long archive_bytes;
    BOOL archive_dirty, archive_full;
    uint32_t archive_save_seq; /* the save scheduled last: earlier ones see a newer one and leave it to that */
    uint64_t pipes_hit, pipes_compiled, pipes_unsaved, pipes_unsaveable;
    double compile_ms, hit_ms;
    id<MTLTexture> cursor_tex;
    /* The pointer as a layer over the screen's layer, so that moving it needs no pass over the whole screen on the GPU
       and no new drawable. cursor_layer_ok (screen_lock) says it is laid out for the target as it is now. Until then,
       and for a moment after the target or its size changes (a layout that may still be animating, which a sublayer
       would not follow), the presenter draws the pointer into the frame as before. The layers are the cursor queue's. */
    dispatch_queue_t cursor_queue;
    CALayer *overlay_box, *overlay_glyph; /* the screen's area in the target (clips), the pointer in it */
    __weak CAMetalLayer *overlay_parent;
    uint64_t overlay_seq;     /* the image it shows: cursor_seq and how it was made */
    int overlay_bright, overlay_matched;
    BOOL cursor_layer_ok, overlay_hold, cursor_queued, overlay_never;
    uint64_t cursor_seq;      /* screen_lock: a new pointer image */
    double cursor_next;       /* screen_lock: the next layer update, at most one a refresh */
    double present_every;     /* 1 / HV_HZ: frames go out no faster than macOS draws them */
    double last_present;      /* presenter: when the last frame went out, for a present cap (hv_present_wait) */
    __weak CAMetalLayer *opaque_layer; /* presenter: the target made opaque, once a frame of its own was on it */
    id<MTLSamplerState> screen_sampler, cursor_sampler;
    uint64_t on_screen; /* the mapping showing */
    _Atomic uint64_t gpu_frames;
    dispatch_queue_t presenter;
    os_unfair_lock screen_lock; /* what to show, and the pointer as the presenter reads it */
    id<MTLTexture> screen_tex;
    BOOL screen_half, screen_dirty, presenter_running;
    BOOL drawable_retry_pending;
    double drawable_retry_cooldown; /* fresh work coalesces one wake at its expiry */
    uint64_t screen_requests; /* fresh frames/cursor changes, not automatic retries */
    double drawable_retry_deadline; /* at most two seconds of retrying an unavailable target */
    uint32_t screen_w, screen_h;
    id<MTLBuffer> test_readback; /* HV_PVG_GPU_TEST: the drawable's pixels for screenshots */
    const char *shot;
    unsigned shots;
    dispatch_source_t shot_timer;
}
- (void)complain:(NSString *)what;
- (HvObject *)object:(uint32_t)ref task:(uint32_t)task;
- (void)drawCursor;
- (BOOL)hasDisplayLayer;
- (void)kickPresenter:(BOOL)fresh;
- (void)present:(uint64_t)mapping;
- (void)cursorChanged;
- (void)targetChanged;
@end

/* What Metal asks while it reads a serialized pipeline. */
@interface HvContext : NSObject {
@public
    __unsafe_unretained HvReplay *replay;
    uint32_t task;
    NSString *failure;
    id standIn; /* what a failed function lookup returns: nil, except for compute pipelines (makeSerialized) */
}
@end

/* Bytes a pixel takes in the uncompressed formats a surface gets viewed as; 0 for one not listed. */
static NSUInteger pixel_bytes(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatA8Unorm: case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Unorm_sRGB: case MTLPixelFormatR8Snorm:
    case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint: return 1;
    case MTLPixelFormatR16Unorm: case MTLPixelFormatR16Snorm: case MTLPixelFormatR16Uint: case MTLPixelFormatR16Sint: case MTLPixelFormatR16Float:
    case MTLPixelFormatRG8Unorm: case MTLPixelFormatRG8Unorm_sRGB: case MTLPixelFormatRG8Snorm: case MTLPixelFormatRG8Uint: case MTLPixelFormatRG8Sint:
    case MTLPixelFormatB5G6R5Unorm: case MTLPixelFormatA1BGR5Unorm: case MTLPixelFormatABGR4Unorm: case MTLPixelFormatBGR5A1Unorm: return 2;
    case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint: case MTLPixelFormatR32Float: case MTLPixelFormatRG16Unorm: case MTLPixelFormatRG16Snorm:
    case MTLPixelFormatRG16Uint: case MTLPixelFormatRG16Sint: case MTLPixelFormatRG16Float: case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB:
    case MTLPixelFormatRGBA8Snorm: case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGBA8Sint: case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB:
    case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatRGB10A2Uint: case MTLPixelFormatRG11B10Float: case MTLPixelFormatRGB9E5Float:
    case MTLPixelFormatBGR10A2Unorm: return 4;
    case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRG32Float: case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRGBA16Snorm:
    case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRGBA16Float: return 8;
    case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint: case MTLPixelFormatRGBA32Float: return 16;
    default: return 0;
    }
}

/* Metal aborts the app, rather than failing, on a linear texture whose rows don't hold its width or whose row or offset
   isn't aligned. A view the guest makes in another format, or a surface read with the wrong description, can ask for one.
   The last row needs only the texture's width: Metal's own length check (debug layer, "Length required by texture
   offset, bytes per row, height ...") is offset + row * (height - 1) + width * bytes per pixel. Asking for whole rows
   left a macOS icon empty (72x72 on rows of 1440: a whole last row would run 944 bytes past its buffer). */
static BOOL linear_texture_fits(id<MTLDevice> device, MTLTextureDescriptor *t, uint64_t offset, uint64_t row, NSUInteger length) {
    NSUInteger bpp = pixel_bytes(t.pixelFormat);
    if (!bpp) return YES; /* not checked: as before */
    NSUInteger align = [device minimumLinearTextureAlignmentForPixelFormat:t.pixelFormat];
    BOOL ok = row >= t.width * bpp && (!align || (row % align == 0 && offset % align == 0)) && t.height && offset + row * (t.height - 1) + t.width * bpp <= length;
    if (!ok) {
        static int told;
        if (told++ < 8) fprintf(stderr, "hengevm: pvg-metal: a %lux%lu format %lu texture can't sit on rows of %llu bytes at %llu in %lu: left empty\n",
                                (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat, row, offset, (unsigned long)length);
    }
    return ok;
}

static double now_seconds(void) {
    return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) * 1e-9;
}

/* How the half-float display surface is shown. WindowServer writes DISPLAY-ENCODED values there (extended sRGB: the guest's gray 128 is
   0.502, measured on a phone), so mode 0 passes them through. Mode 1 treats them as LINEAR light and applies the sRGB encode,
   which is what this code did before (and was only right for a linear display profile such as ACES CG Linear: with every other profile
   it encodes twice and the screen looks pale). HV_PVG_HALF=linear selects mode 1. */
static _Atomic int hv_half_mode = -1;
static int hv_half_mode_get(void) {
    int m = atomic_load(&hv_half_mode);
    if (m < 0) {
        const char *e = getenv("HV_PVG_HALF");
        m = e && !strcmp(e, "linear") ? 1 : 0;
        atomic_store(&hv_half_mode, m);
    }
    return m;
}
static float hv_half_shown(float v, int mode) { /* what the screen shows for a half-float component */
    v = v < 0 ? 0 : v > 1 ? 1 : v;
    return mode == 1 ? (v <= 0.0031308f ? v * 12.92f : 1.055f * powf(v, 1.0f / 2.4f) - 0.055f) : v;
}

#include "pvg_metal/memory.m" /* objects by ref, the guest task memory under them */

@implementation HvContext
- (void)resetFailureState { failure = nil; }
- (BOOL)hadLookupFailure { return failure != nil; }
- (NSString *)firstFailureReason { return failure; }
/* As Apple's host does: ref 0 is no function (not a failure), and only an object-list entry of type 6 is one. Any other
   object handed to Metal as a function is read as one by the GPU driver. A compute pipeline still gets the stand-in, as
   Metal's deserializer aborts on a nil compute function. */
- (id)functionWithFunctionRef:(unsigned long long)ref {
    if (!ref) {
        if (standIn && !failure) failure = @"function ref 0 in a compute pipeline";
        return standIn;
    }
    HvObject *o = [replay object:(uint32_t)ref task:task];
    if (!o || !o->object || (o->entry[0] & 0xff) != OBJ_FUNCTION) {
        if (!failure) failure = o && o->object ? [NSString stringWithFormat:@"function %llu is an object of type %u", ref, o->entry[0] & 0xff]
                                               : [NSString stringWithFormat:@"function %llu", ref];
        return standIn;
    }
    return o->object;
}
@end

@implementation HvReplay

- (void)dealloc {
    for (uint32_t t = 0; t < HV_TASKS; t++) obj_clear(&task_objs[t]);
    free(cmd_scratch);
    free(pages_scratch);
}

- (void)complain:(NSString *)what {
    if ([complaints containsObject:what]) return;
    [complaints addObject:what];
    fprintf(stderr, "hengevm: pvg-metal: %s\n", what.UTF8String);
}

#include "pvg_metal/pipelines.m" /* functions, pipelines and the saved-pipeline archives, other serialized objects */

#include "pvg_metal/resources.m" /* heaps, buffers and textures */

#include "pvg_metal/surfaces.m" /* surfaces (the guest's IOSurfaces) and textures over them */

#include "pvg_metal/objects.m" /* a ref's object made at first use; guest and GPU copies kept in step */

#include "pvg_metal/decode.m" /* the serialized calls: render, compute, blit, object queries */

#include "pvg_metal/exec.m" /* an exec: its resources, its command buffers, its completion */

#include "pvg_metal/display.m" /* the pointer and the screen: presenter, pointer layer, CPU frames */

@end

#include "pvg_metal/api.m" /* the hv_pvg_metal_* functions */
