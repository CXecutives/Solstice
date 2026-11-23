/* The Metal replay's own parts, with devices/pvg_metal.m compiled into this test so its static functions and HvReplay's
   methods can be called directly. Needs a Metal device (any Mac, CI's virtual one included). */
#define HV_PVG_READ_ONCE 1 /* a record field read twice in one handler is counted (read_twice) */
#include "../devices/pvg_metal.m"
#include <sys/mman.h>
#include <mach/mach_vm.h>

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

static BOOL complained(HvReplay *r, NSString *prefix);
static HvObject *put_object(HvReplay *r, uint32_t ref, id made);
static void drop_object(HvReplay *r, uint32_t ref);

static void test_short_records(HvReplay *r) {
    page_size = (size_t)getpagesize();
    guard = mmap(NULL, page_size * 2, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (guard == MAP_FAILED || mprotect(guard + page_size, page_size, PROT_NONE)) { check("guard page", 0); return; }
    /* Every field 1: a ref that names a real object (a buffer), so lookups succeed and handlers go on to read the rest,
       and a count of one list entry. Every tag at every size from 0 to past what it needs (a list's entry more), each
       record ending at the guard. No encoder or command buffer: what is read is the point, and a message to nil still
       has its arguments read; a pipeline counts as set so draws read their fields too. */
    put_object(r, 1, [r->device newBufferWithLength:64 options:MTLResourceStorageModeShared]);
    uint32_t ones[0x260 / 4];
    for (size_t i = 0; i < sizeof ones / 4; i++) ones[i] = 1;
    for (uint32_t size = 0; size <= 0x250; size += 4) [r beginPass:at_guard(ones, size) task:1 commandBuffer:nil];
    for (uint32_t tag = 0; tag < 200; tag++)
        for (uint32_t size = 0; size <= 64; size++) {
            r->pipeline_set = YES, r->tess_factors = YES;
            [r render:nil tag:tag rec:at_guard(ones, size) task:1];
        }
    for (uint32_t tag = 200; tag < 230; tag++)
        for (uint32_t size = 0; size <= 64; size++) {
            r->pipeline_set = YES;
            [r compute:nil tag:tag rec:at_guard(ones, size) task:1];
        }
    for (uint32_t tag = 300; tag < 320; tag++)
        for (uint32_t size = 0; size <= 0x60; size++) [r blit:nil tag:tag rec:at_guard(ones, size) task:1];
    for (uint32_t tag = 450; tag < 470; tag++)
        for (uint32_t size = 0; size <= 0x40; size++) [r info:tag rec:at_guard(ones, size) task:1];
    r->pipeline_set = r->tess_factors = NO;
    drop_object(r, 1);
    /* The records are in memory the guest shares: a field read twice could change in between (an index checked, then
       another used). */
    check("no record field read twice in one handler", read_twice == 0);

    /* Object entries too short for their makers: serialized objects (sampler, depth-stencil with both sides, fence,
       pipelines, unknown) and textures (both description forms). */
    static const uint32_t serialized_tags[] = {3, 4, 0xd, 0xe, 0xb, 0x33, 99};
    for (size_t i = 0; i < sizeof serialized_tags / sizeof *serialized_tags; i++)
        for (uint32_t size = 0; size <= 40; size++) {
            uint32_t w[10] = {serialized_tags[i], size, 1, 0x30}; /* 0x30: both stencil sides; as a pipeline's data length, too long */
            Rec rec = at_guard(w, size);
            @autoreleasepool { [r serialized:[NSData dataWithBytesNoCopy:(void *)rec.p length:size freeWhenDone:NO] task:1]; }
        }
    check("a 27-byte sampler refused", complained(r, @"serialized object tag 3: 27 bytes"));
    check("a depth-stencil with both sides in 39 bytes refused", complained(r, @"depth-stencil flags 30 in 39 bytes"));
    for (uint32_t form = 0; form < 2; form++)
        for (uint32_t size = 0; size < 12 + 0x18 + 12 + (form ? DESCRIPTOR_V2 : DESCRIPTOR_V1); size++) {
            uint8_t bytes[12 + 0x18 + 12 + DESCRIPTOR_V2] = {0};
            bytes[12 + 0x18] = form ? 0x34 : 0x14; /* the description's tag: which form it is */
            Rec rec = at_guard(bytes, size);
            HvObject *o = [HvObject new];
            [r makeTexture:o from:rec.p size:size];
            check("a texture entry too short: nothing made", o->object == nil);
        }
    munmap(guard, page_size * 2);
    puts("short records: none read past its end");
}

/* An object under ref in task 1, as if made from the guest's list (object: finds it there when there is no guest). */
static HvObject *put_object(HvReplay *r, uint32_t ref, id made) {
    HvObject *o = [HvObject new];
    o->object = made;
    *obj_slot(&r->task_objs[1], ref, YES) = o;
    return o;
}

static void drop_object(HvReplay *r, uint32_t ref) { *obj_slot(&r->task_objs[1], ref, YES) = nil; }

static BOOL complained(HvReplay *r, NSString *prefix) {
    @synchronized(r->complaints) {
        for (NSString *c in r->complaints)
            if ([c hasPrefix:prefix]) return YES;
    }
    return NO;
}

/* Where the guest asks for an answer to be written: an offset near 2^64 wraps past the length check and wrote before
   the mapping. Here an unreadable page is right before it, so such a write crashes this test. */
static void test_offsets_do_not_wrap(HvReplay *r) {
    size_t ps = (size_t)getpagesize();
    uint8_t *m = mmap(NULL, ps * 2, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (m == MAP_FAILED || mprotect(m, ps, PROT_NONE)) { check("guard page", 0); return; }
    HvObject *answers = put_object(r, 9, [r->device newBufferWithLength:64 options:MTLResourceStorageModeShared]);
    answers->mapped = m + ps, answers->length = ps, answers->checked = r->walk_epoch; /* the guest's pages, current */
    put_object(r, 10, [r->device newBufferWithLength:64 options:MTLResourceStorageModeShared]);
    uint64_t wrap = UINT64_MAX - 7;
    uint8_t rec[0x2c] = {0};
    uint32_t ten = 10, nine = 9;
    memcpy(rec, &ten, 4), memcpy(rec + 4, &nine, 4), memcpy(rec + 8, &wrap, 8);
    [r info:461 rec:(Rec){rec, 16} task:1];
    check("info 461 at an offset that wraps: refused", complained(r, @"info 461: ref 10 buffer 9"));
    memset(rec, 0, sizeof rec);
    memcpy(rec, &ten, 4), memcpy(rec + 8, &nine, 4), memcpy(rec + 12, &wrap, 8);
    [r info:460 rec:(Rec){rec, 20} task:1];
    check("info 460 at an offset that wraps: refused", complained(r, @"info 460: ref 10 buffer 9"));
    memset(rec, 0, sizeof rec);
    memcpy(rec + 0x20, &nine, 4), memcpy(rec + 0x24, &wrap, 8);
    [r info:451 rec:(Rec){rec, 0x2c} task:1];
    check("a heap size query at an offset that wraps: refused", complained(r, @"heap size query: no buffer"));
    memset(rec, 0, sizeof rec);
    memcpy(rec, &nine, 4), memcpy(rec + 4, &wrap, 8);
    [r render:nil tag:164 rec:(Rec){rec, 12} task:1]; /* writes the tile size, if it fits */
    check("nothing written before the mapping", 1);
    answers->mapped = NULL;
    drop_object(r, 9), drop_object(r, 10);
    munmap(m, ps * 2);
    puts("answer offsets: one that wraps is refused");
}

/* A render pass on a small target of its own, for records that need an encoder. */
static id<MTLRenderCommandEncoder> small_pass(HvReplay *r, id<MTLCommandBuffer> cb) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = [r->device newTextureWithDescriptor:td];
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    return [cb renderCommandEncoderWithDescriptor:pass];
}

/* A ref names any object: a buffer where a pipeline or a depth-stencil state goes is refused, not handed to Metal. */
static void test_wrong_kind_refused(HvReplay *r) {
    put_object(r, 11, [r->device newBufferWithLength:64 options:MTLResourceStorageModeShared]);
    uint32_t ref = 11;
    id<MTLCommandBuffer> cb = [r->queue commandBuffer];
    id<MTLRenderCommandEncoder> re = small_pass(r, cb);
    r->pipeline_set = YES;
    [r render:re tag:116 rec:(Rec){(const uint8_t *)&ref, 4} task:1];
    check("a buffer as a render pipeline: refused", !r->pipeline_set && complained(r, @"object 11 is a"));
    [r render:re tag:104 rec:(Rec){(const uint8_t *)&ref, 4} task:1];
    [re endEncoding];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    r->pipeline_set = YES;
    [r compute:ce tag:208 rec:(Rec){(const uint8_t *)&ref, 4} task:1];
    check("a buffer as a compute pipeline: refused", !r->pipeline_set);
    [ce endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    check("the command buffer still runs", cb.status == MTLCommandBufferStatusCompleted);
    /* An answer about a render pipeline (info 457) for a ref that is a buffer. */
    uint8_t *page = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    HvObject *answers = put_object(r, 9, [r->device newBufferWithLength:64 options:MTLResourceStorageModeShared]);
    answers->mapped = page, answers->length = 0x4000, answers->checked = r->walk_epoch;
    uint32_t q[4] = {11, 9, 0, 0};
    [r info:457 rec:(Rec){(const uint8_t *)q, 16} task:1];
    check("asked about a buffer as a render pipeline: refused", complained(r, @"info 457: object 11 is a"));
    answers->mapped = NULL;
    munmap(page, 0x4000);
    drop_object(r, 9);
    drop_object(r, 11);
    puts("wrong kinds: a buffer named as a pipeline or a state is refused");
}

/* 64 scissor rectangles or viewports in one record: Metal takes 16, and copied all 64 into its table of 16. */
static void test_many_viewports(HvReplay *r) {
    check("64 rectangles: 16 set", viewport_count(8 + 64 * sizeof(MTLScissorRect), sizeof(MTLScissorRect)) == VIEWPORT_SLOTS);
    check("64 viewports: 16 set", viewport_count(64 * sizeof(MTLViewport), sizeof(MTLViewport)) == VIEWPORT_SLOTS);
    check("3 rectangles: 3", viewport_count(8 + 3 * sizeof(MTLScissorRect), sizeof(MTLScissorRect)) == 3);
    enum { N = 64 };
    uint8_t rects[8 + N * sizeof(MTLScissorRect)] = {0};
    for (int i = 0; i < N; i++) {
        MTLScissorRect s = {0, 0, 16, 16};
        memcpy(rects + 8 + i * sizeof s, &s, sizeof s);
    }
    MTLViewport views[N];
    for (int i = 0; i < N; i++) views[i] = (MTLViewport){0, 0, 16, 16, 0, 1};
    id<MTLCommandBuffer> cb = [r->queue commandBuffer];
    id<MTLRenderCommandEncoder> re = small_pass(r, cb);
    [r render:re tag:118 rec:(Rec){rects, sizeof rects} task:1];
    [r render:re tag:131 rec:(Rec){(const uint8_t *)views, sizeof views} task:1];
    [re endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    check("and the pass runs", cb.status == MTLCommandBufferStatusCompleted);
    puts("viewports: at most 16 handed to Metal");
}

/* The saved pipelines, in a folder of this test's own (the replay itself was made with them off, HV_PVG_ARCHIVE=0, so
   the test never touches the real one): another build's file goes, a compiled pipeline is saved to a new file, and the
   next start loads it. */
static void test_archive_files(HvReplay *r) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString] isDirectory:YES];
    [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *stray = [dir URLByAppendingPathComponent:@"pipelines-another-build-1.bin"];
    [@"x" writeToURL:stray atomically:NO encoding:NSUTF8StringEncoding error:nil];
    [r openArchiveIn:dir reset:NO];
    check("another build's file removed", ![fm fileExistsAtPath:stray.path]);
    if (!r->archive) {
        puts("saved pipelines: no binary archives on this GPU, files not checked");
        [fm removeItemAtURL:dir error:nil];
        return;
    }
    MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new];
    d.computeFunction = [r computeStandIn];
    d.label = @"archive test";
    HvObject *o = [HvObject new];
    o->pending = [r compile:0xb descriptor:d name:nil failure:@"archive test pipeline"];
    [r resolve:o];
    [r flushPipelines];
    NSUInteger saved = r->archives.count;
    check("compiled, then saved to a file of its own", saved == 1 && [fm contentsOfDirectoryAtPath:dir.path error:nil].count == 1);
    r->archive = nil, r->archives = nil, r->archive_next = 0, r->archive_bytes = 0, r->archive_full = NO;
    [r openArchiveIn:dir reset:NO];
    check("the next start loads it", r->archives.count == saved);
    r->archive = nil, r->archives = nil, r->archive_dir = nil; /* nothing more goes to the folder */
    [fm removeItemAtURL:dir error:nil];
    puts("saved pipelines: files in their folder made, kept and loaded");
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
        @{(__bridge id)kIOSurfacePlaneWidth: @(W), (__bridge id)kIOSurfacePlaneHeight: @(H), (__bridge id)kIOSurfacePlaneBytesPerRow: @(ROW),
          (__bridge id)kIOSurfacePlaneOffset: @0, (__bridge id)kIOSurfacePlaneSize: @(LUMA), (__bridge id)kIOSurfacePlaneBytesPerElement: @1},
        @{(__bridge id)kIOSurfacePlaneWidth: @(W / 2), (__bridge id)kIOSurfacePlaneHeight: @(H / 2), (__bridge id)kIOSurfacePlaneBytesPerRow: @(ROW),
          (__bridge id)kIOSurfacePlaneOffset: @(LUMA), (__bridge id)kIOSurfacePlaneSize: @(CHROMA), (__bridge id)kIOSurfacePlaneBytesPerElement: @2},
    };
    NSDictionary *props = @{(__bridge id)kIOSurfaceWidth: @(W), (__bridge id)kIOSurfaceHeight: @(H), (__bridge id)kIOSurfacePixelFormat: @('420v'),
                            (__bridge id)kIOSurfaceAllocSize: @(ALLOC), (__bridge id)kIOSurfacePlaneInfo: [NSArray arrayWithObjects:planes count:2]};
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
    blit = nil;
    check("nothing changed: nothing copied", ![r syncSurface:s blit:&blit commandBuffer:nil] && blit == nil);
    /* A small change, 16 bytes of one luma row (a pointer, a subtitle): still a new frame. */
    for (int i = 0; i < 16; i++) guest[3 * ROW + i] ^= 0xff;
    [r syncSurface:s blit:&blit commandBuffer:nil];
    check("16 bytes changed in one row: copied", plane_matches(s->iosurface, 0, guest, ROW, W, H));
    printf("video surface: planes copied as the guest changed them (%s)\n", by_gpu ? "by the GPU" : "by the CPU: no GPU copy here");
}

/* Guest memory for the remap tests: four 16 KB pages, numbered from 1, and a task table naming them. */
static uint8_t *fake_ram;
static uint32_t fake_table[4];
static void fake_task_pages(HvPvgLite *l, uint32_t task, uint64_t first, uint64_t n, uint32_t *out) {
    for (uint64_t i = 0; i < n; i++) out[i] = first + i < 4 ? fake_table[first + i] : 0;
}
static uint8_t *fake_page(HvPvgLite *l, uint32_t page) { return page >= 1 && page <= 4 ? fake_ram + (uint64_t)(page - 1) * 0x4000 : NULL; }

static BOOL still_mapped(const void *p) {
    mach_vm_address_t a = (mach_vm_address_t)(uintptr_t)p;
    mach_vm_size_t size;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object;
    if (mach_vm_region(mach_task_self(), &a, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object) != KERN_SUCCESS) return NO;
    return a <= (mach_vm_address_t)(uintptr_t)p;
}

static NSString *const told_kernel = @"#include <metal_stdlib>\n"
                                      "using namespace metal;\n"
                                      "struct Told { device const uint *p; };\n"
                                      "kernel void read_told(device const Told &t [[buffer(0)]], device uint *out [[buffer(1)]]) { out[0] = t.p[0]; }\n";

/* The word at a GPU address, read by a kernel through an argument buffer as the guest's shaders do; the command
   buffer's status in *ok. The resources made resident are what useResources (render 135/137) would name for o. */
static uint32_t read_on_gpu(HvReplay *r, uint64_t address, HvObject *o, BOOL *ok) {
    NSError *err = nil;
    id<MTLLibrary> lib = [r->device newLibraryWithSource:told_kernel options:nil error:&err];
    id<MTLComputePipelineState> ps = lib ? [r->device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"read_told"] error:&err] : nil;
    if (!ps) { printf("  kernel: %s\n", err.localizedDescription.UTF8String); *ok = NO; return 0; }
    id<MTLBuffer> args = [r->device newBufferWithBytes:&address length:8 options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [r->device newBufferWithLength:4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [r->queue commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps];
    [ce setBuffer:args offset:0 atIndex:0];
    [ce setBuffer:out offset:0 atIndex:1];
    __unsafe_unretained id<MTLResource> items[8];
    uint32_t n = with_retired(o, o->object, items, 0, 8);
    [ce useResources:items count:n usage:MTLResourceUsageRead];
    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [ce endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    *ok = cb.status == MTLCommandBufferStatusCompleted;
    if (!*ok) printf("  kernel: %s\n", cb.error.localizedDescription.UTF8String);
    return *(const uint32_t *)out.contents;
}

/* A buffer whose GPU address the guest was told (info 461) and wrote into its argument buffers, and then the guest's
   pages under it changed (refresh_pages makes a new buffer at a new address). The guest still reads through the old
   address: that buffer has to stay, with its pages, until the guest frees the object. Before, it was let go at once
   and the next shader reading through it faulted the GPU, which then ignored every command buffer (iPad Air 4). */
static void test_told_buffer_outlives_remap(HvReplay *r) {
    vm_address_t ram = 0;
    if (vm_allocate(mach_task_self(), &ram, 4 * 0x4000, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) { check("guest pages", 0); return; }
    fake_ram = (uint8_t *)ram;
    ((uint32_t *)fake_page(NULL, 1))[0] = 0x5eed0001;
    ((uint32_t *)fake_page(NULL, 2))[0] = 0x5eed0002;
    void (*pages_before)(HvPvgLite *, uint32_t, uint64_t, uint64_t, uint32_t *) = r->task_pages;
    uint8_t *(*page_before)(HvPvgLite *, uint32_t) = r->guest_page;
    r->task_pages = fake_task_pages, r->guest_page = fake_page;
    fake_table[0] = 1;
    uint64_t kept_before = atomic_load(&retired_bytes_live);
    HvObject *o = [HvObject new];
    o->length = 0x4000, o->vpage = 0;
    new_command(r);
    if (!map_pages(r, 1, o)) { check("mapped", 0); return; }
    o->plain_buffer = YES;
    o->object = buffer_over_mapping(r, o);
    *obj_slot(&r->task_objs[1], 7, YES) = o;
    uint64_t told = [(id<MTLBuffer>)o->object gpuAddress];
    const uint8_t *old_mapping = o->mapped;
    mark_told(o); /* what info 460...463 do */
    @autoreleasepool {
        fake_table[0] = 2;
        new_command(r);
        refresh_pages(r, 1, o);
    }
    check("new pages: a new buffer over them", o->mapped != old_mapping && [(id<MTLBuffer>)o->object contents] == o->mapped);
    check("the new buffer reads the new page", *(const uint32_t *)o->mapped == 0x5eed0002);
    check("the told buffer's mapping is still there", still_mapped(old_mapping));
    check("its bytes counted", atomic_load(&retired_bytes_live) == kept_before + 0x4000);
    if ([r->device supportsFamily:MTLGPUFamilyMetal3]) {
        BOOL ok = NO;
        uint32_t v;
        @autoreleasepool { v = read_on_gpu(r, told, o, &ok); }
        check("a shader reading through the told address: no GPU fault", ok);
        check("and it reads what was there (stale, not garbage)", v == 0x5eed0001);
    } else puts("  (no Metal 3 GPU here: the told address is not read on the GPU)");
    @autoreleasepool { /* the guest frees it (op 0x25) */
        *obj_slot(&r->task_objs[1], 7, NO) = nil;
        o = nil;
    }
    check("freed by the guest: what was kept goes too", atomic_load(&retired_bytes_live) == kept_before);
    r->task_pages = pages_before, r->guest_page = page_before;
    puts("remap: a buffer whose address the guest has is kept until the guest frees it");
}

/* After a GPU fault the queue's context ignores everything: recoverGPU draws on a new queue with objects made again,
   keeps what the guest has addresses of, and gives up after GPU_RECOVERIES in a minute. */
static void test_gpu_recovery(HvReplay *r) {
    double times[GPU_RECOVERIES] = {0};
    BOOL fits = YES;
    for (int i = 0; i < GPU_RECOVERIES; i++) fits &= recovery_allowed(times, 100 + i);
    check("a few recoveries a minute", fits);
    check("one more in that minute: no", !recovery_allowed(times, 100 + GPU_RECOVERIES));
    check("a minute after the first: one more", recovery_allowed(times, 160.5));
    NSError *fault = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorPageFault userInfo:nil];
    NSError *ignored = [NSError errorWithDomain:@"IOGPU" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Ignored (for causing prior/excessive GPU errors) (00000004:kIOGPUCommandBufferCallbackErrorSubmissionsIgnored)"}];
    NSError *other = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorTimeout userInfo:nil];
    check("a page fault loses the context", gpu_context_lost(fault));
    check("so does 'submissions ignored'", gpu_context_lost(ignored));
    check("a timeout or no error does not", !gpu_context_lost(other) && !gpu_context_lost(nil));

    id<MTLCommandQueue> before = r->queue;
    uint32_t generation = atomic_load(&r->queue_generation);
    HvObject *plain = [HvObject new], *told = [HvObject new];
    plain->object = [r->device newBufferWithLength:64 options:MTLResourceStorageModeShared];
    told->object = [r->device newBufferWithLength:64 options:MTLResourceStorageModeShared];
    mark_told(told);
    *obj_slot(&r->task_objs[2], 3, YES) = plain;
    *obj_slot(&r->task_objs[2], 4, YES) = told;
    [r recoverGPU:1000];
    check("not poisoned: nothing done", r->queue == before && obj_known(r, 2, 3) == plain);
    atomic_store(&r->gpu_poisoned, 1);
    [r recoverGPU:1000];
    check("poisoned: a new queue", r->queue != before && atomic_load(&r->queue_generation) == generation + 1 && !atomic_load(&r->gpu_poisoned));
    check("objects made again at next use", obj_known(r, 2, 3) == nil && obj_known(r, 2, 4) == nil);
    check("one whose address the guest has is kept", [r->told_kept[2] containsObject:told] && ![r->told_kept[2] containsObject:plain]);
    /* Draws again: a fill on the new queue comes back. */
    id<MTLBuffer> b = [r->device newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [r->queue commandBuffer];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be fillBuffer:b range:NSMakeRange(0, 16) value:0x7e];
    [be endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    check("the new queue draws", cb.status == MTLCommandBufferStatusCompleted && ((const uint8_t *)b.contents)[15] == 0x7e);
    /* Fails over and over: after GPU_RECOVERIES in a minute it stays down. */
    for (int i = 1; i <= GPU_RECOVERIES; i++) {
        atomic_store(&r->gpu_poisoned, 1);
        [r recoverGPU:1000 + i];
    }
    id<MTLCommandQueue> last = r->queue;
    check("too many in a minute: down", r->gpu_down);
    atomic_store(&r->gpu_poisoned, 1);
    [r recoverGPU:5000];
    check("and it stays down", r->queue == last);
    r->gpu_down = NO;
    memset(r->recoveries, 0, sizeof r->recoveries);
    r->told_kept[2] = nil;
    puts("GPU recovery: a new queue, objects made again, told ones kept, at most a few a minute");
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
        setenv("HV_PVG_ARCHIVE", "0", 1); /* not the saved pipelines of whoever runs this: test_archive_files has its own */
        HvPvgMetal *m = hv_pvg_metal_create(NULL);
        unsetenv("HV_PVG_ARCHIVE");
        if (!m) { puts("no Metal device"); return 1; }
        HvReplay *r = (__bridge HvReplay *)m;
        dispatch_sync(r->worker, ^{ test_short_records(r); });
        dispatch_sync(r->worker, ^{ test_offsets_do_not_wrap(r); });
        dispatch_sync(r->worker, ^{ test_wrong_kind_refused(r); });
        dispatch_sync(r->worker, ^{ test_many_viewports(r); });
        dispatch_sync(r->worker, ^{ test_pipelines_compiled_later(r); });
        dispatch_sync(r->worker, ^{ test_archive_files(r); });
        dispatch_sync(r->worker, ^{ test_video_surface(r); });
        dispatch_sync(r->worker, ^{ test_told_buffer_outlives_remap(r); });
        dispatch_sync(r->worker, ^{ test_gpu_recovery(r); });
        test_scaler(r);
        hv_pvg_metal_destroy(m);
    }
    if (failures) printf("%d failures\n", failures);
    return failures != 0;
}
