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
        hv_pvg_metal_destroy(m);
    }
    if (failures) printf("%d failures\n", failures);
    return failures != 0;
}
