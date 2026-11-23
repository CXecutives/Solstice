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

int main(void) {
    alarm(120);
    @autoreleasepool {
        test_archive_room();
        HvPvgMetal *m = hv_pvg_metal_create(NULL);
        if (!m) { puts("no Metal device"); return 1; }
        HvReplay *r = (__bridge HvReplay *)m;
        dispatch_sync(r->worker, ^{ test_short_records(r); });
        hv_pvg_metal_destroy(m);
    }
    if (failures) printf("%d failures\n", failures);
    return failures != 0;
}
