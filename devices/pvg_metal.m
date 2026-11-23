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

/* A record's bytes, as a pointer into the buffer's private copy. */
typedef struct {
    const uint8_t *p;
    uint32_t size;
} Rec;

#define U32(off) (*(const uint32_t *)(r.p + (off)))
#define U16(off) (*(const uint16_t *)(r.p + (off)))
#define U64(off) ({ uint64_t _v; memcpy(&_v, r.p + (off), 8); _v; })

- (id<MTLRenderCommandEncoder>)beginPass:(Rec)r task:(uint32_t)task commandBuffer:(id<MTLCommandBuffer>)cb {
    MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
#define ATTACH(a, o)                                                 \
    do {                                                             \
        a.texture = [self get:U32((o)) task:task];                   \
        a.resolveTexture = [self get:U32((o) + 4) task:task];        \
        a.level = U16((o) + 8), a.slice = U16((o) + 10);             \
        a.depthPlane = U16((o) + 12), a.resolveLevel = U16((o) + 14); \
        a.resolveSlice = U16((o) + 16), a.resolveDepthPlane = U16((o) + 18); \
        a.loadAction = (MTLLoadAction)U16((o) + 20);                 \
        a.storeAction = (MTLStoreAction)U16((o) + 22);               \
        a.storeActionOptions = U16((o) + 24);                        \
    } while (0)
    ATTACH(d.depthAttachment, 0);
    double clear_depth;
    memcpy(&clear_depth, r.p + 0x1c, 8);
    d.depthAttachment.clearDepth = clear_depth;
    ATTACH(d.stencilAttachment, 0x28);
    d.stencilAttachment.clearStencil = U32(0x44);
    for (int i = 0; i < 8; i++) {
        uint32_t o = 0x4c + (uint32_t)i * 0x3c;
        if (o + 0x3c > r.size) break;
        MTLRenderPassColorAttachmentDescriptor *c = d.colorAttachments[i];
        ATTACH(c, o);
        double col[4];
        memcpy(col, r.p + o + 0x1c, sizeof col);
        c.clearColor = MTLClearColorMake(col[0], col[1], col[2], col[3]);
    }
    /* Memoryless and resolve store actions want the matching textures; a pass with none stays dontCare. */
    for (int i = 0; i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *c = d.colorAttachments[i];
        if (!c.texture) c.storeAction = MTLStoreActionDontCare, c.loadAction = MTLLoadActionDontCare;
        else if (!c.resolveTexture && (c.storeAction == MTLStoreActionMultisampleResolve || c.storeAction == MTLStoreActionStoreAndMultisampleResolve))
            c.storeAction = MTLStoreActionStore;
    }
    if (!d.depthAttachment.texture) d.depthAttachment.loadAction = MTLLoadActionDontCare, d.depthAttachment.storeAction = MTLStoreActionDontCare;
    if (!d.stencilAttachment.texture) d.stencilAttachment.loadAction = MTLLoadActionDontCare, d.stencilAttachment.storeAction = MTLStoreActionDontCare;
    /* After the attachments: the visibility buffer and the render target's size. */
    if (r.size >= 0x248) {
        if (U32(0x22c)) d.visibilityResultBuffer = [self get:U32(0x22c) task:task];
        uint64_t layers = U64(0x230), rw = U64(0x238), rh = U64(0x240);
        if (layers) d.renderTargetArrayLength = (NSUInteger)layers;
        if (rw) d.renderTargetWidth = (NSUInteger)rw;
        if (rh) d.renderTargetHeight = (NSUInteger)rh;
    }
    /* What came before the pass itself. */
    if (pre_raster_samples) d.defaultRasterSampleCount = pre_raster_samples;
    if (pre_imageblock) d.imageblockSampleLength = pre_imageblock;
    if (pre_threadgroup) d.threadgroupMemoryLength = pre_threadgroup;
    if (pre_tile_w) d.tileWidth = pre_tile_w, d.tileHeight = pre_tile_h;
    {   /* HV_PVG_PASSDUMP=N: the first N render pass records, raw and as read (for a guest driver whose layout differs) */
        static int left = -1;
        if (left < 0) left = getenv("HV_PVG_PASSDUMP") ? atoi(getenv("HV_PVG_PASSDUMP")) : 0;
        if (left > 0) {
            left--;
            fprintf(stderr, "passdump: size 0x%x samples %lu imageblock %lu threadgroup %lu tile %lux%lu layers %lu rt %lux%lu\n", r.size,
                    (unsigned long)d.defaultRasterSampleCount, (unsigned long)d.imageblockSampleLength, (unsigned long)d.threadgroupMemoryLength,
                    (unsigned long)d.tileWidth, (unsigned long)d.tileHeight, (unsigned long)d.renderTargetArrayLength,
                    (unsigned long)d.renderTargetWidth, (unsigned long)d.renderTargetHeight);
            for (int i = -2; i < 8; i++) {
                MTLRenderPassAttachmentDescriptor *a = i == -2 ? (MTLRenderPassAttachmentDescriptor *)d.depthAttachment
                                                      : i == -1 ? (MTLRenderPassAttachmentDescriptor *)d.stencilAttachment : d.colorAttachments[i];
                if (!a.texture) continue;
                fprintf(stderr, "passdump:   %s%d tex %lux%lu fmt %lu samples %lu type %lu usage %lu storage %lu level %lu slice %lu load %lu store %lu opts %lu resolve %s\n",
                        i == -2 ? "depth" : i == -1 ? "stencil" : "c", i < 0 ? 0 : i, (unsigned long)a.texture.width, (unsigned long)a.texture.height,
                        (unsigned long)a.texture.pixelFormat, (unsigned long)a.texture.sampleCount, (unsigned long)a.texture.textureType,
                        (unsigned long)a.texture.usage, (unsigned long)a.texture.storageMode, (unsigned long)a.level, (unsigned long)a.slice,
                        (unsigned long)a.loadAction, (unsigned long)a.storeAction, (unsigned long)a.storeActionOptions, a.resolveTexture ? "yes" : "no");
            }
            for (int i = -2; i < 8; i++) { /* a named attachment Henge has no texture for: its object table entry */
                uint32_t o = i == -2 ? 0 : i == -1 ? 0x28 : 0x4c + (uint32_t)i * 0x3c, ref = o + 4 <= r.size ? U32(o) : 0;
                if (!ref || [self get:ref task:task]) continue;
                uint64_t list = hv_pvg_lite_task_objects(lite, task);
                uint32_t e[3] = {0}, w[24] = {0};
                if (list) hv_pvg_lite_task_read(lite, task, list + (uint64_t)ref * 12, e, 12);
                uint64_t at = (uint64_t)e[2] << 32 | e[1];
                if (at) hv_pvg_lite_task_read(lite, task, at, w, sizeof w);
                fprintf(stderr, "passdump:   missing ref %u (slot %d): type %u size %u at 0x%llx:", ref, i, e[0] & 0xff, e[0] >> 8, (unsigned long long)at);
                for (int k = 0; k < 24; k++) fprintf(stderr, " %08x", w[k]);
                fprintf(stderr, "\n");
            }
            for (uint32_t o = 0; o < r.size && o < 0x260; o += 32) {
                fprintf(stderr, "passdump:   %03x:", o);
                for (uint32_t k = o; k < o + 32 && k < r.size; k += 4) fprintf(stderr, " %08x", U32(k));
                fprintf(stderr, "\n");
            }
        }
    }
    pre_raster_samples = pre_imageblock = pre_threadgroup = pre_tile_w = pre_tile_h = 0;
    /* An attachment the guest names but Henge never made (a texture from a record it doesn't know) leaves a pass with
       no attachments; with a render size and no sample count, the GPU driver aborts the whole app building it. Skip it. */
    int named = 0, made = 0;
    for (int i = -2; i < 8; i++) {
        uint32_t o = i == -2 ? 0 : i == -1 ? 0x28 : 0x4c + (uint32_t)i * 0x3c;
        if (o + 4 > r.size || !U32(o)) continue;
        named++;
        made += (i == -2 ? d.depthAttachment.texture : i == -1 ? d.stencilAttachment.texture : d.colorAttachments[i].texture) != nil;
    }
    if (named && made < named) {
        static int told;
        if (told++ < 20) fprintf(stderr, "hengevm: pvg-metal: pass skipped: %d of its %d attachments were never made\n", named - made, named);
        return nil;
    }
    if (!named && !d.defaultRasterSampleCount) d.defaultRasterSampleCount = 1;
    if (tracing) {
        id<MTLTexture> c0 = d.colorAttachments[0].texture;
        MTLClearColor cc = d.colorAttachments[0].clearColor;
        HvObject *co = [self object:U32(0x4c) task:task];
        fprintf(stderr, "trace: pass c0 ref %u %lux%lu fmt %lu load %lu store %lu clear %.2f %.2f %.2f %.2f surface %s heap %d\n", U32(0x4c), (unsigned long)c0.width, (unsigned long)c0.height, (unsigned long)c0.pixelFormat, (unsigned long)d.colorAttachments[0].loadAction, (unsigned long)d.colorAttachments[0].storeAction, cc.red, cc.green, cc.blue, cc.alpha, co && co->surface ? "yes" : "no", c0.heap != nil);
    }
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:d];
    if (!e) {
        NSMutableString *m = [NSMutableString stringWithString:@"no render encoder:"];
        for (int i = 0; i < 8; i++) {
            MTLRenderPassColorAttachmentDescriptor *c = d.colorAttachments[i];
            uint32_t ref = U32(0x4c + (uint32_t)i * 0x3c);
            if (ref) [m appendFormat:@" c%d ref %u %s %lux%lu fmt %lu load %lu store %lu usage %lu", i, ref, c.texture ? "ok" : "MISSING", (unsigned long)c.texture.width, (unsigned long)c.texture.height, (unsigned long)c.texture.pixelFormat, (unsigned long)c.loadAction, (unsigned long)c.storeAction, (unsigned long)c.texture.usage];
        }
        [m appendFormat:@" depth ref %u stencil ref %u", U32(0), U32(0x28)];
        [self complain:m];
    }
    return e;
}

/* One serialized call. Tags are the guest's. */
- (void)useHeaps:(const uint32_t *)refs count:(uint32_t)n task:(uint32_t)task encoder:(id)e stages:(int)stages {
    id<MTLHeap> __unsafe_unretained list[64];
    NSMutableArray *keep = [NSMutableArray new];
    uint32_t have = 0;
    for (uint32_t i = 0; i < n && have < 64; i++) {
        id heap = [self get:refs[i] task:task];
        if (!heap) continue;
        [keep addObject:heap];
        list[have++] = heap;
    }
    if (!have) return;
    if (stages >= 0) [(id<MTLRenderCommandEncoder>)e useHeaps:list count:have stages:(MTLRenderStages)stages];
    else if ([e conformsToProtocol:@protocol(MTLRenderCommandEncoder)]) [(id<MTLRenderCommandEncoder>)e useHeaps:list count:have];
    else [(id<MTLComputeCommandEncoder>)e useHeaps:list count:have];
}

- (void)render:(id<MTLRenderCommandEncoder>)e tag:(uint32_t)tag rec:(Rec)r task:(uint32_t)task {
    BOOL draw = tag <= 19 || tag == 28 || tag == 29 || tag == 155 || tag == 162;
    if (!pipeline_set && draw) return;
    if (tracing && draw) fprintf(stderr, "trace:  draw tag %u\n", tag);
    switch (tag) {
    case 24: { /* {fence, stages} */
        id f = [self get:U32(0) task:task];
        if (f) [e updateFence:f afterStages:(MTLRenderStages)(U32(4) & 0xffff)];
        break;
    }
    case 25: {
        id f = [self get:U32(0) task:task];
        if (f) [e waitForFence:f beforeStages:(MTLRenderStages)(U32(4) & 0xffff)];
        break;
    }
    case 27: /* {count, stages}, the heaps */
        if (r.size >= 8 + U32(0) * 4ull) [self useHeaps:(const uint32_t *)(r.p + 8) count:U32(0) task:task encoder:e stages:U32(4) & 0xffff];
        break;
    case 134: /* {count}, the heaps */
        if (r.size >= 4 + U32(0) * 4ull) [self useHeaps:(const uint32_t *)(r.p + 4) count:U32(0) task:task encoder:e stages:-1];
        break;
    case 116: { /* Metal crashes on a missing pipeline, and on drawing without one */
        id state = [self get:U32(0) task:task];
        if (state) [e setRenderPipelineState:state];
        pipeline_set = state != nil;
        if (tracing) fprintf(stderr, "trace:  pipeline %u %s\n", U32(0), [objc_getAssociatedObject(state, "hvname") UTF8String]);
        break;
    }
    case 125: case 110: case 157: { /* vertex, fragment, tile buffers: {index, count}, {ref, offset}... */
        uint32_t index = U32(0), count = U32(4);
        if (count > 31) break;
        __unsafe_unretained id<MTLBuffer> buffers[31];
        id strong[31];
        NSUInteger offsets[31];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 12) task:task];
            buffers[i] = strong[i];
            offsets[i] = (NSUInteger)U64(12 + i * 12);
        }
        NSRange range = NSMakeRange(index, count);
        if (tracing) for (uint32_t i = 0; i < count; i++) { /* m4 fork: what the shaders are given */
            id<MTLBuffer> bb = strong[i];
            fprintf(stderr, "trace:  %s buf %u ref %u off %lu len %lu:", tag == 125 ? "vtx" : tag == 110 ? "frag" : "tile", index + i, U32(8 + i * 12),
                    (unsigned long)offsets[i], (unsigned long)bb.length);
            if (bb && bb.storageMode != MTLStorageModePrivate && offsets[i] < bb.length) {
                const float *f = (const float *)((const uint8_t *)bb.contents + offsets[i]);
                NSUInteger nf = MIN((bb.length - offsets[i]) / 4, (NSUInteger)96);
                for (NSUInteger k = 0; k < nf; k++) fprintf(stderr, " %g", f[k]);
            }
            fprintf(stderr, "\n");
        }
        if (tag == 125) [e setVertexBuffers:buffers offsets:offsets withRange:range];
        else if (tag == 110) [e setFragmentBuffers:buffers offsets:offsets withRange:range];
        else [e setTileBuffers:buffers offsets:offsets withRange:range];
        break;
    }
    case 126: [e setVertexBufferOffset:(NSUInteger)U64(4) atIndex:U32(0)]; break;
    case 111: [e setFragmentBufferOffset:(NSUInteger)U64(4) atIndex:U32(0)]; break;
    case 114: case 161: { /* fragment, tile textures */
        uint32_t index = U32(0), count = U32(4);
        if (count > 128) break;
        __unsafe_unretained id<MTLTexture> items[128];
        id strong[128];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
        }
        if (tracing) for (uint32_t i = 0; i < count; i++) {
            id<MTLTexture> x = strong[i];
            HvObject *xo = [self object:U32(8 + i * 4) task:task];
            fprintf(stderr, "trace:  tex %u ref %u %lux%lu fmt %lu type %u swz %d%d%d%d surface %s heap %d valid %d\n", index + i, U32(8 + i * 4), (unsigned long)x.width, (unsigned long)x.height, (unsigned long)x.pixelFormat, xo ? xo->entry[0] & 0xff : 0, x.swizzle.red, x.swizzle.green, x.swizzle.blue, x.swizzle.alpha, xo && xo->surface ? "yes" : "no", x.heap != nil, xo ? xo->host_valid : 0);
        }
        if (tag == 114) [e setFragmentTextures:items withRange:NSMakeRange(index, count)];
        else [e setTileTextures:items withRange:NSMakeRange(index, count)];
        break;
    }
    case 112: { /* fragment samplers */
        uint32_t index = U32(0), count = U32(4);
        if (count > 16) break;
        __unsafe_unretained id<MTLSamplerState> items[16];
        id strong[16];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
        }
        [e setFragmentSamplerStates:items withRange:NSMakeRange(index, count)];
        break;
    }
    case 117: {
        MTLScissorRect s;
        memcpy(&s, r.p, sizeof s);
        [e setScissorRect:s];
        if (tracing) fprintf(stderr, "trace:  scissor %lu %lu %lu %lu\n", (unsigned long)s.x, (unsigned long)s.y, (unsigned long)s.width, (unsigned long)s.height);
        break;
    }
    case 130: {
        MTLViewport v;
        memcpy(&v, r.p, sizeof v);
        [e setViewport:v];
        break;
    }
    case 122: { /* {ref, offset, stride} */
        id<MTLBuffer> b = [self get:U32(0) task:task];
        [e setTessellationFactorBuffer:b offset:(NSUInteger)U64(4) instanceStride:(NSUInteger)U64(12)];
        tess_factors = b != nil;
        break;
    }
    case 123: {
        float f;
        memcpy(&f, r.p, 4);
        [e setTessellationFactorScale:f];
        break;
    }
    case 104: {
        id state = [self get:U32(0) task:task];
        [e setDepthStencilState:state];
        break;
    }
    case 107: [e setCullMode:(MTLCullMode)U32(0)]; break;
    case 108: {
        float f[3];
        memcpy(f, r.p, sizeof f);
        [e setDepthBias:f[0] slopeScale:f[1] clamp:f[2]];
        break;
    }
    case 109: [e setDepthClipMode:(MTLDepthClipMode)U32(0)]; break;
    case 115: [e setFrontFacingWinding:(MTLWinding)U32(0)]; break;
    case 124: [e setTriangleFillMode:(MTLTriangleFillMode)U32(0)]; break;
    case 119: [e setStencilFrontReferenceValue:U32(0) backReferenceValue:U32(4)]; break;
    case 118: { /* a header, then the rectangles */
        uint32_t head = r.size % sizeof(MTLScissorRect), n = (r.size - head) / sizeof(MTLScissorRect);
        if (n) [e setScissorRects:(const MTLScissorRect *)(r.p + head) count:n];
        break;
    }
    case 131: {
        uint32_t head = r.size % sizeof(MTLViewport), n = (r.size - head) / sizeof(MTLViewport);
        if (n) [e setViewports:(const MTLViewport *)(r.p + head) count:n];
        break;
    }
    case 129: { /* vertex textures: {index, count}, refs */
        uint32_t index = U32(0), count = U32(4);
        if (count > 128) break;
        __unsafe_unretained id<MTLTexture> items[128];
        id strong[128];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
        }
        [e setVertexTextures:items withRange:NSMakeRange(index, count)];
        break;
    }
    case 127: { /* vertex samplers */
        uint32_t index = U32(0), count = U32(4);
        if (count > 16) break;
        __unsafe_unretained id<MTLSamplerState> items[16];
        id strong[16];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
        }
        [e setVertexSamplerStates:items withRange:NSMakeRange(index, count)];
        break;
    }
    case 113: case 128: { /* samplers with LOD clamps: {index, count}, refs, minimums, maximums */
        uint32_t index = U32(0), count = U32(4);
        if (count > 16 || r.size < 8 + count * 12ull) break;
        __unsafe_unretained id<MTLSamplerState> items[16];
        id strong[16];
        float lo[16], hi[16];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
            memcpy(&lo[i], r.p + 8 + count * 4 + i * 4, 4);
            memcpy(&hi[i], r.p + 8 + count * 8 + i * 4, 4);
        }
        if (tag == 113) [e setFragmentSamplerStates:items lodMinClamps:lo lodMaxClamps:hi withRange:NSMakeRange(index, count)];
        else [e setVertexSamplerStates:items lodMinClamps:lo lodMaxClamps:hi withRange:NSMakeRange(index, count)];
        break;
    }
    case 135: case 137: { /* {count, usage}, or {count, usage 16, stages 16}, then the resources */
        uint32_t count = U32(0);
        if (count > 256 || r.size < 8 + count * 4ull) break;
        __unsafe_unretained id<MTLResource> items[256];
        NSMutableArray *keep = [NSMutableArray new];
        uint32_t have = 0;
        for (uint32_t i = 0; i < count; i++) {
            id x = [self get:U32(8 + i * 4) task:task];
            if (!x || [x conformsToProtocol:@protocol(MTLHeap)]) continue;
            [keep addObject:x];
            items[have++] = x;
        }
        if (!have) break;
        if (tag == 135) [e useResources:items count:have usage:(MTLResourceUsage)U32(4)];
        else [e useResources:items count:have usage:(MTLResourceUsage)U16(4) stages:(MTLRenderStages)U16(6)];
        break;
    }
    case 165: { /* vertex buffers with stride: {index, count}, {ref, offset, stride}... */
        uint32_t index = U32(0), count = U32(4);
        if (count > 31 || r.size < 8 + count * 20ull) break;
        __unsafe_unretained id<MTLBuffer> buffers[31];
        id strong[31];
        NSUInteger offsets[31], strides[31];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 20) task:task];
            buffers[i] = strong[i];
            offsets[i] = (NSUInteger)U64(12 + i * 20);
            strides[i] = (NSUInteger)U64(20 + i * 20);
        }
        [e setVertexBuffers:buffers offsets:offsets attributeStrides:strides withRange:NSMakeRange(index, count)];
        break;
    }
    case 166: [e setVertexBufferOffset:(NSUInteger)U64(4) attributeStride:(NSUInteger)U64(12) atIndex:U32(0)]; break;
    case 101: {
        float c[4];
        memcpy(c, r.p, sizeof c);
        [e setBlendColorRed:c[0] green:c[1] blue:c[2] alpha:c[3]];
        break;
    }
    case 13: { /* {start 16, count 16, index ref, offset 16, instances 16, base instance 16, control points 16} */
        if (!tess_factors) break; /* Metal crashes without a factor buffer */
        id<MTLBuffer> b = [self get:U32(4) task:task];
        [e drawPatches:U16(14) patchStart:U16(0) patchCount:U16(2) patchIndexBuffer:b patchIndexBufferOffset:U16(8) instanceCount:U16(10) baseInstance:U16(12)];
        draws++;
        break;
    }
    case 12: { /* {start 64, count 64, index ref, offset 64, instances 64, base instance 64, control points 16} */
        if (!tess_factors) break;
        id<MTLBuffer> b = [self get:U32(16) task:task];
        [e drawPatches:U16(44) patchStart:(NSUInteger)U64(0) patchCount:(NSUInteger)U64(8) patchIndexBuffer:b patchIndexBufferOffset:(NSUInteger)U64(20)
         instanceCount:(NSUInteger)U64(28) baseInstance:(NSUInteger)U64(36)];
        draws++;
        break;
    }
    case 14: { /* {start 64, count 64, patch index ref, offset 64, control point index ref, offset 64, instances 64, base instance 64, control points 16} */
        if (!tess_factors) break;
        id<MTLBuffer> patches = [self get:U32(16) task:task], points = [self get:U32(28) task:task];
        if (points) [e drawIndexedPatches:U16(56) patchStart:(NSUInteger)U64(0) patchCount:(NSUInteger)U64(8) patchIndexBuffer:patches patchIndexBufferOffset:(NSUInteger)U64(20)
                  controlPointIndexBuffer:points controlPointIndexBufferOffset:(NSUInteger)U64(32) instanceCount:(NSUInteger)U64(40) baseInstance:(NSUInteger)U64(48)];
        draws++;
        break;
    }
    case 15: { /* {start 16, count 16, patch index ref, offset 16, control point index ref, offset 16, instances 16, base instance 16, control points 16} */
        if (!tess_factors) break;
        id<MTLBuffer> patches = [self get:U32(4) task:task], points = [self get:U32(10) task:task];
        if (points) [e drawIndexedPatches:U16(20) patchStart:U16(0) patchCount:U16(2) patchIndexBuffer:patches patchIndexBufferOffset:U16(8)
                  controlPointIndexBuffer:points controlPointIndexBufferOffset:U16(14) instanceCount:U16(16) baseInstance:U16(18)];
        draws++;
        break;
    }
    case 18: { /* {patch index ref, indirect ref, patch index offset 64, indirect offset 64, control points 16} */
        if (!tess_factors) break;
        id<MTLBuffer> patches = [self get:U32(0) task:task], indirect = [self get:U32(4) task:task];
        if (indirect) [e drawPatches:U16(24) patchIndexBuffer:patches patchIndexBufferOffset:(NSUInteger)U64(8) indirectBuffer:indirect indirectBufferOffset:(NSUInteger)U64(16)];
        draws++;
        break;
    }
    case 19: { /* {patch index ref, control point index ref, indirect ref, then their three offsets, 64, and control points 16} */
        if (!tess_factors) break;
        id<MTLBuffer> patches = [self get:U32(0) task:task], points = [self get:U32(4) task:task], indirect = [self get:U32(8) task:task];
        if (points && indirect) [e drawIndexedPatches:U16(36) patchIndexBuffer:patches patchIndexBufferOffset:(NSUInteger)U64(12) controlPointIndexBuffer:points
                                controlPointIndexBufferOffset:(NSUInteger)U64(20) indirectBuffer:indirect indirectBufferOffset:(NSUInteger)U64(28)];
        draws++;
        break;
    }
    case 1: /* {primitive, start 16, count 16} */
        [e drawPrimitives:(MTLPrimitiveType)U32(0) vertexStart:U16(4) vertexCount:U16(6)];
        draws++;
        break;
    case 3: /* {start, count, instances, primitive} */
        [e drawPrimitives:(MTLPrimitiveType)U16(6) vertexStart:U16(0) vertexCount:U16(2) instanceCount:U16(4)];
        draws++;
        break;
    case 7: { /* {primitive, index type, ref, count, offset} */
        id<MTLBuffer> b = [self get:U32(4) task:task];
        if (b) [e drawIndexedPrimitives:(MTLPrimitiveType)U16(0) indexCount:U16(8) indexType:(MTLIndexType)U16(2) indexBuffer:b indexBufferOffset:U16(10)];
        draws++;
        break;
    }
    case 6: {
        id<MTLBuffer> b = [self get:U32(4) task:task];
        if (b) [e drawIndexedPrimitives:(MTLPrimitiveType)U16(0) indexCount:(NSUInteger)U64(8) indexType:(MTLIndexType)U16(2) indexBuffer:b indexBufferOffset:(NSUInteger)U64(16)];
        draws++;
        break;
    }
    case 9: { /* {primitive, index type, ref, count 16, offset 16, instances 16} */
        id<MTLBuffer> b = [self get:U32(4) task:task];
        if (b) [e drawIndexedPrimitives:(MTLPrimitiveType)U16(0) indexCount:U16(8) indexType:(MTLIndexType)U16(2) indexBuffer:b indexBufferOffset:U16(10) instanceCount:U16(12)];
        draws++;
        break;
    }
    case 8: { /* {primitive, index type, ref, count 64, offset 64, instances 64} */
        id<MTLBuffer> b = [self get:U32(4) task:task];
        if (b) [e drawIndexedPrimitives:(MTLPrimitiveType)U16(0) indexCount:(NSUInteger)U64(8) indexType:(MTLIndexType)U16(2) indexBuffer:b indexBufferOffset:(NSUInteger)U64(16) instanceCount:(NSUInteger)U64(24)];
        draws++;
        break;
    }
    case 0: /* {primitive 32, start 64, count 64} */
        [e drawPrimitives:(MTLPrimitiveType)U32(0) vertexStart:(NSUInteger)U64(4) vertexCount:(NSUInteger)U64(12)];
        draws++;
        break;
    case 2: /* {start 64, count 64, instances 64, primitive} */
        [e drawPrimitives:(MTLPrimitiveType)U16(24) vertexStart:(NSUInteger)U64(0) vertexCount:(NSUInteger)U64(8) instanceCount:(NSUInteger)U64(16)];
        draws++;
        break;
    case 4: /* {start 64, count 64, instances 64, base instance 64, primitive} */
        [e drawPrimitives:(MTLPrimitiveType)U16(32) vertexStart:(NSUInteger)U64(0) vertexCount:(NSUInteger)U64(8) instanceCount:(NSUInteger)U64(16) baseInstance:(NSUInteger)U64(24)];
        draws++;
        break;
    case 5: /* {start, count, instances, base instance, primitive}, all 16 */
        [e drawPrimitives:(MTLPrimitiveType)U16(8) vertexStart:U16(0) vertexCount:U16(2) instanceCount:U16(4) baseInstance:U16(6)];
        draws++;
        break;
    case 10: case 28: { /* {primitive, index type, ref, offset 64, count 64, instances 64, base vertex 64, base instance 64} */
        id<MTLBuffer> b = [self get:U32(4) task:task];
        if (b) [e drawIndexedPrimitives:(MTLPrimitiveType)U16(0) indexCount:(NSUInteger)U64(16) indexType:(MTLIndexType)U16(2) indexBuffer:b indexBufferOffset:(NSUInteger)U64(8)
                          instanceCount:(NSUInteger)U64(24) baseVertex:(NSInteger)U64(32) baseInstance:(NSUInteger)U64(40)];
        draws++;
        break;
    }
    case 11: case 29: { /* {primitive, index type, ref, offset 16, count 16, instances 16, base vertex 16, base instance 16}; 29's base vertex can be negative */
        id<MTLBuffer> b = [self get:U32(4) task:task];
        NSInteger base_vertex = tag == 29 ? (NSInteger)(int16_t)U16(14) : (NSInteger)U16(14);
        if (b) [e drawIndexedPrimitives:(MTLPrimitiveType)U16(0) indexCount:U16(10) indexType:(MTLIndexType)U16(2) indexBuffer:b indexBufferOffset:U16(8)
                          instanceCount:U16(12) baseVertex:base_vertex baseInstance:U16(16)];
        draws++;
        break;
    }
    case 16: { /* {ref, primitive 16, 2 unused, offset 64} */
        id<MTLBuffer> b = [self get:U32(0) task:task];
        if (b) [e drawPrimitives:(MTLPrimitiveType)U16(4) indirectBuffer:b indirectBufferOffset:(NSUInteger)U64(8)];
        draws++;
        break;
    }
    case 17: { /* {primitive, index type, index ref, indirect ref, index offset 64, indirect offset 64} */
        id<MTLBuffer> index = [self get:U32(4) task:task], indirect = [self get:U32(8) task:task];
        if (index && indirect) [e drawIndexedPrimitives:(MTLPrimitiveType)U16(0) indexType:(MTLIndexType)U16(2) indexBuffer:index indexBufferOffset:(NSUInteger)U64(12)
                                          indirectBuffer:indirect indirectBufferOffset:(NSUInteger)U64(20)];
        draws++;
        break;
    }
    case 154: { /* {count, then a viewport and a render target offset for each view} */
        uint32_t count = U32(0);
        MTLVertexAmplificationViewMapping views[8];
        if (count == 0 || count > 8 || r.size < 4 + count * 8ull || ![e.device supportsVertexAmplificationCount:count]) break;
        for (uint32_t i = 0; i < count; i++) {
            views[i].viewportArrayIndexOffset = U32(4 + i * 8);
            views[i].renderTargetArrayIndexOffset = U32(8 + i * 8);
        }
        [e setVertexAmplificationCount:count viewMappings:views];
        break;
    }
    case 155: {
        MTLSize s;
        memcpy(&s, r.p, sizeof s);
        [e dispatchThreadsPerTile:s];
        break;
    }
    case 162: { /* threads per tile, then a tile region */
        MTLSize s;
        MTLRegion region;
        memcpy(&s, r.p, sizeof s);
        memcpy(&region, r.p + sizeof s, sizeof region);
        SEL sel = sel_registerName("dispatchThreadsPerTile:inRegion:");
        if ([(id)e respondsToSelector:sel]) ((void (*)(id, SEL, MTLSize, MTLRegion))objc_msgSend)(e, sel, s, region);
        else [e dispatchThreadsPerTile:s];
        break;
    }
    case 164: { /* where to write the tile size: {buffer ref, offset} */
        HvObject *o = [self object:U32(0) task:task];
        uint64_t off = U64(4);
        if (o && o->mapped && off + 4 <= o->length) {
            uint16_t dims[2] = {(uint16_t)e.tileWidth, (uint16_t)e.tileHeight};
            memcpy(o->mapped + off, dims, 4);
        }
        break;
    }
    default:
        [self complain:[NSString stringWithFormat:@"render command %u (%u bytes) skipped", tag, r.size]];
        break;
    }
}

/* Compute calls. Tags start at 200. */
- (void)compute:(id<MTLComputeCommandEncoder>)e tag:(uint32_t)tag rec:(Rec)r task:(uint32_t)task {
    if (!pipeline_set && (tag == 200 || tag == 202)) return;
    switch (tag) {
    case 209: {
        MTLRegion region;
        if (r.size >= sizeof region) {
            memcpy(&region, r.p, sizeof region);
            [e setStageInRegion:region];
        }
        break;
    }
    case 214: /* barriers: encoders here are in order, and each exec is waited for */
    case 215:
        [e memoryBarrierWithScope:MTLBarrierScopeBuffers | MTLBarrierScopeTextures];
        break;
    case 212: {
        id f = [self get:U32(0) task:task];
        if (f) [e updateFence:f];
        break;
    }
    case 213: {
        id f = [self get:U32(0) task:task];
        if (f) [e waitForFence:f];
        break;
    }
    case 208: {
        id state = [self get:U32(0) task:task];
        if (state) [e setComputePipelineState:state];
        pipeline_set = state != nil;
        if (tracing) fprintf(stderr, "trace:  pipeline %u %s\n", U32(0), [objc_getAssociatedObject(state, "hvname") UTF8String]);
        break;
    }
    case 203: {
        uint32_t index = U32(0), count = U32(4);
        if (count > 31) break;
        __unsafe_unretained id<MTLBuffer> buffers[31];
        id strong[31];
        NSUInteger offsets[31];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 12) task:task];
            buffers[i] = strong[i];
            offsets[i] = (NSUInteger)U64(12 + i * 12);
        }
        if (tracing) for (uint32_t i = 0; i < count; i++) {
            id<MTLBuffer> x = strong[i];
            fprintf(stderr, "trace:  cbuf %u ref %u off %lu len %lu:", index + i, U32(8 + i * 12), (unsigned long)offsets[i], (unsigned long)x.length);
            if (x && x.storageMode != MTLStorageModePrivate && offsets[i] < x.length)
                for (NSUInteger k = 0; k < 96 && offsets[i] + k + 4 <= x.length; k += 4)
                    fprintf(stderr, " %08x", *(uint32_t *)((uint8_t *)x.contents + offsets[i] + k));
            fprintf(stderr, "\n");
        }
        [e setBuffers:buffers offsets:offsets withRange:NSMakeRange(index, count)];
        break;
    }
    case 207:
        if (tracing) fprintf(stderr, "trace:  cbuf %u offset now %llu\n", U32(0), (unsigned long long)U64(4));
        [e setBufferOffset:(NSUInteger)U64(4) atIndex:U32(0)];
        break;
    case 206: {
        uint32_t index = U32(0), count = U32(4);
        if (count > 128) break;
        __unsafe_unretained id<MTLTexture> items[128];
        id strong[128];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
        }
        if (tracing) for (uint32_t i = 0; i < count; i++) {
            id<MTLTexture> x = strong[i];
            HvObject *xo = [self object:U32(8 + i * 4) task:task];
            fprintf(stderr, "trace:  ctex %u ref %u %lux%lu fmt %lu type %u surface %s\n", index + i, U32(8 + i * 4), (unsigned long)x.width,
                    (unsigned long)x.height, (unsigned long)x.pixelFormat, xo ? xo->entry[0] & 0xff : 0, xo && xo->surface ? "yes" : "no");
        }
        [e setTextures:items withRange:NSMakeRange(index, count)];
        break;
    }
    case 204: {
        uint32_t index = U32(0), count = U32(4);
        if (count > 16) break;
        __unsafe_unretained id<MTLSamplerState> items[16];
        id strong[16];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
        }
        [e setSamplerStates:items withRange:NSMakeRange(index, count)];
        break;
    }
    case 211: [e setThreadgroupMemoryLength:(NSUInteger)U64(0) atIndex:U32(8)]; break;
    case 200: case 202: {
        MTLSize a, b;
        memcpy(&a, r.p, sizeof a), memcpy(&b, r.p + sizeof a, sizeof b);
        if (tracing) fprintf(stderr, "trace:  dispatch %u %lux%lux%lu by %lux%lux%lu\n", tag, (unsigned long)a.width, (unsigned long)a.height,
                             (unsigned long)a.depth, (unsigned long)b.width, (unsigned long)b.height, (unsigned long)b.depth);
        if (tag == 200) [e dispatchThreadgroups:a threadsPerThreadgroup:b];
        else [e dispatchThreads:a threadsPerThreadgroup:b];
        break;
    }
    case 216: /* {width, height} of the imageblock, 32x32 from macOS 27's glass and blur kernels: without it their
                 imageblock memory is undefined, and toolbars came out black with coloured blocks */
        if (r.size >= 8 && U32(0) && U32(4) && U32(0) <= 256 && U32(4) <= 256) [e setImageblockWidth:U32(0) height:U32(4)];
        break;
    case 219: /* not a command the framework knows either, though the guest sends it */
        break;
    default:
        [self complain:[NSString stringWithFormat:@"compute command %u (%u bytes) skipped", tag, r.size]];
        break;
    }
}

/* Blit calls. Tags start at 300. */
- (void)blit:(id<MTLBlitCommandEncoder>)e tag:(uint32_t)tag rec:(Rec)r task:(uint32_t)task {
    switch (tag) {
    case 316: {
        id f = [self get:U32(0) task:task];
        if (f) [e updateFence:f];
        break;
    }
    case 317: {
        id f = [self get:U32(0) task:task];
        if (f) [e waitForFence:f];
        break;
    }
    case 300: { /* buffer to texture */
        id<MTLBuffer> b = [self get:U32(0) task:task];
        id<MTLTexture> t = [self get:U32(4) task:task];
        if (!b || !t) break;
        MTLSize size;
        MTLOrigin origin;
        memcpy(&size, r.p + 0x20, sizeof size), memcpy(&origin, r.p + 0x38, sizeof origin);
        [e copyFromBuffer:b sourceOffset:(NSUInteger)U64(8) sourceBytesPerRow:(NSUInteger)U64(0x10) sourceBytesPerImage:(NSUInteger)U64(0x18) sourceSize:size
                toTexture:t destinationSlice:U16(0x50) destinationLevel:U16(0x52) destinationOrigin:origin options:(MTLBlitOption)U32(0x54)];
        break;
    }
    case 301: { /* buffer to buffer */
        id<MTLBuffer> a = [self get:U32(0) task:task], b = [self get:U32(4) task:task];
        if (a && b) [e copyFromBuffer:a sourceOffset:(NSUInteger)U64(8) toBuffer:b destinationOffset:(NSUInteger)U64(0x10) size:(NSUInteger)U64(0x18)];
        break;
    }
    case 302: { /* texture to buffer */
        id<MTLTexture> t = [self get:U32(0) task:task];
        id<MTLBuffer> b = [self get:U32(4) task:task];
        if (!b || !t) break;
        MTLOrigin origin;
        MTLSize size;
        memcpy(&origin, r.p + 8, sizeof origin), memcpy(&size, r.p + 0x20, sizeof size);
        [e copyFromTexture:t sourceSlice:U16(0x50) sourceLevel:U16(0x52) sourceOrigin:origin sourceSize:size toBuffer:b
            destinationOffset:(NSUInteger)U64(0x38) destinationBytesPerRow:(NSUInteger)U64(0x40) destinationBytesPerImage:(NSUInteger)U64(0x48) options:(MTLBlitOption)U16(0x54)];
        break;
    }
    case 303: { /* texture to texture */
        id<MTLTexture> a = [self get:U32(0) task:task], b = [self get:U32(4) task:task];
        if (!a || !b) break;
        MTLOrigin from, to;
        MTLSize size;
        memcpy(&from, r.p + 8, sizeof from), memcpy(&size, r.p + 0x20, sizeof size), memcpy(&to, r.p + 0x38, sizeof to);
        [e copyFromTexture:a sourceSlice:U16(0x50) sourceLevel:U16(0x52) sourceOrigin:from sourceSize:size
                 toTexture:b destinationSlice:U16(0x54) destinationLevel:U16(0x56) destinationOrigin:to];
        break;
    }
    case 306: { /* fill: {ref, location, length, value} */
        id<MTLBuffer> b = [self get:U32(0) task:task];
        if (b) [e fillBuffer:b range:NSMakeRange((NSUInteger)U64(4), (NSUInteger)U64(12)) value:r.p[20]];
        break;
    }
    case 307: {
        id<MTLTexture> t = [self get:U32(0) task:task];
        if (t) [e generateMipmapsForTexture:t];
        break;
    }
    case 308: case 309: case 310: case 311: case 314: case 315: /* hints, and syncing memory Apple GPUs share */
        break;
    default:
        [self complain:[NSString stringWithFormat:@"blit command %u (%u bytes) skipped", tag, r.size]];
        break;
    }
}

/* What the guest asks about objects, answered in its own buffers: tags start at
   450, {ref, buffer ref, offset}. The guest's Metal puts these real host values
   into its argument buffers. */
- (void)info:(uint32_t)tag rec:(Rec)r task:(uint32_t)task {
    uint32_t ref = U32(0), bufref = U32(4);
    uint64_t off = U64(8);
    if (tag == 451 || tag == 469) { /* how big a texture would be in a heap: {description, buffer ref, offset} */
        uint32_t at = tag == 451 ? 0x20 : 0x28;
        if (r.size < at + 12) return;
        MTLTextureDescriptor *t = tag == 451 ? descriptor_v1(r.p) : descriptor_v2(r.p);
        HvObject *to = [self object:U32(at) task:task];
        refresh_pages(self, task, to);
        uint64_t where = U64(at + 4);
        if (!to || !to->mapped || where + 16 > to->length) { [self complain:@"heap size query: no buffer"]; return; }
        MTLSizeAndAlign sa = [device heapTextureSizeAndAlignWithDescriptor:t];
        uint64_t v[2] = {sa.size, sa.align};
        memcpy(to->mapped + where, v, 16);
        return;
    }
    if (tag == 460) { /* an object's identifier: {ref, kind, buffer ref, offset} */
        bufref = U32(8);
        off = U64(12);
    }
    HvObject *to = [self object:bufref task:task];
    if (to) refresh_pages(self, task, to);
    uint8_t *out = to && to->mapped && off + 28 <= to->length ? to->mapped + off : NULL;
    id obj = [self get:ref task:task];
    if (!out || !obj) {
        [self complain:[NSString stringWithFormat:@"info %u: ref %u buffer %u (%s, %llu bytes) offset %llu: %s", tag, ref, bufref,
                        !to ? "unknown" : to->mapped ? "mapped" : "not mapped", to ? to->length : 0, off, out ? "no object" : "no buffer"]];
        return;
    }
    SEL index_sel = sel_registerName("resourceIndex");
    uint64_t index = [obj respondsToSelector:index_sel] ? ((uint64_t (*)(id, SEL))objc_msgSend)(obj, index_sel) : 0;
    switch (tag) {
    case 460: {
        SEL sel = sel_registerName("uniqueIdentifier");
        uint64_t v = [obj respondsToSelector:sel] ? ((uint64_t (*)(id, SEL))objc_msgSend)(obj, sel) : (uint64_t)(uintptr_t)obj;
        memcpy(out, &v, 8);
        break;
    }
    case 457: { /* render pipeline: {max threads, imageblock length, tile match, indirect} */
        id<MTLRenderPipelineState> p = obj;
        uint32_t v[2] = {(uint32_t)p.maxTotalThreadsPerThreadgroup, (uint32_t)p.imageblockSampleLength};
        memcpy(out, v, 8);
        out[8] = p.threadgroupSizeMatchesTileSize, out[9] = p.supportIndirectCommandBuffers;
        break;
    }
    case 450: { /* compute pipeline */
        id<MTLComputePipelineState> p = obj;
        uint64_t v[3] = {p.maxTotalThreadsPerThreadgroup, p.threadExecutionWidth, p.staticThreadgroupMemoryLength};
        memcpy(out, v, 24);
        out[24] = p.supportIndirectCommandBuffers;
        break;
    }
    case 463: { /* heap: where the whole of it is */
        id<MTLHeap> h = obj;
        HvObject *ho = [self object:ref task:task];
        uint64_t a = ho && ho->heap_whole ? ho->heap_whole.gpuAddress : 0;
        (void)h;
        memcpy(out, &a, 8);
        break;
    }
    case 461: { /* buffer */
        uint64_t a = [(id<MTLBuffer>)obj gpuAddress];
        memcpy(out, &a, 8);
        break;
    }
    case 462: case 464: case 466: case 467: case 468: { /* texture, sampler, render, compute, depth-stencil */
        MTLResourceID id_ = ((MTLResourceID (*)(id, SEL))objc_msgSend)(obj, @selector(gpuResourceID));
        memcpy(out, &id_, 8);
        memcpy(out + 8, &index, 8);
        break;
    }
    default:
        [self complain:[NSString stringWithFormat:@"info command %u (%u bytes) skipped", tag, r.size]];
        break;
    }
}

/* One exec: {task, resources, buffers}, {ref, flags} per resource, {offset, length} per buffer. */
/* Commits without waiting: the next batch can be encoded while the GPU does this one. */
- (void)commit:(id<MTLCommandBuffer>)cb channel:(uint32_t)ch stamp:(uint32_t)stamp complete:(BOOL)complete {
    static int sync = -1; /* HV_PVG_SYNC: wait for the GPU after every batch */
    if (sync < 0) sync = getenv("HV_PVG_SYNC") != NULL;
    HvPvgLite *l = lite;
    atomic_fetch_add(&inflight, 1);
    dispatch_group_enter(completions);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.error) {
            self->failed++;
            fprintf(stderr, "hengevm: pvg-metal: command buffer: %s\n", done.error.localizedDescription.UTF8String);
        }
        if (complete) hv_pvg_lite_complete(l, ch, stamp);
        atomic_fetch_sub(&self->inflight, 1);
        dispatch_group_leave(self->completions);
    }];
    [cb commit];
    last_cb = cb;
    if (sync) [cb waitUntilCompleted];
}

/* A command that used the GPU not at all, or waited for by others: its stamp after everything before it. */
- (void)finishChannel:(uint32_t)ch stamp:(uint32_t)stamp {
    if (atomic_load(&inflight) == 0) {
        hv_pvg_lite_complete(lite, ch, stamp);
        return;
    }
    [self commit:[queue commandBuffer] channel:ch stamp:stamp complete:YES];
}

/* Returns YES if the GPU's completion gives the stamp back. */
- (BOOL)exec:(const uint32_t *)a length:(uint32_t)len channel:(uint32_t)ch stamp:(uint32_t)stamp {
    uint32_t task = a[0], nres = a[1], nbuf = a[2];
    if (12 + nres * 8ull + nbuf * 16ull > len) { /* never quietly: a lost job is a frame that never gets drawn */
        [self complain:[NSString stringWithFormat:@"exec of %u bytes dropped: task %u, %u resources, %u buffers", len, task, nres, nbuf]];
        return NO;
    }
    const uint32_t *res = a + 3;
    const uint8_t *bufs = (const uint8_t *)(res + nres * 2);
    tracing = hv_pvg_trace_on() != 0;
    if (tracing) fprintf(stderr, "trace: exec task %u, %u resources, %u buffers\n", task, nres, nbuf);
    double t_begin = now_seconds();
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = nil;
    BOOL sync_after = NO;
    for (uint32_t i = 0; i < nres; i++) {
        HvObject *o = [self object:res[i * 2] task:task];
        if (!o) continue;
        if (o->mapped) refresh_pages(self, task, o);
        if (o->surface) sync_iosurface(o->surface);
        static int tally = -1;
        if (tally < 0) tally = getenv("HV_PVG_TALLY") != NULL;
        if (tally && (o->entry[0] & 0xff) == OBJ_MAPPED_TEXTURE) {
            static uint32_t seen[256];
            uint32_t f = res[i * 2 + 1] & 0xff, key = res[i * 2] & 0xff;
            if (seen[key] != f + 1) {
                seen[key] = f + 1;
                fprintf(stderr, "pvgres task %u ref %u mapped flags %x\n", task, res[i * 2], res[i * 2 + 1]);
            }
        }
        if (res[i * 2 + 1] & 1) o->guest_stale = NO, o->host_valid = NO; /* the guest wrote it */
        if (o->guest_backed && !o->host_valid) {
            if (!o->guest_stale) [self page:o toGuest:NO task:task blit:&blit commandBuffer:cb];
            o->host_valid = YES;
        }
        if (res[i * 2 + 1] & 4) sync_after = YES;
    }
    [blit endEncoding];
    /* Bit 1: this exec writes it, so the guest's copy is out of date from here on. Never
       upload that over what the GPU drew: mostly zeros, which show as black boxes. */
    for (uint32_t i = 0; i < nres; i++)
        if (res[i * 2 + 1] & 2) { /* and what it is made from: a texture in a heap is the heap's bytes */
            for (HvObject *o = [self object:res[i * 2] task:task]; o; o = o->parent) o->guest_stale = YES;
        }
    id e = nil; /* the open encoder */
    uint32_t etype = 0;
    for (uint32_t b = 0; b < nbuf; b++) {
        uint64_t off, blen;
        memcpy(&off, bufs + b * 16, 8);
        memcpy(&blen, bufs + b * 16 + 8, 8);
        if (blen > (64u << 20) || blen < 8) continue;
        /* Read where it is when it is in one piece (nearly always: the guest is waiting for this exec and does not
           touch it meanwhile), else copied once into a buffer kept for the next. */
        const uint8_t *p = task_span(self, task, off, blen);
        if (!p) {
            if (blen > cmd_cap) {
                free(cmd_scratch);
                cmd_scratch = malloc((size_t)blen);
                cmd_cap = cmd_scratch ? (size_t)blen : 0;
            }
            if (!cmd_scratch || task_copy(self, task, off, cmd_scratch, blen)) { [self complain:@"command buffer unreadable"]; continue; }
            p = cmd_scratch;
        }
        const uint8_t *end = p + blen;
        uint32_t seglen, info;
        memcpy(&seglen, p, 4), memcpy(&info, p + 4, 4);
        p += 8;
        if ((info & 0xff) == 5) { /* protection options, then the real header */
            p += 8;
            if (p + 8 > end) continue;
            memcpy(&seglen, p, 4), memcpy(&info, p + 4, 4);
            p += 8;
        }
        uint32_t type = info & 0xff, cont = (info >> 8) & 0xff, more = (info >> 16) & 0xff;
        if (p + seglen < end) end = p + seglen;
        if (!cont && e) { [e endEncoding]; e = nil; }
        if (type > 2) {
            const uint8_t *q = p;
            while (q + 8 <= end) {
                uint32_t tag = *(const uint32_t *)q, sz = *(const uint32_t *)(q + 4);
                if (sz < 8 || q + sz > end) break;
                Rec r = {q + 8, sz - 8};
                if (type == 4) [self info:tag rec:r task:task];
                else [self complain:[NSString stringWithFormat:@"encoder type %u command %u (%u bytes) skipped", type, tag, sz]];
                q += sz;
            }
            continue;
        }
        if (!e && type == 1) e = [cb computeCommandEncoder], pipeline_set = NO;
        if (!e && type == 2) e = [cb blitCommandEncoder];
        etype = type;
        @try {
            while (p + 8 <= end) {
                uint32_t tag, size;
                memcpy(&tag, p, 4), memcpy(&size, p + 4, 4);
                if (size < 8 || p + size > end) break;
                Rec r = {p + 8, size - 8};
                if (etype == 0 && tag >= 30 && tag <= 36) { /* these describe the pass that follows */
                    if (tag == 30 && size >= 12) pre_raster_samples = U32(0);
                    else if (tag == 34 && size >= 12) pre_imageblock = U32(0);
                    else if (tag == 35 && size >= 12) pre_threadgroup = U32(0);
                    else if (tag == 36 && size >= 12) pre_tile_w = U32(0) & 0xffff, pre_tile_h = U32(0) >> 16;
                    else if (tag == 33 || tag == 32) [self complain:[NSString stringWithFormat:@"pass description %u (%u bytes) not done", tag, size]];
                } else if (etype == 0 && tag == 26) {
                    if (e) [e endEncoding];
                    e = [self beginPass:r task:task commandBuffer:cb];
                    pipeline_set = NO, tess_factors = NO;
                } else if (e) {
                    if (etype == 0) [self render:e tag:tag rec:r task:task];
                    else if (etype == 1) [self compute:e tag:tag rec:r task:task];
                    else [self blit:e tag:tag rec:r task:task];
                }
                p += size;
            }
        } @catch (NSException *x) {
            [self complain:[NSString stringWithFormat:@"exception: %@", x.reason]];
            failed++;
        }
        if (!more && e) { [e endEncoding]; e = nil; }
    }
    if (e) [e endEncoding];
    if (cmd_cap > (4u << 20)) { /* a big one, rare: not kept */
        free(cmd_scratch);
        cmd_scratch = NULL, cmd_cap = 0;
    }
    if (sync_after) { /* the guest wants these back as soon as this is done */
        id<MTLBlitCommandEncoder> back = nil;
        for (uint32_t i = 0; i < nres; i++) {
            if (!(res[i * 2 + 1] & 4)) continue;
            HvObject *o = [self object:res[i * 2] task:task];
            if (!o || !o->guest_backed) continue;
            [self page:o toGuest:YES task:task blit:&back commandBuffer:cb];
            o->guest_stale = NO;
        }
        [back endEncoding];
    }
    double t1 = now_seconds();
    [self commit:cb channel:ch stamp:stamp complete:YES];
    double t2 = now_seconds();
    encode_time += t1 - t_begin, gpu_wait_time += t2 - t1;
    if (++execs % 2000 == 0) {
        static double t0;
        if (!t0) t0 = now_seconds();
        fprintf(stderr, "hengevm: pvg-metal: %llu execs, %llu draws, %llu failed, %llu synced, %llu remaps, %.0f s; encoding %.2f s, waiting for the GPU %.2f s\n", (unsigned long long)execs, (unsigned long long)draws, (unsigned long long)failed, (unsigned long long)synced, (unsigned long long)remaps, now_seconds() - t0, encode_time, gpu_wait_time);
        encode_time = gpu_wait_time = 0;
    }
    return YES;
}

/* Every possible half-float value to a display byte, as the screen would show it in the current mode (see hv_half_mode). */
static const uint8_t *half_to_byte(void) {
    static uint8_t *tables[2];
    int mode = hv_half_mode_get();
    if (tables[mode]) return tables[mode];
    uint8_t *t = malloc(65536);
    for (uint32_t i = 0; i < 65536; i++) {
        uint16_t bits = (uint16_t)i;
        __fp16 h;
        memcpy(&h, &bits, 2);
        float v = h;
        t[i] = !(v > 0) ? 0 : v >= 1 ? 255 : (uint8_t)(hv_half_shown(v, mode) * 255.0f + 0.5f);
    }
    tables[mode] = t;
    return t;
}

/* Op 4: a new pointer image in the kernel task's memory, premultiplied BGRA:
   {port, 0, offset, mapped length, stride, width, height, hot x, hot y, sum}. */
- (void)cursorGlyph:(const uint32_t *)a length:(uint32_t)n {
    if (n < 0x2c) return;
    uint64_t off, stride;
    memcpy(&off, a + 2, 8), memcpy(&stride, a + 6, 8);
    uint16_t w, h, hx, hy;
    memcpy(&w, (const uint8_t *)a + 0x20, 2), memcpy(&h, (const uint8_t *)a + 0x22, 2);
    memcpy(&hx, (const uint8_t *)a + 0x24, 2), memcpy(&hy, (const uint8_t *)a + 0x26, 2);
    if (!w || !h || w > 512 || h > 512 || stride < (uint64_t)w * 4 || stride > 8192) return;
    uint8_t *bits = malloc((size_t)stride * h);
    if (hv_pvg_lite_task_read(lite, 0, off, bits, (uint32_t)stride * h)) {
        free(bits);
        [self complain:@"pointer image unreadable"];
        return;
    }
    free(cursor);
    MTLTextureDescriptor *ct = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    ct.storageMode = MTLStorageModeShared;
    id<MTLTexture> glyph = [device newTextureWithDescriptor:ct];
    [glyph replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:bits bytesPerRow:(NSUInteger)stride];
    os_unfair_lock_lock(&screen_lock);
    cursor = bits, cursor_w = w, cursor_h = h, cursor_stride = (uint32_t)stride, cursor_hot_x = hx, cursor_hot_y = hy;
    cursor_tex = glyph;
    cursor_seq++;
    os_unfair_lock_unlock(&screen_lock);
    if (getenv("HV_PVG_CURSOR_LOG")) fprintf(stderr, "pvgcursor glyph %ux%u hot %d,%d stride %u first alpha %u\n", w, h, hx, hy, (uint32_t)stride, bits[(size_t)(h / 2) * stride + (size_t)(w / 2) * 4 + 3]);
    [self drawCursor];
}

- (BOOL)hasDisplayLayer {
    os_unfair_lock_lock(&screen_lock);
    BOOL attached = layer != nil;
    os_unfair_lock_unlock(&screen_lock);
    return attached;
}

/* Puts back what the pointer covered, and draws it where the shared page says it is now. */
- (void)drawCursor {
    if ([self hasDisplayLayer]) {
        [self cursorChanged];
        return;
    }
    if (!frame || !base) return;
    uint32_t w = frame_w, h = frame_h;
    for (int y = drawn_y; y < drawn_y + drawn_h; y++) memcpy(frame + (size_t)y * w * 4 + (size_t)drawn_x * 4, base + (size_t)y * w * 4 + (size_t)drawn_x * 4, (size_t)drawn_w * 4);
    drawn_w = drawn_h = 0;
    const uint8_t *page = hv_pvg_lite_display_page(lite);
    if (!page || !cursor || !(cursor_shown || page[0xe04])) return;
    uint32_t where = __atomic_load_n((const uint32_t *)(page + 0xe00), __ATOMIC_ACQUIRE);
    if (getenv("HV_PVG_CURSOR_LOG")) {
        static uint32_t last;
        if (where != last) fprintf(stderr, "pvgcursor at %u,%u shown %d flag %d\n", where & 0xffff, where >> 16, cursor_shown, page[0xe04]);
        last = where;
    }
    if (where == 0xffffffff) return;
    /* Bigger than the guest draws it. The hot spot stays where it points. */
    const int scale = cursor_scale();
    /* The pointer's place is in the display mode's pixels; a scaled resolution's frame is smaller than the mode. */
    uint32_t mw = w, mh = h;
    hv_pvg_lite_mode(&mw, &mh);
    if (!mw || !mh) mw = w, mh = h;
    int x = (int)((uint64_t)(where & 0xffff) * w / mw) - cursor_hot_x * scale, y = (int)((uint64_t)(where >> 16) * h / mh) - cursor_hot_y * scale;
    int cw = (int)cursor_w * scale, ch = (int)cursor_h * scale;
    int x0 = x < 0 ? 0 : x, y0 = y < 0 ? 0 : y;
    int x1 = x + cw > (int)w ? (int)w : x + cw, y1 = y + ch > (int)h ? (int)h : y + ch;
    if (x1 <= x0 || y1 <= y0) return;
    for (int py = y0; py < y1; py++) {
        const uint8_t *row = cursor + (size_t)((py - y) / scale) * cursor_stride;
        uint8_t *dst = frame + (size_t)py * w * 4 + (size_t)x0 * 4;
        for (int px = x0; px < x1; px++, dst += 4) {
            const uint8_t *src = row + (size_t)((px - x) / scale) * 4;
            uint32_t keep = 255u - src[3];
            dst[0] = (uint8_t)(src[0] + (dst[0] * keep + 127) / 255);
            dst[1] = (uint8_t)(src[1] + (dst[1] * keep + 127) / 255);
            dst[2] = (uint8_t)(src[2] + (dst[2] * keep + 127) / 255);
        }
    }
    drawn_x = x0, drawn_y = y0, drawn_w = x1 - x0, drawn_h = y1 - y0;
}

static NSString *const screen_shaders = @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct V { float4 at [[position]]; float2 uv; };\n"
    "vertex V screen_v(uint i [[vertex_id]], constant float4 &rect [[buffer(0)]]) {\n"
    "  float2 c = float2(i & 1, (i >> 1) & 1);\n"
    "  V o; o.at = float4(rect.xy + c * rect.zw, 0, 1); o.uv = float2(c.x, 1 - c.y); return o; }\n"
    "fragment float4 screen_plain(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant float &bright [[buffer(1)]]) {\n"
    "  return float4(t.sample(s, v.uv).rgb * bright, 1); }\n"
    "fragment float4 screen_linear(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant uint &mode [[buffer(0)]],\n"
    "                              constant float &bright [[buffer(1)]]) {\n"
    "  float3 c = saturate(t.sample(s, v.uv).rgb);\n"
    "  if (mode == 1) c = select(1.055 * powr(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);\n"
    "  return float4(c * bright, 1); }\n"
    "fragment float4 screen_cursor(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant float &bright [[buffer(1)]]) {\n"
    "  float4 c = t.sample(s, v.uv); return float4(c.rgb * bright, c.a); }\n";

- (BOOL)prepareScreenForLayer:(CAMetalLayer *)target {
    if (!screen_pipe || !linear_pipe || !cursor_pipe) {
        NSError *err = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:screen_shaders options:nil error:&err];
        if (!lib) { [self complain:[NSString stringWithFormat:@"screen shaders: %@", err.localizedDescription]]; return NO; }
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"screen_v"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        d.fragmentFunction = [lib newFunctionWithName:@"screen_plain"];
        screen_pipe = [device newRenderPipelineStateWithDescriptor:d error:&err];
        d.fragmentFunction = [lib newFunctionWithName:@"screen_linear"];
        linear_pipe = [device newRenderPipelineStateWithDescriptor:d error:&err];
        d.fragmentFunction = [lib newFunctionWithName:@"screen_cursor"];
        d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        cursor_pipe = [device newRenderPipelineStateWithDescriptor:d error:&err];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        screen_sampler = [device newSamplerStateWithDescriptor:sd];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
        cursor_sampler = [device newSamplerStateWithDescriptor:sd];
        if (!screen_pipe || !linear_pipe || !cursor_pipe || !screen_sampler || !cursor_sampler) { [self complain:[NSString stringWithFormat:@"screen pipelines: %@", err.localizedDescription]]; return NO; }
    }
    // Pipelines are shared, but a newly connected monitor has a fresh layer.
    if (prepared_layer != target) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        target.device = device;
        target.pixelFormat = MTLPixelFormatBGRA8Unorm;
        target.framebufferOnly = !(getenv("HV_PVG_GPU_TEST") || getenv("HV_COLOR_PROBE")); /* the probe copies the drawable out */
        target.allowsNextDrawableTimeout = YES;
        target.maximumDrawableCount = 3;
        [CATransaction commit];
        prepared_layer = target;
        fprintf(stderr, "hengevm: pvg-metal: half-float display surfaces are shown %s (HV_PVG_HALF=%s)\n",
                hv_half_mode_get() == 1 ? "as LINEAR light with an sRGB encode" : "as display-encoded values, passed through", hv_half_mode_get() == 1 ? "linear" : "encoded/default");
        if (cp.on) cp_log_layer(self, target);
    }
    return YES;
}

/* The display, drawn by the GPU. Waiting for a drawable can take until the screen's next
   refresh, so that happens on a thread of its own and never holds up the guest's GPU work:
   this only says what to show next. Whatever is newest when a drawable comes is what is shown. */
- (void)kickPresenter:(BOOL)fresh {
    /* screen_lock held */
    if (atomic_load(&stopping)) return;
    if (fresh) screen_requests++;
    if (presenter_running || !layer || !screen_tex || drawable_retry_pending) return;
    if (drawable_retry_cooldown) {
        double delay = drawable_retry_cooldown - now_seconds();
        if (delay > 0) {
            if (!fresh) return;
            // Coalesce fresh work arriving during cooldown; it may be the guest's
            // last update. Automatic retries alone never reopen an exhausted budget.
            drawable_retry_pending = YES;
            uint64_t generation = layer_generation;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), presenter, ^{
                os_unfair_lock_lock(&self->screen_lock);
                if (self->layer_generation == generation) {
                    self->drawable_retry_pending = NO;
                    self->drawable_retry_cooldown = self->drawable_retry_deadline = 0;
                    [self kickPresenter:NO];
                }
                os_unfair_lock_unlock(&self->screen_lock);
            });
            return;
        }
        drawable_retry_cooldown = drawable_retry_deadline = 0;
    }
    presenter_running = YES;
    dispatch_async(presenter, ^{ [self presentLoop]; });
}

- (void)showOnLayer:(uint64_t)mapping {
    HvObject *surface = hv_pvg_lite_old_driver(lite) ? [self currentSurface:mapping] : (surfaces[@(mapping)] ?: [self newSurface:mapping]); /* not met yet: a resumed machine's screen */
    if (!surface) { [self complain:[NSString stringWithFormat:@"swap to unknown surface %llu", mapping]]; return; }
    on_screen = mapping;
    BOOL half = surface->fourcc == 'RGhA';
    if (!screen_tex) fprintf(stderr, "hengevm: display scanout format %s (%ux%u)\n",
                             half ? "RGBA16Float" : "BGRA8Unorm", surface->surface_w, surface->surface_h);
    if (!surface->scanout) {
        MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:half ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm
                                                                                     width:surface->surface_w height:surface->surface_h mipmapped:NO];
        t.storageMode = MTLStorageModeShared;
        t.usage = MTLTextureUsageShaderRead;
        if (linear_texture_fits(device, t, surface->first, surface->row, ((id<MTLBuffer>)surface->object).length))
            surface->scanout = [(id<MTLBuffer>)surface->object newTextureWithDescriptor:t offset:surface->first bytesPerRow:surface->row];
        if (!surface->scanout) { [self complain:[NSString stringWithFormat:@"no scanout for surface %llu, row %llu", mapping, surface->row]]; return; }
    }
    os_unfair_lock_lock(&screen_lock);
    if (screen_tex && (screen_w != surface->surface_w || screen_h != surface->surface_h)) [self targetChanged]; /* a new mode */
    screen_tex = surface->scanout, screen_half = half, screen_w = surface->surface_w, screen_h = surface->surface_h;
    screen_dirty = YES;
    [self kickPresenter:YES];
    os_unfair_lock_unlock(&screen_lock);
}

/* The frame as it is, drawn again (the colour probe: another mode, a post-shader capture). */
- (void)screenChanged {
    os_unfair_lock_lock(&screen_lock);
    if (screen_tex) {
        screen_dirty = YES;
        [self kickPresenter:YES];
    }
    os_unfair_lock_unlock(&screen_lock);
}

/* The pointer moved or changed, with no need to go through the GPU queue's worker: its layer moves, or, while that is
   not laid out, the screen is drawn again with the pointer in it. */
- (void)cursorChanged {
    os_unfair_lock_lock(&screen_lock);
    if (cursor_layer_ok) [self queueCursorUpdate];
    else if (screen_tex) {
        screen_dirty = YES;
        [self kickPresenter:YES];
    }
    os_unfair_lock_unlock(&screen_lock);
}

/* One layer update on its way, at most one a refresh: the newest position is read when it runs. screen_lock held. */
- (void)queueCursorUpdate {
    if (cursor_queued || atomic_load(&stopping) || !cursor_queue) return;
    cursor_queued = YES;
    double wait = cursor_next - now_seconds();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, wait > 0 ? (int64_t)(wait * NSEC_PER_SEC) : 0), cursor_queue, ^{ [self updateCursorLayer]; });
}

/* The target, or its size, changed (the app lays its view out again, or another screen takes over): the pointer goes
   back into the frame until the layout has settled, then onto its layer again (enableCursorLayer). screen_lock held,
   with the new target's generation. */
- (void)targetChanged {
    if (!cursor_queue) return;
    cursor_layer_ok = NO;
    overlay_hold = YES;
    [self queueCursorUpdate]; /* hides it, or takes it off a target that went */
    if (overlay_never || !layer) return;
    uint64_t generation = layer_generation;
    /* SwiftUI's layout animations here take 0.25 s, a rotation about 0.35 s. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 450 * NSEC_PER_MSEC), cursor_queue, ^{ [self enableCursorLayer:generation]; });
}

- (void)enableCursorLayer:(uint64_t)generation {
    os_unfair_lock_lock(&screen_lock);
    BOOL settled = layer_generation == generation && layer && !atomic_load(&stopping);
    if (settled) {
        cursor_layer_ok = YES;
        overlay_hold = YES; /* shown once a frame without the pointer in it is on screen */
        if (screen_tex) {
            screen_dirty = YES;
            [self kickPresenter:YES];
        }
    }
    os_unfair_lock_unlock(&screen_lock);
}

/* A frame drawn without the pointer is on screen: the layer can show it now. */
- (void)releaseCursorHold:(uint64_t)generation {
    os_unfair_lock_lock(&screen_lock);
    if (layer_generation == generation && cursor_layer_ok && overlay_hold) {
        overlay_hold = NO;
        [self queueCursorUpdate];
    }
    os_unfair_lock_unlock(&screen_lock);
}

/* The pointer's image for its layer: premultiplied BGRA as the guest gave it, dimmed as the screen is (colour times
   brightness, alpha kept, which is what drawing it into the dimmed frame gave). */
static CGImageRef cursor_image(const uint8_t *bits, uint32_t w, uint32_t h, uint32_t stride, int bright, CGColorSpaceRef space) {
    size_t row = (size_t)w * 4;
    NSMutableData *d = [NSMutableData dataWithLength:row * h];
    uint8_t *out = d.mutableBytes;
    for (uint32_t y = 0; y < h; y++) {
        const uint8_t *in = bits + (size_t)y * stride;
        uint8_t *o = out + (size_t)y * row;
        for (size_t x = 0; x < row; x += 4) {
            for (int c = 0; c < 3; c++) o[x + c] = (uint8_t)((in[x + c] * bright + 500) / 1000);
            o[x + 3] = in[x + 3];
        }
    }
    CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)d);
    CGImageRef img = dp ? CGImageCreate(w, h, 8, 32, row, space, (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                                        dp, NULL, false, kCGRenderingIntentDefault) : NULL;
    CGDataProviderRelease(dp);
    return img;
}

/* Cursor queue: the pointer's layer where the guest's shared page says the pointer is now. Off the main thread, in a
   transaction of its own: Core Animation takes layer changes from any thread. */
- (void)updateCursorLayer {
    /* Nothing of Core Animation's under screen_lock: the main thread takes that lock while it lays out layers. */
    int bright = (int)(brightness_now() * 1000 + 0.5f);
    CGFloat scale = cursor_scale();
    os_unfair_lock_lock(&screen_lock);
    cursor_queued = NO;
    cursor_next = now_seconds() + hv_present_every(present_every, hv_pvg_present_hz()); /* paced as the screen */
    CAMetalLayer *target = atomic_load(&stopping) ? nil : layer;
    BOOL visible = target && cursor_layer_ok && !overlay_hold && cursor && screen_w && screen_h;
    uint32_t W = screen_w, H = screen_h, cw = cursor_w, ch = cursor_h, stride = cursor_stride;
    int hx = cursor_hot_x, hy = cursor_hot_y;
    BOOL shown = cursor_shown;
    uint64_t seq = cursor_seq;
    NSData *bits = visible && (seq != overlay_seq || bright != overlay_bright || overlay_matched < 0)
                       ? [NSData dataWithBytes:cursor length:(size_t)stride * ch] : nil;
    os_unfair_lock_unlock(&screen_lock);
    int matched = target && target.colorspace != NULL;
    if (visible && !bits && matched != overlay_matched) { /* only the colour matching changed */
        os_unfair_lock_lock(&screen_lock);
        if (cursor && cursor_seq == seq) bits = [NSData dataWithBytes:cursor length:(size_t)stride * ch];
        os_unfair_lock_unlock(&screen_lock);
        if (!bits) visible = NO; /* a new image is on its way, with its own update */
    }
    const uint8_t *page = target && lite ? hv_pvg_lite_display_page(lite) : NULL; /* target: not stopping */
    uint32_t where = page ? __atomic_load_n((const uint32_t *)(page + 0xe00), __ATOMIC_ACQUIRE) : 0xffffffff;
    if (where == 0xffffffff || !(shown || page[0xe04])) visible = NO;
    CGRect bounds = target ? target.bounds : CGRectZero;
    NSString *gravity = target.contentsGravity;
    CGRect content = bounds;
    if (W && H && bounds.size.width > 0 && bounds.size.height > 0 && ![gravity isEqualToString:kCAGravityResize]) {
        CGFloat sx = bounds.size.width / W, sy = bounds.size.height / H;
        CGFloat s = [gravity isEqualToString:kCAGravityResizeAspectFill] ? MAX(sx, sy) : MIN(sx, sy);
        content = CGRectMake(bounds.origin.x + (bounds.size.width - W * s) / 2, bounds.origin.y + (bounds.size.height - H * s) / 2, W * s, H * s);
        if (![gravity isEqualToString:kCAGravityResizeAspect] && ![gravity isEqualToString:kCAGravityResizeAspectFill]) visible = NO;
    }
    if (content.size.width <= 0 || content.size.height <= 0) visible = NO;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!overlay_box && target) {
        overlay_box = [CALayer layer];
        overlay_box.masksToBounds = YES;
        overlay_box.anchorPoint = CGPointZero;
        overlay_glyph = [CALayer layer];
        overlay_glyph.anchorPoint = CGPointZero;
        [overlay_box addSublayer:overlay_glyph];
    }
    CAMetalLayer *parent = overlay_parent;
    if (overlay_box && parent != target) {
        [overlay_box removeFromSuperlayer];
        if (target) [target addSublayer:overlay_box];
        overlay_parent = target;
    }
    if (overlay_box) overlay_box.hidden = !visible;
    if (visible && overlay_box) {
        if (bits) {
            CGColorSpaceRef space = matched ? CGColorSpaceRetain(target.colorspace) : CGColorSpaceCreateDeviceRGB();
            CGImageRef img = cursor_image(bits.bytes, cw, ch, stride, bright, space);
            CGColorSpaceRelease(space);
            overlay_glyph.contents = (__bridge_transfer id)img;
            overlay_seq = seq, overlay_bright = bright, overlay_matched = matched;
        }
        /* Where the presenter would draw it: the place in the display mode's pixels (the surface can be smaller,
           a scaled resolution), the size from the guest's image times the pointer scale. */
        uint32_t MW = W, MH = H;
        hv_pvg_lite_mode(&MW, &MH);
        if (!MW || !MH) MW = W, MH = H;
        CGFloat x = ((CGFloat)(where & 0xffff) - hx * scale) / MW, y = ((CGFloat)(where >> 16) - hy * scale) / MH;
        CGFloat w = cw * scale / MW, h = ch * scale / MH;
#if !TARGET_OS_IPHONE
        y = 1 - y - h; /* a Mac's layers count from the bottom */
#endif
        overlay_box.bounds = CGRectMake(0, 0, content.size.width, content.size.height);
        overlay_box.position = content.origin;
        overlay_glyph.frame = CGRectMake(x * content.size.width, y * content.size.height, w * content.size.width, h * content.size.height);
        NSString *filter = atomic_load(&cursor_sharp) ? kCAFilterNearest : kCAFilterLinear;
        overlay_glyph.magnificationFilter = filter;
        overlay_glyph.minificationFilter = filter;
    }
    [CATransaction commit];
    [CATransaction flush];
}

- (void)presentLoop {
    for (;;) @autoreleasepool {
        /* Under a present cap (hot, Low Power Mode: hv_pvg_present_hz) the next frame is taken a whole interval after
           the last present, the newest there is then; frames meanwhile only mark the screen dirty. */
        double wait = hv_present_wait(last_present, now_seconds(), present_every,
                                      hv_present_every(present_every, hv_pvg_present_hz()));
        if (wait > 0) usleep((useconds_t)(wait * 1e6));
        os_unfair_lock_lock(&screen_lock);
        if (!screen_dirty || !layer) {
            presenter_running = NO;
            os_unfair_lock_unlock(&screen_lock);
            return;
        }
        screen_dirty = NO;
        CAMetalLayer *target = layer; // retained across nextDrawable and a concurrent disconnect
        uint64_t generation = layer_generation, requests = screen_requests;
        id<MTLTexture> tex = screen_tex, ctex = cursor_tex;
        BOOL half = screen_half, shown = cursor_shown;
        uint32_t W = screen_w, H = screen_h, cw0 = cursor_w, ch0 = cursor_h;
        int hx = cursor_hot_x, hy = cursor_hot_y;
        os_unfair_lock_unlock(&screen_lock);
        if (![self prepareScreenForLayer:target]) {
            os_unfair_lock_lock(&screen_lock);
            BOOL changed = layer_generation != generation;
            if (!changed) presenter_running = NO;
            os_unfair_lock_unlock(&screen_lock);
            if (changed) continue;
            return;
        }
        CGSize want = CGSizeMake(W, H);
        if (!CGSizeEqualToSize(target.drawableSize, want)) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            target.drawableSize = want;
            [CATransaction commit];
        }
        id<CAMetalDrawable> drawable = [target nextDrawable]; /* the wait is here */
        if (!drawable) {
            os_unfair_lock_lock(&screen_lock);
            screen_dirty = YES;
            BOOL changed = layer_generation != generation;
            if (!changed) {
                presenter_running = NO;
                double now = now_seconds();
                if (!drawable_retry_deadline) drawable_retry_deadline = now + 2;
                BOOL exhausted = now >= drawable_retry_deadline;
                if (exhausted) {
                    drawable_retry_cooldown = now + 1;
                    // A fresh frame/cursor event received while nextDrawable waited
                    // must not lose its wakeup at the transition into cooldown.
                    if (screen_requests != requests) [self kickPresenter:YES];
                } else {
                    // A monitor can connect before its first drawable is available.
                    // Retry even if the guest is idle, but never poll a hidden target forever.
                    drawable_retry_pending = YES;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), presenter, ^{
                        os_unfair_lock_lock(&self->screen_lock);
                        if (self->layer_generation == generation) {
                            self->drawable_retry_pending = NO;
                            [self kickPresenter:NO];
                        }
                        os_unfair_lock_unlock(&self->screen_lock);
                    });
                }
            }
            os_unfair_lock_unlock(&screen_lock);
            if (changed) continue;
            return;
        }
        /* Something newer came during the wait? Then that is the frame to show. */
        os_unfair_lock_lock(&screen_lock);
        tex = screen_tex, half = screen_half, ctex = cursor_tex, shown = cursor_shown;
        cw0 = cursor_w, ch0 = cursor_h, hx = cursor_hot_x, hy = cursor_hot_y;
        BOOL pointer_in_frame = !cursor_layer_ok, hold = overlay_hold; /* else its layer shows it */
        BOOL same_target = layer_generation == generation && layer == target;
        BOOL same_size = screen_w == W && screen_h == H;
        if (same_target && same_size) {
            screen_dirty = NO;
            drawable_retry_deadline = 0;
        }
        os_unfair_lock_unlock(&screen_lock);
        if (!same_target || !same_size) { /* a target or mode change during nextDrawable */
            os_unfair_lock_lock(&screen_lock);
            screen_dirty = YES;
            os_unfair_lock_unlock(&screen_lock);
            continue;
        }
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass];
        [e setRenderPipelineState:half ? linear_pipe : screen_pipe];
        float rect[4] = {-1, -1, 2, 2};
        [e setVertexBytes:rect length:sizeof rect atIndex:0];
        [e setFragmentTexture:tex atIndex:0];
        [e setFragmentSamplerState:screen_sampler atIndex:0];
        if (half) {
            uint32_t half_mode = (uint32_t)hv_half_mode_get();
            [e setFragmentBytes:&half_mode length:sizeof half_mode atIndex:0];
        }
        float bright = brightness_now();
        [e setFragmentBytes:&bright length:sizeof bright atIndex:1];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        const uint8_t *page = hv_pvg_lite_display_page(lite);
        uint32_t where = page ? __atomic_load_n((const uint32_t *)(page + 0xe00), __ATOMIC_ACQUIRE) : 0xffffffff;
        if (pointer_in_frame && ctex && where != 0xffffffff && (shown || page[0xe04])) {
            const float scale = cursor_scale();
            float x = (float)(where & 0xffff) - hx * scale, y = (float)(where >> 16) - hy * scale;
            float cw = cw0 * scale, ch = ch0 * scale;
            /* The pointer's place is in the display mode's pixels, not the surface's: with a scaled resolution
               chosen in macOS (1280x988 on a 1864x1440 display) the surface is smaller than the mode, and the
               pointer was drawn further right and down than where it clicks. Seen on a phone: the pointer at
               1842 of 1864 with a 1600 wide surface, and the Dock's magnification under where it is drawn now.
               The guest stops the pointer 128 x (mode / surface - 1) pixels short of the right and bottom edges
               there and crops its image, while what it clicks goes on to the edge; open. */
            uint32_t MW = W, MH = H;
            hv_pvg_lite_mode(&MW, &MH);
            if (!MW || !MH) MW = W, MH = H;
            float r[4] = {x / MW * 2 - 1, 1 - (y + ch) / MH * 2, cw / MW * 2, ch / MH * 2};
            [e setRenderPipelineState:cursor_pipe];
            [e setVertexBytes:r length:sizeof r atIndex:0];
            [e setFragmentTexture:ctex atIndex:0];
            cursor_settings_refresh();
            [e setFragmentSamplerState:atomic_load(&cursor_sharp) ? cursor_sampler : screen_sampler atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }
        [e endEncoding];
        if (cp.on) cp_capture_post(self, drawable.texture, W, H, cb);
#if !TARGET_OS_IPHONE
        if (getenv("HV_PVG_GPU_TEST")) { /* the same pixels for a screenshot: this is the path a phone runs */
            NSUInteger bytes = (NSUInteger)W * H * 4;
            if (!test_readback || test_readback.length < bytes) test_readback = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
            id<MTLBuffer> rb = test_readback;
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
                      toBuffer:rb destinationOffset:0 destinationBytesPerRow:(NSUInteger)W * 4 destinationBytesPerImage:bytes];
            [b endEncoding];
            [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                (void)done;
                dispatch_async(self->worker, ^{
                    if (!self->frame || self->frame_w != W || self->frame_h != H) {
                        self->frame = malloc((size_t)W * H * 4), self->frame_w = W, self->frame_h = H;
                    }
                    memcpy(self->frame, rb.contents, (size_t)W * H * 4);
                    self->frames++;
                });
            }];
        }
#endif
        /* Once this frame is on screen: the pointer's layer may show (it was waiting for a frame without the pointer
           drawn in), and a target with a frame of its own on it is opaque from then on (the compositor need not blend
           it with what is behind; before its first frame what is behind is the boot screen). */
        BOOL first_here = opaque_layer != target;
        if ((!pointer_in_frame && hold) || first_here) {
            __weak CAMetalLayer *weak_target = target;
            [drawable addPresentedHandler:^(id<MTLDrawable> shown_drawable) {
                (void)shown_drawable;
                /* never a lock of ours on the thread presenting it: queued */
                if (!pointer_in_frame && hold) dispatch_async(self->cursor_queue, ^{ [self releaseCursorHold:generation]; });
                if (first_here) dispatch_async(self->presenter, ^{
                    CAMetalLayer *t = weak_target;
                    if (!t) return;
                    self->opaque_layer = t;
                    if (t.opaque) return;
                    [CATransaction begin];
                    [CATransaction setDisableActions:YES];
                    t.opaque = YES;
                    [CATransaction commit];
                    [CATransaction flush];
                });
            }];
        }
        // Serialize the final check and commit with set_layer: a switch that has
        // returned must not be followed by a commit to its old target.
        os_unfair_lock_lock(&screen_lock);
        if (layer_generation == generation && layer == target) {
            /* No faster than macOS draws (HV_HZ): a ProMotion panel stays at that rate instead of following every
               change, and three drawables queue at most that far ahead. */
            [cb presentDrawable:drawable afterMinimumDuration:present_every];
            [cb commit];
            last_present = now_seconds();
            gpu_frames++;
        } else {
            screen_dirty = YES;
        }
        os_unfair_lock_unlock(&screen_lock);
    }
}

/* What the display should show: at most a few times a second by CPU, for tests and the boot's first frames. */
- (void)present:(uint64_t)mapping {
    if (atomic_load(&stopping)) return;
    double now = now_seconds();
    on_screen = mapping;
    if ([self hasDisplayLayer]) {
        late = NO;
        [self showOnLayer:mapping];
        return;
    }
    if (now - last_capture < 0.066) { /* 15 a second is plenty until this is GPU work */
        late_mapping = mapping, late = YES;
        if (!late_queued) {
            late_queued = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 70 * NSEC_PER_MSEC), worker, ^{
                self->late_queued = NO;
                if (self->late) [self present:self->late_mapping];
            });
        }
        return;
    }
    late = NO;
    HvObject *surface = hv_pvg_lite_old_driver(lite) ? [self currentSurface:mapping] : (surfaces[@(mapping)] ?: [self newSurface:mapping]); /* not met yet: a resumed machine's screen */
    if (!surface) { [self complain:[NSString stringWithFormat:@"swap to unknown surface %llu", mapping]]; return; }
    last_capture = now;
    [last_cb waitUntilCompleted]; /* the CPU copies the pixels here, so the GPU must be done with them */
    NSUInteger bpp = surface->fourcc == 'RGhA' ? 8 : 4, row = surface->row;
    uint32_t w = surface->surface_w, h = surface->surface_h;
    if (!frame || !base || frame_w != w || frame_h != h) {
        free(base);
        base = malloc((size_t)w * h * 4);
        uint8_t *old = frame;
        frame = calloc((size_t)w * h, 4); /* the old one may be on screen for a moment yet: a small leak beats a crash */
        if (old) {
            if (!retired_frames) retired_frames = [NSMutableArray new];
            [retired_frames addObject:[NSValue valueWithPointer:old]];
        }
        frame_w = w, frame_h = h;
        drawn_w = drawn_h = 0;
    }
    uint8_t *out = base;
    const uint8_t *src = surface->mapped + surface->first;
    const uint8_t *lut = half_to_byte();
    if (bpp == 8) {
        for (uint32_t y = 0; y < h; y++) {
            const uint16_t *in = (const uint16_t *)(src + y * row);
            uint8_t *o = out + (size_t)y * w * 4;
            for (uint32_t x = 0; x < w; x++, in += 4, o += 4) {
                o[0] = lut[in[2]], o[1] = lut[in[1]], o[2] = lut[in[0]], o[3] = 255;
            }
        }
    } else {
        for (uint32_t y = 0; y < h; y++) memcpy(out + (size_t)y * w * 4, src + y * row, (size_t)w * 4);
    }
    memcpy(frame, base, (size_t)w * h * 4);
    drawn_w = drawn_h = 0;
    [self drawCursor];
    frames++;
}

#if !TARGET_OS_IPHONE
/* Debugging: HV_PVG_SHOT=prefix keeps what is on the display, every HV_PVG_SHOT_SECS seconds it has changed. */
- (void)saveShot {
    if (!frame || frames == frames_shot) return;
    frames_shot = frames;
    char path[1100];
    snprintf(path, sizeof path, "%s-%04u.png", shot, shots++);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(frame, frame_w, frame_h, 8, (size_t)frame_w * 4, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (dest) {
        CGImageDestinationAddImage(dest, img, NULL);
        CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }
    CFRelease(url), CGImageRelease(img), CGContextRelease(ctx), CGColorSpaceRelease(cs);
}
#endif

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
