/* The Metal replay's own parts, with devices/pvg_metal.m compiled into this test so its static functions and HvReplay's
   methods can be called directly. Needs a Metal device (any Mac, CI's virtual one included). */
#include "../devices/pvg_metal.m"
#include <sys/mman.h>

static int failures;

static void check(const char *what, int ok) {
    if (ok) return;
    printf("  FAIL %s\n", what);
    failures++;
}

/* The saved pipelines: one more save must still be possible where the phone was (31 files, 14 MB of 768). */
static void test_archive_room(void) {
    unsigned long long cap = 768ull << 20;
    check("31 files saved, then one more: still room", !archive_full_at(32, 15ull << 20, cap));
    check("past the size cap: full", archive_full_at(1, cap + 1, cap));
    /* At start the oldest files go, so that a session has room in files and in bytes. */
    unsigned long long sizes[ARCHIVE_FILES + 8];
    for (int i = 0; i < ARCHIVE_FILES + 8; i++) sizes[i] = 1ull << 20;
    check("31 small files: none removed", archive_evict(sizes, 31, cap) == 0);
    NSUInteger k = archive_evict(sizes, ARCHIVE_FILES + 8, cap);
    check("too many files: the oldest go, room for a session left", ARCHIVE_FILES + 8 - k == ARCHIVE_FILES - ARCHIVE_ROOM);
    check("after that, room again", !archive_full_at(ARCHIVE_FILES + 8 - k + 1, (ARCHIVE_FILES + 8 - k + 1) << 20, cap));
    sizes[0] = sizes[1] = cap / 2;
    check("too many bytes: the oldest go until under 7/8 of the cap", archive_evict(sizes, 10, cap) == 1);
    puts("saved pipelines: room checked");
}

/* Records the guest makes too short for what their handlers read: each ends where an unreadable page starts, so a
   handler that reads past its record crashes this test. */
static uint8_t *guard;
static size_t page_size;

static Rec at_guard(const void *bytes, uint32_t size) {
    uint8_t *p = guard + page_size - size;
    memset(p, 0, size);
    if (bytes) memcpy(p, bytes, size);
    return (Rec){p, size};
}

static void test_short_records(HvReplay *r) {
    page_size = (size_t)getpagesize();
    guard = mmap(NULL, page_size * 2, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (guard == MAP_FAILED || mprotect(guard + page_size, page_size, PROT_NONE)) { check("guard page", 0); return; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [r->device newTextureWithDescriptor:td];
    id<MTLCommandBuffer> cb = [r->queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    /* A pass record shorter than its depth and stencil attachments. */
    for (uint32_t size = 0; size < 0x48; size += 4) [r beginPass:at_guard(NULL, size) task:1 commandBuffer:cb];

    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
    r->pipeline_set = NO;
    for (uint32_t tag = 0; tag < 200; tag++)
        for (uint32_t size = 0; size <= 4; size += 4) [r render:re tag:tag rec:at_guard(NULL, size) task:1];
    /* Lists longer than their records: {index 0, count 2} and nothing after. */
    static const uint32_t render_lists[] = {27, 110, 112, 114, 125, 127, 129, 157, 161, 165};
    uint32_t two[2] = {0, 2};
    for (size_t i = 0; i < sizeof render_lists / sizeof *render_lists; i++) [r render:re tag:render_lists[i] rec:at_guard(two, 8) task:1];
    uint32_t heaps[1] = {2};
    [r render:re tag:134 rec:at_guard(heaps, 4) task:1];
    [re endEncoding];

    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    for (uint32_t tag = 200; tag < 230; tag++)
        for (uint32_t size = 0; size <= 4; size += 4) [r compute:ce tag:tag rec:at_guard(NULL, size) task:1];
    static const uint32_t compute_lists[] = {203, 204, 206};
    for (size_t i = 0; i < sizeof compute_lists / sizeof *compute_lists; i++) [r compute:ce tag:compute_lists[i] rec:at_guard(two, 8) task:1];
    [ce endEncoding];

    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    for (uint32_t tag = 300; tag < 320; tag++)
        for (uint32_t size = 0; size <= 4; size += 4) [r blit:be tag:tag rec:at_guard(NULL, size) task:1];
    [be endEncoding];

    for (uint32_t tag = 450; tag < 470; tag++)
        for (uint32_t size = 0; size <= 4; size += 4) [r info:tag rec:at_guard(NULL, size) task:1];
    [cb commit];
    [cb waitUntilCompleted];
    munmap(guard, page_size * 2);
    puts("short records: none read past its end");
}

/* A pipeline compiled off the worker: its first use waits for it and gets it; several compile side by side. */
static void test_pipelines_compiled_later(HvReplay *r) {
    id<MTLFunction> f = [r computeStandIn];
    if (!f) { check("a kernel to compile", 0); return; }
    enum { N = 6 };
    HvObject *objs[N];
    for (int i = 0; i < N; i++) {
        MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new];
        d.computeFunction = f;
        d.label = [NSString stringWithFormat:@"test %d", i]; /* each its own descriptor */
        objs[i] = [HvObject new];
        objs[i]->pending = [r compile:0xb descriptor:d name:@"test" failure:@"test pipeline"];
    }
    for (int i = 0; i < N; i++) {
        [r resolve:objs[i]];
        check("a pending pipeline resolves to a compute pipeline",
              objs[i]->pending == nil && [objs[i]->object conformsToProtocol:@protocol(MTLComputePipelineState)]);
    }
    [r flushPipelines];
    os_unfair_lock_lock(&r->pipe_lock);
    uint64_t made = r->pipes_compiled + r->pipes_hit;
    os_unfair_lock_unlock(&r->pipe_lock);
    check("each counted as compiled or found", made >= N);
    puts("pipelines: compiled off the worker, waited for at first use");
}

/* A two-plane video surface whose host copy is kept up to date from the guest's pages: what changed in the guest is
   copied, plane by plane, and a plane the guest left alone keeps what the host side has in it (the GPU drew it). */
static int plane_matches(IOSurfaceRef ios, uint32_t i, const uint8_t *guest, uint64_t row, size_t w_bytes, size_t rows) {
    IOSurfaceLock(ios, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *host = IOSurfaceGetBaseAddressOfPlane(ios, i);
    size_t host_row = IOSurfaceGetBytesPerRowOfPlane(ios, i);
    int same = 1;
    for (size_t y = 0; y < rows && same; y++) same = !memcmp(host + y * host_row, guest + y * row, w_bytes);
    IOSurfaceUnlock(ios, kIOSurfaceLockReadOnly, NULL);
    return same;
}

static void test_video_surface(HvReplay *r) {
    enum { W = 64, H = 32, ROW = 64, LUMA = ROW * H, CHROMA = ROW * (H / 2), ALLOC = LUMA + CHROMA, PAGES = 0x4000 };
    vm_address_t at = 0;
    if (vm_allocate(mach_task_self(), &at, PAGES, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) { check("guest pages", 0); return; }
    uint8_t *guest = (uint8_t *)at;
    for (int i = 0; i < ALLOC; i++) guest[i] = (uint8_t)(i * 7 + 3);
    HvObject *s = [HvObject new];
    s->mapped = guest, s->length = PAGES, s->first = 0, s->alloc = ALLOC;
    s->object = [r->device newBufferWithBytesNoCopy:guest length:PAGES options:MTLResourceStorageModeShared
                                        deallocator:^(void *p, NSUInteger n) { vm_deallocate(mach_task_self(), (vm_address_t)p, n); }];
    s->mapping_in_buffer = s->object != nil;
    s->plane_count = 2;
    s->plane_from[0] = 0, s->plane_row[0] = ROW, s->plane_h[0] = H;
    s->plane_from[1] = LUMA, s->plane_row[1] = ROW, s->plane_h[1] = H / 2;
    NSDictionary *planes[2] = {
        @{(__bridge id)kIOSurfacePlaneWidth: @W, (__bridge id)kIOSurfacePlaneHeight: @H, (__bridge id)kIOSurfacePlaneBytesPerRow: @ROW,
          (__bridge id)kIOSurfacePlaneOffset: @0, (__bridge id)kIOSurfacePlaneSize: @LUMA, (__bridge id)kIOSurfacePlaneBytesPerElement: @1},
        @{(__bridge id)kIOSurfacePlaneWidth: @(W / 2), (__bridge id)kIOSurfacePlaneHeight: @(H / 2), (__bridge id)kIOSurfacePlaneBytesPerRow: @ROW,
          (__bridge id)kIOSurfacePlaneOffset: @LUMA, (__bridge id)kIOSurfacePlaneSize: @CHROMA, (__bridge id)kIOSurfacePlaneBytesPerElement: @2},
    };
    NSDictionary *props = @{(__bridge id)kIOSurfaceWidth: @W, (__bridge id)kIOSurfaceHeight: @H, (__bridge id)kIOSurfacePixelFormat: @('420v'),
                            (__bridge id)kIOSurfaceAllocSize: @ALLOC, (__bridge id)kIOSurfacePlaneInfo: [NSArray arrayWithObjects:planes count:2]};
    s->iosurface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!s->iosurface || IOSurfaceGetPlaneCount(s->iosurface) != 2) { check("a two-plane IOSurface", 0); return; }

    id<MTLCommandBuffer> cb = [r->queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = nil;
    BOOL by_gpu = [r syncSurface:s blit:&blit commandBuffer:cb];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    check("luma copied", plane_matches(s->iosurface, 0, guest, ROW, W, H));
    check("chroma copied", plane_matches(s->iosurface, 1, guest + LUMA, ROW, W, H / 2));

    /* The host side draws into luma; the guest changes chroma only. */
    IOSurfaceLock(s->iosurface, 0, NULL);
    memset(IOSurfaceGetBaseAddressOfPlane(s->iosurface, 0), 0xab, IOSurfaceGetBytesPerRowOfPlane(s->iosurface, 0) * H);
    IOSurfaceUnlock(s->iosurface, 0, NULL);
    for (int i = LUMA; i < ALLOC; i++) guest[i] ^= 0x5a;
    cb = [r->queue commandBuffer];
    blit = nil;
    [r syncSurface:s blit:&blit commandBuffer:cb];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    check("the changed plane copied again", plane_matches(s->iosurface, 1, guest + LUMA, ROW, W, H / 2));
    IOSurfaceLock(s->iosurface, kIOSurfaceLockReadOnly, NULL);
    check("the other plane kept what the host drew", ((const uint8_t *)IOSurfaceGetBaseAddressOfPlane(s->iosurface, 0))[5] == 0xab);
    IOSurfaceUnlock(s->iosurface, kIOSurfaceLockReadOnly, NULL);
    check("nothing changed: nothing copied", ![r syncSurface:s blit:&blit commandBuffer:nil] && blit == nil);
    printf("video surface: planes copied as the guest changed them (%s)\n", by_gpu ? "by the GPU" : "by the CPU: no GPU copy here");
}

/* The screen scaled into a target of ow x oh pixels, read back (BGRA). */
static uint8_t *scaled(HvReplay *r, id<MTLTexture> src, uint32_t ow, uint32_t oh, HvFit *fit_out) {
    HvFit fit = screen_fit(ow, oh, (uint32_t)src.width, (uint32_t)src.height);
    *fit_out = fit;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:ow height:oh mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> out = [r->device newTextureWithDescriptor:td];
    id<MTLBuffer> rb = [r->device newBufferWithLength:(NSUInteger)ow * oh * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [r->queue commandBuffer];
    id<MTLRenderCommandEncoder> e = [r drawScreen:src half:NO fit:fit into:out commandBuffer:cb];
    [e endEncoding];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:out sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(ow, oh, 1)
              toBuffer:rb destinationOffset:0 destinationBytesPerRow:(NSUInteger)ow * 4 destinationBytesPerImage:(NSUInteger)ow * oh * 4];
    [b endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    uint8_t *px = malloc((size_t)ow * oh * 4);
    memcpy(px, rb.contents, (size_t)ow * oh * 4);
    return px;
}

static id<MTLTexture> picture(HvReplay *r, uint32_t w, uint32_t h, uint32_t (^bgra)(uint32_t x, uint32_t y)) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [r->device newTextureWithDescriptor:td];
    uint32_t *px = malloc((size_t)w * h * 4);
    for (uint32_t y = 0; y < h; y++)
        for (uint32_t x = 0; x < w; x++) px[y * w + x] = bgra(x, y) | 0xff000000u;
    [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:px bytesPerRow:w * 4];
    free(px);
    return t;
}

static uint32_t at(const uint8_t *px, uint32_t ow, uint32_t x, uint32_t y) { uint32_t v; memcpy(&v, px + ((size_t)y * ow + x) * 4, 4); return v; }

/* Black where the picture is not: the columns left and right of it (or rows above and below). */
static int bars_black(const uint8_t *px, uint32_t ow, uint32_t oh, HvFit f) {
    for (uint32_t y = 0; y < oh; y++)
        for (uint32_t x = 0; x < ow; x++) {
            BOOL inside = x >= f.x && x < f.x + f.w && y >= f.y && y < f.y + f.h;
            if (!inside && at(px, ow, x, y) != 0xff000000u) return 0;
        }
    return 1;
}

/* Every channel of the picture's pixels between lo and hi. */
static int picture_within(const uint8_t *px, uint32_t ow, HvFit f, int lo, int hi) {
    for (uint32_t y = f.y; y < f.y + f.h; y++)
        for (uint32_t x = f.x; x < f.x + f.w; x++)
            for (int c = 0; c < 3; c++) {
                int v = px[((size_t)y * ow + x) * 4 + c];
                if (v < lo || v > hi) return 0;
            }
    return 1;
}

static void test_scaler(HvReplay *r) {
    if (![r makeScreenPipelines]) { check("screen pipelines", 0); return; }
    HvFit f;
    /* 2x: every Mac pixel exactly 2x2, centred between black bars where the target is wider. */
    id<MTLTexture> colours = picture(r, 6, 4, ^uint32_t(uint32_t x, uint32_t y) { return (x * 40 + 7) | (y * 60 + 11) << 8 | ((x ^ y) * 30) << 16; });
    uint8_t *px = scaled(r, colours, 16, 8, &f);
    check("2x: a whole factor, exact", f.mode == FIT_EXACT && f.w == 12 && f.h == 8);
    check("2x: centred", f.x == 2 && f.y == 0 && bars_black(px, 16, 8, f));
    int exact = 1;
    for (uint32_t y = 0; y < 8; y++)
        for (uint32_t x = 0; x < 12; x++) {
            uint32_t want = ((x / 2) * 40 + 7) | ((y / 2) * 60 + 11) << 8 | (((x / 2) ^ (y / 2)) * 30) << 16 | 0xff000000u;
            if (at(px, 16, f.x + x, y) != want) exact = 0;
        }
    check("2x: each pixel the Mac's own", exact);
    free(px);
    /* 1.4x: a flat picture stays flat; a step does not ring (no halo past its two sides); centred. */
    id<MTLTexture> grey = picture(r, 10, 10, ^uint32_t(uint32_t x, uint32_t y) { return 0x808080u; });
    px = scaled(r, grey, 20, 14, &f);
    check("1.4x: enlarged, sharpened", f.mode == FIT_SHARP && f.w == 14 && f.h == 14);
    check("1.4x: centred", f.x == 3 && f.y == 0 && bars_black(px, 20, 14, f));
    check("1.4x: flat stays flat", picture_within(px, 20, f, 127, 129));
    free(px);
    id<MTLTexture> step = picture(r, 10, 10, ^uint32_t(uint32_t x, uint32_t y) { return x < 5 ? 0x404040u : 0xc0c0c0u; });
    px = scaled(r, step, 14, 14, &f);
    check("1.4x: no ringing at an edge", picture_within(px, 14, f, 0x40 - 1, 0xc0 + 1));
    int rising = 1;
    for (uint32_t x = 1; x < 14; x++) rising &= px[(7 * 14 + x) * 4] >= px[(7 * 14 + x - 1) * 4];
    check("1.4x: an edge rises without a dip", rising);
    free(px);
    /* 0.75x: a 1-pixel checkerboard averages out instead of aliasing; centred. */
    id<MTLTexture> checker = picture(r, 16, 16, ^uint32_t(uint32_t x, uint32_t y) { return (x ^ y) & 1 ? 0xffffffu : 0; });
    px = scaled(r, checker, 16, 12, &f);
    check("0.75x: shrunk", f.mode == FIT_SHRINK && f.w == 12 && f.h == 12);
    check("0.75x: centred", f.x == 2 && f.y == 0 && bars_black(px, 16, 12, f));
    check("0.75x: averaged", picture_within(px, 16, f, 64, 192));
    free(px);
    puts("scaler: 2x exact, 1.4x sharp without ringing, 0.75x averaged, all centred");
}

int main(void) {
    alarm(120);
    @autoreleasepool {
        test_archive_room();
        HvPvgMetal *m = hv_pvg_metal_create(NULL);
        if (!m) { puts("no Metal device"); return 1; }
        HvReplay *r = (__bridge HvReplay *)m;
        dispatch_sync(r->worker, ^{ test_short_records(r); });
        dispatch_sync(r->worker, ^{ test_pipelines_compiled_later(r); });
        dispatch_sync(r->worker, ^{ test_video_surface(r); });
        test_scaler(r);
        hv_pvg_metal_destroy(m);
    }
    if (failures) printf("%d failures\n", failures);
    return failures != 0;
}
