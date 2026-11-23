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
    id<MTLBuffer> readback;
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
- (void)screenChanged;
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
   0.502, measured with the colour probe), so mode 0 passes them through. Mode 1 treats them as LINEAR light and applies the sRGB encode,
   which is what this code did before (and was only right for a linear display profile such as ACES CG Linear: with every other profile
   it encodes twice and the screen looks pale). HV_PVG_HALF=linear selects mode 1 at start; with the colour probe on, a file named
   mode-linear or mode-encoded in its folder switches it while running. */
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

#include "pvg_colorprobe.h" /* HV_COLOR_PROBE: what the display is told and shown, for chasing colour problems */

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

HvPvgMetal *hv_pvg_metal_create(HvPvgLite *lite) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return NULL;
        if (![dev respondsToSelector:@selector(newRenderPipelineDescriptorWithSerializedData:deserializationContext:)]) {
            fprintf(stderr, "hengevm: pvg-metal: this Metal cannot read serialized pipelines; no drawing\n");
            return NULL;
        }
        Protocol *proto = objc_getProtocol("MTLDeserializationContext");
        if (proto) class_addProtocol([HvContext class], proto);
        HvReplay *r = [HvReplay new];
        r->lite = lite;
        r->completions = dispatch_group_create();
        r->device = dev;
        r->queue = [dev newCommandQueueWithMaxCommandBufferCount:64];
        r->worker = dispatch_queue_create("hengevm.pvg", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        r->presenter = dispatch_queue_create("hengevm.present", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        r->cursor_queue = dispatch_queue_create("hengevm.cursor", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        const char *hz = getenv("HV_HZ");
        int rate = hz && atoi(hz) >= 30 && atoi(hz) <= 120 ? atoi(hz) : 60;
        r->present_every = 1.0 / rate;
        r->overlay_matched = -1;
        /* Screenshots of the drawable (the GPU test, the colour probe) want the pointer in it. */
        r->overlay_never = getenv("HV_PVG_GPU_TEST") || getenv("HV_COLOR_PROBE");
        r->screen_lock = OS_UNFAIR_LOCK_INIT;
        r->walk_epoch = 1;
        r->mapped_textures = [NSMutableDictionary new];
        r->surfaces = [NSMutableDictionary new];
        r->planar = [NSMutableDictionary new];
        r->planar_uses = [NSMutableDictionary new];
        r->planar_hashes = [NSMutableDictionary new];
        r->complaints = [NSMutableSet new];
        r->shot = getenv("HV_PVG_SHOT");
        cp_start(r);
        [r openArchive];
#if !TARGET_OS_IPHONE
        if (getenv("HV_PVG_GPU_TEST")) r->layer = [CAMetalLayer layer];
#endif
#if !TARGET_OS_IPHONE
        if (r->shot) {
            double every = getenv("HV_PVG_SHOT_SECS") ? atof(getenv("HV_PVG_SHOT_SECS")) : 5;
            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, r->worker);
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(every * NSEC_PER_SEC)), (uint64_t)(every * NSEC_PER_SEC), NSEC_PER_SEC / 10);
            HvReplay *__weak weak = r;
            dispatch_source_set_event_handler(timer, ^{ [weak saveShot]; });
            dispatch_resume(timer);
            r->shot_timer = timer;
        }
#endif
        fprintf(stderr, "hengevm: pvg-metal: drawing on %s\n", dev.name.UTF8String);
        return (HvPvgMetal *)CFBridgingRetain(r);
    }
}

void hv_pvg_metal_destroy(HvPvgMetal *m) {
    if (!m) return;
    @autoreleasepool {
        HvReplay *r = CFBridgingRelease(m);
        atomic_store(&r->stopping, 1);
        if (r->shot_timer) { dispatch_source_cancel(r->shot_timer); r->shot_timer = nil; }
        if (cp.timer) { dispatch_source_cancel(cp.timer); cp.timer = nil; }
        os_unfair_lock_lock(&r->screen_lock);
        r->layer = nil;
        r->layer_generation++;
        r->screen_dirty = NO;
        os_unfair_lock_unlock(&r->screen_lock);
        /* No CPU can enqueue more work. Delayed presentation blocks see
           stopping before touching guest memory; already queued work drains. */
        dispatch_sync(r->worker, ^{ r->late = NO; });
        dispatch_sync(r->presenter, ^{});
        dispatch_sync(r->cursor_queue, ^{ /* later pointer updates see stopping and touch nothing of the guest's */
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [r->overlay_box removeFromSuperlayer];
            [CATransaction commit];
            [CATransaction flush];
            r->overlay_parent = nil;
        });
        id<MTLCommandBuffer> fence = [r->queue commandBuffer];
        [fence commit];
        [fence waitUntilCompleted];
        dispatch_group_wait(r->completions, DISPATCH_TIME_FOREVER);
        /* GPU completions may have enqueued a final readback on the worker. */
        dispatch_sync(r->worker, ^{
            [r saveArchive];
            r->lite = NULL;
            for (uint32_t t = 0; t < HV_TASKS; t++) obj_clear(&r->task_objs[t]);
            r->surfaces = nil;
            r->mapped_textures = nil;
            r->planar = nil;
            r->screen_tex = nil;
            r->cursor_tex = nil;
            r->last_cb = nil;
            r->readback = r->test_readback = nil;
            free(r->frame); r->frame = NULL;
            free(r->base); r->base = NULL;
            free(r->cursor); r->cursor = NULL;
            for (NSValue *old in r->retired_frames) free(old.pointerValue);
            r->retired_frames = nil;
            free(cp.pend_src); cp.pend_src = NULL;
            cp.on = 0;
        });
    }
}

void hv_pvg_metal_submit(HvPvgMetal *m, HvPvgLite *lite, uint32_t ch, uint32_t *cmd, uint32_t len) {
    HvReplay *r = (__bridge HvReplay *)m;
    dispatch_async(r->worker, ^{
        @autoreleasepool {
            new_command(r);
            uint32_t op = cmd[0] & 0xffff, skip = (cmd[0] >> 16) * 8; /* the barriers come first */
            const uint32_t *args = (const uint32_t *)((const uint8_t *)cmd + 12 + skip);
            uint32_t n = len > 12 + skip ? len - 12 - skip : 0;
            BOOL gpu_completes = NO;
            @try {
                if ((op == 0x43 || op == 0x45) && n >= 12) {
                    gpu_completes = [r exec:args length:n channel:ch stamp:cmd[2]];
                } else if (op == 0x37 && n >= 12) {
                    /* macOS 13's driver: the same work with 24-byte resource entries ({ref, flags} and four more words)
                       before the 16-byte buffers. Put it in 0x43's shape: {task, resources, buffers, {ref, flags}..., buffers...}. */
                    uint32_t nres = args[1], nbuf = args[2];
                    if (12 + nres * 24ull + nbuf * 16ull <= n && nres < 65536 && nbuf < 65536) {
                        uint32_t len43 = 12 + nres * 8 + nbuf * 16, *a43 = malloc(len43);
                        if (a43) {
                            a43[0] = args[0], a43[1] = nres, a43[2] = nbuf;
                            for (uint32_t i = 0; i < nres; i++) a43[3 + i * 2] = args[3 + i * 6], a43[4 + i * 2] = args[4 + i * 6];
                            memcpy(a43 + 3 + nres * 2, args + 3 + nres * 6, nbuf * 16ull);
                            gpu_completes = [r exec:a43 length:len43 channel:ch stamp:cmd[2]];
                            free(a43);
                        }
                    } else [r complain:[NSString stringWithFormat:@"command 0x37 of %u bytes: %u resources, %u buffers do not fit", n, nres, nbuf]];
                } else if ((op == 0x25 || op == 0x28) && n >= 8) { /* {task, ref} or {task, tag, size, ref} */
                    uint32_t ref = op == 0x25 ? args[1] : (n >= 16 ? args[3] : 0);
                    HvObject *__strong *slot = args[0] < HV_TASKS ? obj_slot(&r->task_objs[args[0]], ref, NO) : NULL;
                    if (slot) *slot = nil;
                } else if (op == 0x35 || op == 0x3e) {
                    [r synchronize:args length:n];
                } else if (op == 0x34) {
                    [r invalidate:args length:n];
                } else if (op == 0x3f) {
                    /* "May be thrown away": Apple's host only marks it purgeable, and the bytes stay
                       until the system needs the memory. Here they just stay. */
                } else if (op == 0x20 && n >= 4) {
                    /* Delete task: the id as every other command names it. Only define task (0x38) sends it shifted left with a
                       flag in bit 0 (Apple's host: -[PGFIFO CmdDeleteTask] passes p[0] to deleteTaskID: as it is). Shifted here,
                       an ended process kept its objects and the next one given its id got its functions wherever an object-list
                       entry read the same: a vertex function in a fragment slot, and the GPU driver died (issue 102). */
                    if (args[0] < HV_TASKS) obj_clear(&r->task_objs[args[0]]);
                } else {
                    hv_pvg_lite_command(lite, cmd, len);
                    if (op == 8 && n >= 16) {
                        uint64_t shown = (uint64_t)args[3] << 32 | args[2];
                        if (r->tracing) fprintf(stderr, "trace: swap to %llu\n", shown);
                        cp_note_swap(r, shown, args, n);
                        [r present:shown];
                    }
                    if (op == 4) [r cursorGlyph:args length:n];
                    if (op == 5 && n >= 8) {
                        os_unfair_lock_lock(&r->screen_lock);
                        r->cursor_shown = args[1] & 1;
                        os_unfair_lock_unlock(&r->screen_lock);
                        if (getenv("HV_PVG_CURSOR_LOG")) fprintf(stderr, "pvgcursor show %u\n", args[1]);
                        [r drawCursor];
                    }
                }
            } @catch (NSException *x) {
                [r complain:[NSString stringWithFormat:@"exception: %@", x.reason]];
            }
            if (!gpu_completes) [r finishChannel:ch stamp:cmd[2]];
            free(cmd);
        }
    });
}

void hv_pvg_metal_set_layer(HvPvgMetal *m, void *layer) {
    if (!m) return;
    HvReplay *r = (__bridge HvReplay *)m;
    CAMetalLayer *l = (__bridge CAMetalLayer *)layer;
    cursor_settings_now(); /* the app may have changed the brightness: it shows the screen again for that */
    // Invalidate immediately, even when the guest GPU worker has a backlog.
    os_unfair_lock_lock(&r->screen_lock);
    r->layer_generation++; /* reattaching the same layer also wakes a stopped presenter */
    r->layer = l;
    r->drawable_retry_pending = NO;
    r->drawable_retry_deadline = r->drawable_retry_cooldown = 0;
    r->screen_dirty = YES;
    [r targetChanged];
    [r kickPresenter:YES];
    os_unfair_lock_unlock(&r->screen_lock);
    dispatch_async(r->worker, ^{
        if (r->on_screen) [r present:r->on_screen];
    });
}

uint64_t hv_pvg_metal_gpu_frames(HvPvgMetal *m) {
    return m ? ((__bridge HvReplay *)m)->gpu_frames : 0;
}

void hv_pvg_metal_cursor_moved(HvPvgMetal *m) {
    if (!m) return;
    HvReplay *r = (__bridge HvReplay *)m;
    if ([r hasDisplayLayer]) { /* no need to queue behind the guest's GPU work */
        [r cursorChanged];
        return;
    }
    static _Atomic int queued;
    if (atomic_exchange(&queued, 1)) return; /* one is already on its way, and it will read the newest position */
    dispatch_async(r->worker, ^{
        atomic_store(&queued, 0);
        [r drawCursor];
    });
}

void hv_pvg_metal_unmap(HvPvgMetal *m, uint32_t mapping) {
    HvReplay *r = (__bridge HvReplay *)m;
    dispatch_async(r->worker, ^{
        /* The last mapping of a shared multi-plane surface takes its table entry along: the entry holds the host
           IOSurface (4K video frames are 27-65 MB of Henge's own memory), and the guest reuses its memory for others. */
        HvObject *s = r->surfaces[@(mapping)];
        NSString *pk = s ? s->planar_key : nil;
        if (pk) {
            s->planar_key = nil;
            if ((__bridge IOSurfaceRef)r->planar[pk] == s->iosurface) { /* still this one's entry (the table may have been emptied since) */
                unsigned uses = r->planar_uses[pk].unsignedIntValue;
                if (uses > 1) r->planar_uses[pk] = @(uses - 1);
                else {
                    [r->planar removeObjectForKey:pk];
                    [r->planar_uses removeObjectForKey:pk];
                    [r->planar_hashes removeObjectForKey:pk];
                }
            }
        }
        [r->surfaces removeObjectForKey:@(mapping)];
        [r->mapped_textures removeObjectForKey:@(mapping)];
    });
}

void hv_pvg_metal_after_gpu(HvPvgMetal *m, HvPvgLite *lite, uint64_t index) {
    HvReplay *r = (__bridge HvReplay *)m;
    dispatch_group_enter(r->completions); /* so a quiesce waits for it too */
    dispatch_async(r->worker, ^{
        /* Everything before this on the worker has been encoded and committed by now; the queue's command buffers
           finish in order, so this empty one finishes after all of them. */
        @autoreleasepool {
            id<MTLCommandBuffer> cb = r->queue ? [r->queue commandBuffer] : nil;
            if (!cb) { /* no GPU work can be under way */
                hv_pvg_lite_mapper_done(lite, index);
                dispatch_group_leave(r->completions);
                return;
            }
            [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                (void)done;
                hv_pvg_lite_mapper_done(lite, index);
                dispatch_group_leave(r->completions);
            }];
            [cb commit];
            r->last_cb = cb;
        }
    });
}

/* A small picture of what the display shows, BGRA with no padding, for the app's home screen.
   Read straight from the surface's memory, nearest pixel: it may catch a frame being drawn, which
   does not matter at this size. -1 before anything has been shown. */
int hv_pvg_metal_snapshot(HvPvgMetal *m, uint8_t *bgra, uint32_t w, uint32_t h) {
    if (!m || !w || !h) return -1;
    HvReplay *r = (__bridge HvReplay *)m;
    os_unfair_lock_lock(&r->screen_lock);
    id<MTLTexture> tex = r->screen_tex;
    BOOL half = r->screen_half;
    uint32_t W = r->screen_w, H = r->screen_h;
    os_unfair_lock_unlock(&r->screen_lock);
    id<MTLBuffer> buffer = tex.buffer;
    if (!buffer || !W || !H || buffer.storageMode == MTLStorageModePrivate) return -1;
    const uint8_t *base = (const uint8_t *)buffer.contents + tex.bufferOffset;
    size_t row = tex.bufferBytesPerRow;
    /* Four samples to a pixel: one makes text look broken at this size. */
    for (uint32_t y = 0; y < h; y++) {
        uint8_t *out = bgra + (size_t)y * w * 4;
        for (uint32_t x = 0; x < w; x++, out += 4) {
            uint32_t sum[3] = {0, 0, 0};
            for (uint32_t k = 0; k < 4; k++) {
                size_t sx = (2 * x + (k & 1)) * (uint64_t)W / (2 * w), sy = (2 * y + (k >> 1)) * (uint64_t)H / (2 * h);
                const uint8_t *src = base + sy * row;
                if (!half) {
                    for (int c = 0; c < 3; c++) sum[c] += src[sx * 4 + c];
                    continue;
                }
                const __fp16 *p = (const __fp16 *)(src + sx * 8);
                for (int c = 0; c < 3; c++) {
                    float v = hv_half_shown((float)p[c], hv_half_mode_get()); /* as the screen shows it */
                    sum[2 - c] += (uint32_t)(v * 255 + 0.5f);
                }
            }
            for (int c = 0; c < 3; c++) out[c] = (uint8_t)((sum[c] + 2) / 4);
            out[3] = 255;
        }
    }
    return 0;
}

int hv_pvg_metal_frame(HvPvgMetal *m, const uint8_t **pixels, uint32_t *w, uint32_t *h) {
    if (!m) return -1;
    HvReplay *r = (__bridge HvReplay *)m;
    if (!r->frame) return -1;
    *pixels = r->frame, *w = r->frame_w, *h = r->frame_h;
    return 0;
}

@interface HvReplay (Resume)
- (void)page:(HvObject *)o toGuest:(BOOL)down task:(uint32_t)task blit:(id<MTLBlitCommandEncoder> *)blit commandBuffer:(id<MTLCommandBuffer>)cb;
@end

/* Instant resume: the CPUs are stopped. Finish what the guest handed over, then copy what only the GPU holds (it drew
   into private memory and the guest has not asked for it back) into guest memory, where a replay made after a restore
   reads it from. A texture in a heap goes with its heap's bytes, as the heap is what is made again from guest memory. */
void hv_pvg_metal_quiesce(HvPvgMetal *m) {
    if (!m) return;
    HvReplay *r = (__bridge HvReplay *)m;
    @autoreleasepool {
        dispatch_sync(r->worker, ^{});
        dispatch_group_wait(r->completions, DISPATCH_TIME_FOREVER);
        dispatch_sync(r->worker, ^{
            [r saveArchive]; /* a suspended app may not come back */
            id<MTLCommandBuffer> cb = nil;
            id<MTLBlitCommandEncoder> blit = nil;
            unsigned copied = 0;
            new_command(r);
            for (uint32_t task = 0; task < HV_TASKS; task++) {
                HvTaskObjects *objs = &r->task_objs[task];
                for (uint32_t p = 0; p < objs->pages; p++)
                    for (uint32_t i = 0; objs->page[p] && i < OBJ_PAGE; i++) {
                        HvObject *o = objs->page[p][i];
                        if (!o || !o->guest_backed || !o->host_valid || !o->guest_stale) continue;
                        if (o->parent && o->parent->heap_whole) continue;
                        if (!cb) cb = [r->queue commandBuffer];
                        [r page:o toGuest:YES task:task blit:&blit commandBuffer:cb];
                        o->guest_stale = NO;
                        copied++;
                    }
            }
            [blit endEncoding];
            if (cb) {
                [cb commit];
                [cb waitUntilCompleted];
            }
            fprintf(stderr, "hengevm: pvg-metal: quiesced, %u GPU-only objects copied to guest memory\n", copied);
        });
        dispatch_group_wait(r->completions, DISPATCH_TIME_FOREVER);
    }
}

typedef struct DisplayState {
    uint64_t on_screen;
    uint32_t cursor_w, cursor_h, cursor_stride, cursor_shown;
    int32_t hot_x, hot_y;
} DisplayState;

size_t hv_pvg_metal_display_state(HvPvgMetal *m, void *out, size_t cap) {
    HvReplay *r = (__bridge HvReplay *)m;
    __block size_t need = 0;
    dispatch_sync(r->worker, ^{
        os_unfair_lock_lock(&r->screen_lock);
        size_t bits = r->cursor ? (size_t)r->cursor_stride * r->cursor_h : 0;
        need = sizeof(DisplayState) + bits;
        if (out && cap >= need) {
            DisplayState d = {.on_screen = r->on_screen, .cursor_w = bits ? r->cursor_w : 0, .cursor_h = bits ? r->cursor_h : 0,
                              .cursor_stride = bits ? r->cursor_stride : 0, .cursor_shown = r->cursor_shown,
                              .hot_x = r->cursor_hot_x, .hot_y = r->cursor_hot_y};
            memcpy(out, &d, sizeof d);
            if (bits) memcpy((uint8_t *)out + sizeof d, r->cursor, bits);
        }
        os_unfair_lock_unlock(&r->screen_lock);
    });
    return need;
}

void hv_pvg_metal_set_display_state(HvPvgMetal *m, const void *in, size_t len) {
    if (!m || len < sizeof(DisplayState)) return;
    HvReplay *r = (__bridge HvReplay *)m;
    DisplayState d;
    memcpy(&d, in, sizeof d);
    size_t bits = (size_t)d.cursor_stride * d.cursor_h;
    if (len < sizeof d + bits || d.cursor_w > 512 || d.cursor_h > 512 || (bits && d.cursor_stride < d.cursor_w * 4)) bits = 0;
    uint8_t *copy = bits ? malloc(bits) : NULL;
    if (copy) memcpy(copy, (const uint8_t *)in + sizeof d, bits);
    dispatch_sync(r->worker, ^{
        @autoreleasepool {
            id<MTLTexture> glyph = nil;
            if (copy) {
                MTLTextureDescriptor *ct = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                              width:d.cursor_w height:d.cursor_h mipmapped:NO];
                ct.storageMode = MTLStorageModeShared;
                glyph = [r->device newTextureWithDescriptor:ct];
                [glyph replaceRegion:MTLRegionMake2D(0, 0, d.cursor_w, d.cursor_h) mipmapLevel:0 withBytes:copy bytesPerRow:d.cursor_stride];
            }
            os_unfair_lock_lock(&r->screen_lock);
            if (copy) {
                free(r->cursor);
                r->cursor = copy, r->cursor_w = d.cursor_w, r->cursor_h = d.cursor_h, r->cursor_stride = d.cursor_stride;
                r->cursor_hot_x = d.hot_x, r->cursor_hot_y = d.hot_y;
                r->cursor_tex = glyph;
                r->cursor_seq++;
            }
            r->cursor_shown = d.cursor_shown != 0;
            os_unfair_lock_unlock(&r->screen_lock);
            r->on_screen = d.on_screen;
            if (d.on_screen) [r present:d.on_screen];
            [r drawCursor];
        }
    });
    fprintf(stderr, "hengevm: pvg-metal: screen %llu and a %ux%u pointer restored\n", (unsigned long long)d.on_screen, d.cursor_w, d.cursor_h);
}
