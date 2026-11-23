/* Surfaces (the guest's IOSurfaces), their host copies and the textures over them (part of pvg_metal.m). */

/* A multi-plane surface as a real IOSurface, laid out as the guest laid it out.
   Planes are in the descriptor from +0x80, 0x80 apart: offset +8, size +0x18,
   width +0x20, height +0x28, row +0x30, bytes per element +0x38. */
/* compact: macOS 14's description, 0x40 bytes of header then 0x40 a plane: offset +0x0c, size +0x10, width and height
   << 8 at +0x14 and +0x18, row +0x1c, bytes per element +0x20 (x420 3840x2160: luma at 0x200, 8000-byte rows, 2 bytes;
   chroma at 0x1194400, 1920x1080, 4 bytes). The plane count is the u32 at +0x24. */
static void read_plane(const uint8_t *desc, BOOL compact, uint32_t i, uint64_t *o_off, uint64_t *o_size, uint64_t *o_w, uint64_t *o_h,
                       uint64_t *o_row, uint16_t *o_bpe) {
    const uint8_t *pl = desc + 0x80 + i * 0x80;
    uint64_t off, size, w, h, row;
    uint16_t bpe;
    if (compact) {
        const uint8_t *cp = desc + 0x40 + i * 0x40;
        uint32_t v[6], base;
        memcpy(v, cp + 0x0c, sizeof v); /* offset, size, width << 8, height << 8, row, bytes per element */
        off = v[0], size = v[1], w = v[2] >> 8, h = v[3] >> 8, row = v[4], bpe = (uint16_t)v[5];
        /* +0x08: where the plane's first visible pixel is. A video decoder's buffers carry extended pixels
           around the picture (Sonoma's 10-bit HEVC: 96 columns and 71 rows before it), and the guest's
           GPU reads the plane from there; from the allocation's start, every converted frame came out
           moved right and down with a green band at the top and left (the menu bar and left strip). */
        memcpy(&base, cp + 0x08, 4);
        if (base > off && base - off < size) size -= base - off, off = base;
    } else
    memcpy(&off, pl + 8, 8), memcpy(&size, pl + 0x18, 8), memcpy(&w, pl + 0x20, 8), memcpy(&h, pl + 0x28, 8), memcpy(&row, pl + 0x30, 8), memcpy(&bpe, pl + 0x38, 2);
    *o_off = off, *o_size = size, *o_w = w, *o_h = h, *o_row = row, *o_bpe = bpe;
}

static uint32_t plane_count(const uint8_t *desc, BOOL compact) {
    uint32_t planes = desc[0x3e];
    if (compact) memcpy(&planes, desc + 0x24, 4);
    return planes;
}

/* Where each plane is in the guest's memory, without making anything. */
static void plane_layout(HvObject *to, const uint8_t *desc, BOOL compact) {
    uint32_t planes = plane_count(desc, compact);
    for (uint32_t i = 0; i < planes && i < 4; i++) {
        uint64_t off, size, w, h, row;
        uint16_t bpe;
        read_plane(desc, compact, i, &off, &size, &w, &h, &row, &bpe);
        to->plane_from[i] = off, to->plane_row[i] = row, to->plane_h[i] = h;
    }
    to->plane_count = MIN(planes, 4u);
}

static IOSurfaceRef make_iosurface(HvObject *to, const uint8_t *desc, uint64_t alloc, BOOL compact) {
    uint32_t fourcc, planes = plane_count(desc, compact);
    uint64_t width, height;
    memcpy(&fourcc, desc + 4, 4), memcpy(&width, desc + 0x20, 8), memcpy(&height, desc + 0x28, 8);
    if (compact) {
        uint32_t w32, h32;
        memcpy(&w32, desc + 0x14, 4), memcpy(&h32, desc + 0x18, 4);
        width = w32 >> 8, height = h32 >> 8;
    }
    NSMutableArray *info = [NSMutableArray new], *plain = [NSMutableArray new];
    uint64_t at = 0;
    for (uint32_t i = 0; i < planes && i < 4; i++) {
        uint64_t off, size, w, h, row;
        uint16_t bpe;
        read_plane(desc, compact, i, &off, &size, &w, &h, &row, &bpe);
        [info addObject:@{(__bridge id)kIOSurfacePlaneWidth: @(w), (__bridge id)kIOSurfacePlaneHeight: @(h), (__bridge id)kIOSurfacePlaneBytesPerRow: @(row),
                          (__bridge id)kIOSurfacePlaneOffset: @(off), (__bridge id)kIOSurfacePlaneSize: @(size), (__bridge id)kIOSurfacePlaneBytesPerElement: @(bpe),
                          (__bridge id)kIOSurfacePlaneElementWidth: @1, (__bridge id)kIOSurfacePlaneElementHeight: @1}];
        [plain addObject:@{(__bridge id)kIOSurfacePlaneWidth: @(w), (__bridge id)kIOSurfacePlaneHeight: @(h), (__bridge id)kIOSurfacePlaneBytesPerRow: @(row),
                           (__bridge id)kIOSurfacePlaneOffset: @(at), (__bridge id)kIOSurfacePlaneSize: @(row * h), (__bridge id)kIOSurfacePlaneBytesPerElement: @(bpe),
                           (__bridge id)kIOSurfacePlaneElementWidth: @1, (__bridge id)kIOSurfacePlaneElementHeight: @1}];
        to->plane_from[i] = off, to->plane_row[i] = row, to->plane_h[i] = h;
        at += row * h;
    }
    NSDictionary *props = @{(__bridge id)kIOSurfaceWidth: @(width), (__bridge id)kIOSurfaceHeight: @(height), (__bridge id)kIOSurfacePixelFormat: @(fourcc),
                            (__bridge id)kIOSurfaceAllocSize: @(alloc), (__bridge id)kIOSurfacePlaneInfo: info};
    IOSurfaceRef made = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!made) {
        /* Video formats can refuse the guest's padding: request packed planes instead. */
        NSDictionary *plain_props = @{(__bridge id)kIOSurfaceWidth: @(width), (__bridge id)kIOSurfaceHeight: @(height), (__bridge id)kIOSurfacePixelFormat: @(fourcc), (__bridge id)kIOSurfacePlaneInfo: plain};
        made = IOSurfaceCreate((__bridge CFDictionaryRef)plain_props);
    }
    if (made) {
        to->plane_count = planes;
        static int logged;
        if (planes >= 2 && logged++ < 4)
            for (uint32_t i = 0; i < planes && i < IOSurfaceGetPlaneCount(made) && i < 4; i++)
                fprintf(stderr, "hengevm: video plane %u guest off %llu row %llu h %llu; host row %zu h %zu\n",
                        i, (unsigned long long)to->plane_from[i], (unsigned long long)to->plane_row[i],
                        (unsigned long long)to->plane_h[i], IOSurfaceGetBytesPerRowOfPlane(made, i),
                        IOSurfaceGetHeightOfPlane(made, i));
    }
    return made;
}

/* Guest bytes sampled to tell whether a surface's pixels changed: one 8-byte word every SURFACE_SAMPLE bytes. One every
   64 bytes read every cache line of a 4K video frame (27 MB) for every exec that named the surface; a decoded frame
   changes nearly every word, so a sparser sample still sees each new one. */
enum { SURFACE_SAMPLE = 1024 };
static uint64_t hash_bytes(const uint8_t *from, uint64_t len) {
    uint64_t hash = 0xcbf29ce484222325ull;
    for (uint64_t i = 0; i + 8 <= len; i += SURFACE_SAMPLE) {
        uint64_t v;
        memcpy(&v, from + i, 8);
        hash = (hash ^ v) * 0x100000001b3ull;
    }
    return hash;
}

static uint64_t guest_hash(HvObject *s) { return hash_bytes(s->mapped + s->first, s->alloc); }

/* Plane i of a multi-plane surface in the guest's memory, or 0 bytes if its layout does not fit the allocation. */
static uint64_t plane_bytes(HvObject *s, uint32_t i) {
    uint64_t row = s->plane_row[i], off = s->plane_from[i];
    if (!row || off > s->alloc || s->plane_h[i] > (s->alloc - off) / row) return 0;
    return row * s->plane_h[i];
}

/* A format with a plane's bytes per element, for copying it as it is. */
static MTLPixelFormat copy_format(size_t bpe) {
    switch (bpe) {
    case 1: return MTLPixelFormatR8Uint;
    case 2: return MTLPixelFormatR16Uint;
    case 4: return MTLPixelFormatR32Uint;
    case 8: return MTLPixelFormatRG32Uint;
    case 16: return MTLPixelFormatRGBA32Uint;
    default: return MTLPixelFormatInvalid;
    }
}

/* Debugging, read once: HV_PVG_HOST_DUMP=prefix, the host surface as it is just before the guest's pixels go over it
   (the first few multi-plane surfaces, with its layout in a .txt beside it: did the GPU draw something here that this
   copy throws away?); HV_PVG_SURFACE_DUMP=prefix, the guest's bytes copied. */
static const char *host_dump_prefix(void) {
    static const char *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ p = getenv("HV_PVG_HOST_DUMP"); });
    return p;
}
static const char *surface_dump_prefix(void) {
    static const char *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ p = getenv("HV_PVG_SURFACE_DUMP"); });
    return p;
}

static void dump_host_surface(HvObject *s) {
    const char *host_dump = host_dump_prefix();
    static int host_dumped;
    if (!host_dump || !s->plane_count || host_dumped >= 12) return;
    char path[1100];
    IOSurfaceLock(s->iosurface, kIOSurfaceLockReadOnly, NULL);
    snprintf(path, sizeof path, "%s-%d.bin", host_dump, host_dumped);
    FILE *f = fopen(path, "wb");
    if (f) fwrite(IOSurfaceGetBaseAddress(s->iosurface), 1, IOSurfaceGetAllocSize(s->iosurface), f), fclose(f);
    snprintf(path, sizeof path, "%s-%d.txt", host_dump, host_dumped++);
    f = fopen(path, "w");
    if (f) {
        fprintf(f, "fourcc %08x w %zu h %zu alloc %zu guest %llu\n", IOSurfaceGetPixelFormat(s->iosurface), IOSurfaceGetWidth(s->iosurface),
                IOSurfaceGetHeight(s->iosurface), IOSurfaceGetAllocSize(s->iosurface), (unsigned long long)s->alloc);
        for (size_t i = 0; i < IOSurfaceGetPlaneCount(s->iosurface); i++)
            fprintf(f, "plane %zu off %ld row %zu h %zu w %zu bpe %zu\n", i,
                    (long)((uint8_t *)IOSurfaceGetBaseAddressOfPlane(s->iosurface, i) - (uint8_t *)IOSurfaceGetBaseAddress(s->iosurface)),
                    IOSurfaceGetBytesPerRowOfPlane(s->iosurface, i), IOSurfaceGetHeightOfPlane(s->iosurface, i),
                    IOSurfaceGetWidthOfPlane(s->iosurface, i), IOSurfaceGetBytesPerElementOfPlane(s->iosurface, i));
        fclose(f);
    }
    IOSurfaceUnlock(s->iosurface, kIOSurfaceLockReadOnly, NULL);
}

/* Plane i of the guest's pixels into the host IOSurface by the GPU: a blit from the buffer over the guest's pages into a
   view of the plane, in cb, before what cb draws. NO where that cannot be done (no buffer over the pages, a layout the
   blit cannot take): the CPU copies that plane then. */
- (BOOL)blitPlane:(uint32_t)i of:(HvObject *)s blit:(id<MTLBlitCommandEncoder> *)blit commandBuffer:(id<MTLCommandBuffer>)cb {
    id<MTLBuffer> pages = s->mapping_in_buffer ? s->object : nil;
    IOSurfaceRef ios = s->iosurface;
    size_t bpe = IOSurfaceGetBytesPerElementOfPlane(ios, i), pw = IOSurfaceGetWidthOfPlane(ios, i), ph = IOSurfaceGetHeightOfPlane(ios, i);
    uint64_t row = s->plane_row[i], from = (uint64_t)s->first + s->plane_from[i];
    size_t rows = MIN((size_t)s->plane_h[i], ph), w = bpe ? MIN(pw, (size_t)(row / bpe)) : 0;
    MTLPixelFormat format = copy_format(bpe);
    if (!cb || !pages || format == MTLPixelFormatInvalid || !w || !rows || row % bpe || from % bpe || !plane_bytes(s, i) ||
        from + row * (rows - 1) + w * bpe > pages.length)
        return NO;
    if (!s->plane_view[i]) {
        MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:pw height:ph mipmapped:NO];
        t.storageMode = MTLStorageModeShared;
        t.usage = MTLTextureUsageShaderRead;
        s->plane_view[i] = [device newTextureWithDescriptor:t iosurface:ios plane:i];
        if (!s->plane_view[i]) {
            [self complain:[NSString stringWithFormat:@"surface plane %u (%zu bytes an element): no view to copy into; copied by the CPU", i, bpe]];
            return NO;
        }
    }
    if (!*blit) *blit = [cb blitCommandEncoder];
    [*blit copyFromBuffer:pages sourceOffset:(NSUInteger)from sourceBytesPerRow:(NSUInteger)row sourceBytesPerImage:(NSUInteger)(row * rows)
               sourceSize:MTLSizeMake(w, rows, 1) toTexture:s->plane_view[i] destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    return YES;
}

/* Guest pixels into a surface's host IOSurface, the planes that changed: by the GPU when there is a command buffer to
   put the copy in (see blitPlane), else by the CPU. YES if a blit went into cb, which what cb draws must wait for. */
- (BOOL)syncSurface:(HvObject *)s blit:(id<MTLBlitCommandEncoder> *)blit commandBuffer:(id<MTLCommandBuffer>)cb {
    if (!s->iosurface) return NO;
    const uint8_t *from = s->mapped + s->first;
    BOOL by_plane = s->plane_count && IOSurfaceGetPlaneCount(s->iosurface) >= s->plane_count;
    uint64_t hashes[4] = {0};
    uint32_t changed = 0;
    uint64_t *have = s->shared_hashes ? (uint64_t *)s->shared_hashes.mutableBytes : s->plane_hash;
    if (by_plane) {
        for (uint32_t i = 0; i < s->plane_count && i < 4; i++) {
            hashes[i] = hash_bytes(from + s->plane_from[i], plane_bytes(s, i));
            if (hashes[i] != have[i]) changed |= 1u << i;
        }
        if (!changed) return NO;
    } else {
        uint64_t hash = guest_hash(s);
        if (hash == s->content_hash) return NO;
        s->content_hash = hash;
    }
    dump_host_surface(s);
    surfaces_copied++;
    BOOL blitted = NO;
    if (by_plane) {
        BOOL locked = NO;
        for (uint32_t i = 0; i < s->plane_count && i < 4; i++) {
            if (!(changed & 1u << i)) continue;
            have[i] = hashes[i];
            if ([self blitPlane:i of:s blit:blit commandBuffer:cb]) {
                blitted = YES;
                continue;
            }
            /* IOSurface can choose different offsets and row strides from those requested: copied through its
               actual host layout. */
            if (!locked) IOSurfaceLock(s->iosurface, 0, NULL), locked = YES;
            uint8_t *dst = IOSurfaceGetBaseAddressOfPlane(s->iosurface, i);
            size_t dst_row = IOSurfaceGetBytesPerRowOfPlane(s->iosurface, i);
            size_t rows = MIN((size_t)s->plane_h[i], IOSurfaceGetHeightOfPlane(s->iosurface, i));
            uint64_t src_row = s->plane_row[i], src_off = s->plane_from[i];
            if (!dst || !src_row || src_off > s->alloc || rows > (s->alloc - src_off) / src_row) continue;
            size_t bytes = MIN((size_t)src_row, dst_row);
            for (size_t y = 0; y < rows; y++)
                memcpy(dst + y * dst_row, from + src_off + y * src_row, bytes);
        }
        if (locked) IOSurfaceUnlock(s->iosurface, 0, NULL);
    } else {
        IOSurfaceLock(s->iosurface, 0, NULL);
        memcpy(IOSurfaceGetBaseAddress(s->iosurface), from, MIN(s->alloc, IOSurfaceGetAllocSize(s->iosurface)));
        IOSurfaceUnlock(s->iosurface, 0, NULL);
    }
    const char *dump = surface_dump_prefix();
    static int dumped;
    if (dump && s->plane_count && dumped < 6) {
        char path[1100];
        snprintf(path, sizeof path, "%s-%d.bin", dump, dumped++);
        FILE *f = fopen(path, "wb");
        if (f) fwrite(from, 1, s->alloc, f), fclose(f);
    }
    return blitted;
}

/* A multi-plane surface's host IOSurface, shared by every mapping of the same guest memory (another process):
   what one draws there is what another reads. Whether its pixels are there is in the hashes it shares: a video
   decoder's process writes frames with the CPU and never uses the GPU, so nothing had copied them, and the first
   process to draw with one (the wallpaper's lock-screen image during Setup) read an empty frame: solid green. */
- (void)newIOSurface:(HvObject *)surface mapping:(uint64_t)mapping {
    if (surface->iosurface || !surface->planar_desc) return;
    const uint8_t *desc = surface->planar_desc.bytes;
    NSString *pk = surface->planar_want;
    IOSurfaceRef made = make_iosurface(surface, desc, surface->alloc, surface->planar_compact);
    id shared = planar[pk];
    if (shared && made) {
        CFRelease(made);
        surface->iosurface = (IOSurfaceRef)CFRetain((__bridge CFTypeRef)shared);
        surface->content_hash = guest_hash(surface);
        surface->shared_hashes = planar_hashes[pk];
        surface->planar_key = pk;
        planar_uses[pk] = @(planar_uses[pk].unsignedIntValue + 1);
        static int told;
        if (told++ < 8) fprintf(stderr, "hengevm: pvg-metal: surface %llu shares the host surface of the same guest memory (%s)\n", mapping, pk.UTF8String);
        return;
    }
    surface->iosurface = made;
    if (made) {
        if (planar.count >= 512) [planar removeAllObjects], [planar_uses removeAllObjects], [planar_hashes removeAllObjects]; /* old ones only lose their sharing */
        planar[pk] = (__bridge id)made;
        planar_uses[pk] = @1;
        surface->shared_hashes = [NSMutableData dataWithLength:sizeof surface->plane_hash];
        planar_hashes[pk] = surface->shared_hashes;
        surface->planar_key = pk;
    } else {
        NSMutableString *m = [NSMutableString stringWithFormat:@"surface %llu: no IOSurface for its planes (alloc %llu):", mapping, surface->alloc];
        for (int i = 0; i < 96; i++) [m appendFormat:@" %08x", ((const uint32_t *)desc)[i]];
        [self complain:m];
    }
    [self syncSurface:surface blit:NULL commandBuffer:nil];
}

/* A surface (IOSurface in the guest): a texture over its guest pages, so the
   guest's CPU and the GPU see the same pixels, as they do through a real one.
   {mapping id, tag, size, ref, description}. Its descriptor: page list at +0,
   first-page offset +0x60, allocation +0x18, bytes per row +0x30. The list is a
   page table, as ParavirtualizedGraphics reads it (-[PGIOSurfaceHostDevice
   mapSurface:]): each 32-bit entry is a 16 KB page number << 2 with two flag bits,
   01 for a page and 11 for a table page. Up to 4096 pages the list page holds the
   surface's pages; past that it holds up to 4096 table pages of 4096 pages each. */
/* Entry i of a surface's page table, or 0 for a missing or malformed one. */
static uint32_t surface_page_entry(HvPvgLite *lite, uint32_t list, uint64_t n, uint64_t i) {
    const uint64_t per = 0x4000 / 4;
    if (!(list & 1) || n > per * per) return 0;
    const uint32_t *root = hv_pvg_lite_phys(lite, (uint64_t)(list >> 2) << 14, 0x4000);
    if (!root) return 0;
    uint32_t e;
    if (n <= per) e = root[i];
    else {
        uint32_t table = root[i / per];
        if ((table & 3) != 3) return 0;
        const uint32_t *t = hv_pvg_lite_phys(lite, (uint64_t)(table >> 2) << 14, 0x4000);
        if (!t) return 0;
        e = t[i % per];
    }
    return (e & 3) == 1 ? e : 0;
}
/* A guest surface (IOSurface) from its description: its pages in one host buffer, every plane's views on them. */
- (HvObject *)newSurface:(uint64_t)mapping {
    NSNumber *key = @(mapping);
    HvObject *surface = nil;
    const uint8_t *desc = hv_pvg_lite_surface(lite, (uint32_t)mapping);
    if (!desc) { [self complain:[NSString stringWithFormat:@"surface %llu has no descriptor", mapping]]; return nil; }
    uint32_t list, first;
    uint64_t alloc, row;
    /* macOS 15 and later: u64 allocation, width, height and row at 0x18..0x30, plane count at 0x3e, first byte at 0x60.
       macOS 14's driver writes a compact one: u32 allocation at 0x10, width and height << 8 at 0x14 and 0x18, u32 row
       at 0x1c, bytes per pixel at 0x20 (BGRA 1920x1080: 007ec000 00078080 00043880 00001e00 00000004); one plane. */
    BOOL compact = hv_pvg_lite_old_driver(lite) != 0;
    if (getenv("HV_PVG_DESC_DUMP")) {
        fprintf(stderr, "surface-desc %llu:", mapping);
        for (int i = 0; i < 0x200; i += 4) fprintf(stderr, "%s%08x", i % 32 ? " " : "\n  ", *(const uint32_t *)(desc + i));
        fprintf(stderr, "\n");
    }
    uint32_t compact_planes = 1;
    if (compact) memcpy(&compact_planes, desc + 0x24, 4);
    uint8_t planes = compact ? (uint8_t)MIN(MAX(compact_planes, 1u), 4u) : desc[0x3e];
    memcpy(&list, desc, 4), memcpy(&alloc, desc + 0x18, 8), memcpy(&row, desc + 0x30, 8), memcpy(&first, desc + 0x60, 4);
    if (compact) {
        uint32_t a32, r32;
        memcpy(&a32, desc + 0x10, 4), memcpy(&r32, desc + 0x1c, 4);
        alloc = a32, row = r32, first = 0;
    }
    surface = [HvObject new];
    if (compact) memcpy(surface->described, desc, sizeof surface->described);
    surface->length = (alloc + first + 0x3fff) & ~0x3fffull;
    surface->row = row;
    surface->first = first;
    uint64_t sw, sh;
    memcpy(&sw, desc + 0x20, 8), memcpy(&sh, desc + 0x28, 8), memcpy(&surface->fourcc, desc + 4, 4);
    if (compact) {
        uint32_t w32, h32;
        memcpy(&w32, desc + 0x14, 4), memcpy(&h32, desc + 0x18, 4);
        sw = w32 >> 8, sh = h32 >> 8;
    }
    surface->surface_w = (uint32_t)sw, surface->surface_h = (uint32_t)sh;
    uint64_t n = surface->length >> 14;
    vm_address_t pages_at = 0;
    uint32_t page0 = n ? surface_page_entry(lite, list, n, 0) : 0;
    if (!page0 || vm_allocate(mach_task_self(), &pages_at, surface->length, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
        [self complain:[NSString stringWithFormat:@"surface %llu has no pages", mapping]];
        return nil;
    }
    surface->mapped = (uint8_t *)pages_at;
    for (uint64_t i = 0; i < n; i++) {
        uint32_t page = surface_page_entry(lite, list, n, i);
        if (!page) continue;
        uint8_t *src = hv_pvg_lite_phys(lite, (uint64_t)(page >> 2) << 14, 0x4000);
        if (!src) continue;
        vm_address_t to = pages_at + (i << 14);
        vm_prot_t cur, max;
        vm_remap(mach_task_self(), &to, 0x4000, 0, VM_FLAGS_OVERWRITE, mach_task_self(), (vm_address_t)src, FALSE, &cur, &max, VM_INHERIT_NONE);
    }
    surface->object = [device newBufferWithBytesNoCopy:surface->mapped length:surface->length options:MTLResourceStorageModeShared
                                           deallocator:^(void *at, NSUInteger size) { vm_deallocate(mach_task_self(), (vm_address_t)at, size); }];
    surface->mapping_in_buffer = surface->object != nil;
    surfaces[key] = surface;
    if (planes >= 2) {
        surface->alloc = alloc;
        surface->planar_compact = compact;
        surface->planar_desc = [NSData dataWithBytes:desc length:compact ? 0x200 : 0x400]; /* the whole slot */
        surface->planar_want = [NSString stringWithFormat:@"%x/%08x/%llux%llu/%llu", page0 & ~3u, surface->fourcc,
                                (unsigned long long)sw, (unsigned long long)sh, (unsigned long long)alloc];
        plane_layout(surface, desc, compact);
        /* Each plane is drawn and read through a view of its own (R8, RG8, BGR10...), so a view can sit on the
           guest's pages at the plane's offset, as a one-plane surface's does, and what the GPU draws is in guest
           memory at once. A host IOSurface copy instead kept what the GPU drew to itself: nothing wrote it back,
           and it went with its last mapping, so a WebKit page tile drawn in its GPU process and mapped again (or
           first) by WindowServer came back from the guest's pages as never drawn, alpha 0: a blank page. A copy
           is still made for a view that cannot sit on the pages (newIOSurface). HV_PVG_PLANAR_COPY=1 (testing):
           the copy for every one, as before. */
        static int copy_all = -1;
        if (copy_all < 0) copy_all = getenv("HV_PVG_PLANAR_COPY") != NULL;
        if (copy_all || !surface->mapping_in_buffer) [self newIOSurface:surface mapping:mapping];
    }
    if (hv_pvg_trace_on()) fprintf(stderr, "trace: surface %llu: %llux%llu, row %llu, %llu KB, fourcc %c%c%c%c planes %u\n", mapping, (unsigned long long)sw, (unsigned long long)sh, row, alloc >> 10, desc[7], desc[6], desc[5], desc[4], planes);
        return surface;
}

/* The surface under a mapping id as the guest describes it now. macOS 14's driver reuses ids for new surfaces
   without saying the old one went: a different description under the same id is a new surface (a 1920x48 BGRA
   strip, then the 1920x1080 half-float screen). */
- (HvObject *)currentSurface:(uint64_t)mapping {
    HvObject *surface = surfaces[@(mapping)];
    if (surface && hv_pvg_lite_old_driver(lite)) {
        const uint8_t *now = hv_pvg_lite_surface(lite, (uint32_t)mapping);
        if (now && (now[0] | now[0x10]) && memcmp(surface->described, now, sizeof surface->described)) {
            [surfaces removeObjectForKey:@(mapping)];
            surface = nil;
        }
    }
    return surface ? surface : [self newSurface:mapping];
}

- (void)makeMappedTexture:(HvObject *)o at:(uint64_t)at task:(uint32_t)task {
    /* d holds a v2 description (tag 0x39, 0x38 bytes) whose swizzle sits at +0x23..0x26: with only 32 bytes
       read those came from the stack, and macOS 27.2's first surface made Metal abort Henge (swizzle 193). */
    struct __attribute__((packed)) { uint64_t mapping; uint32_t tag, size, ref; uint8_t d[64]; } h;
    memset(&h, 0, sizeof h);
    const uint32_t head = (uint32_t)offsetof(__typeof__(h), d);
    if (hv_pvg_lite_task_read(lite, task, at, &h, head + 32)) return;
    /* size is the description's own length (0x38 for a v2 one), after the header */
    if (h.size > 32 && hv_pvg_lite_task_read(lite, task, at, &h, head + MIN(h.size, (uint32_t)sizeof h.d))) {
        memset(h.d + 32, 0, sizeof h.d - 32); /* past the end of the task: keep what the first read had */
    }
    HvObject *surface = [self currentSurface:h.mapping];
    o->on_mapping = h.mapping;
    if (hv_pvg_trace_on()) {
        fprintf(stderr, "trace: mapped texture ref %u tag %#x size %u mapping %llu:", h.ref, h.tag, h.size, h.mapping);
        for (int i = 0; i < 64; i += 4) fprintf(stderr, " %08x", *(uint32_t *)(h.d + i));
        fprintf(stderr, "\n");
    }
    MTLTextureDescriptor *t = h.tag == 0x39 ? descriptor_v2(h.d) : descriptor_v1(h.d);
    if (!surface) surface = [self newSurface:h.mapping];
    if (!surface) return;
    t.storageMode = MTLStorageModeShared;
    set_framebuffer_only(t, NO);
    t.usage |= MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    /* Metal aborts on a swizzled render target, and a surface is always drawn into here: views over it
       (tags 7/8/0x1b) can still swizzle. */
    MTLTextureSwizzleChannels sw = t.swizzle;
    if (sw.red != MTLTextureSwizzleRed || sw.green != MTLTextureSwizzleGreen || sw.blue != MTLTextureSwizzleBlue || sw.alpha != MTLTextureSwizzleAlpha) {
        static int told;
        if (told++ < 3) fprintf(stderr, "hengevm: pvg-metal: surface %llu asked for swizzle %u %u %u %u; drawing it unswizzled\n", h.mapping, sw.red, sw.green, sw.blue, sw.alpha);
        t.swizzle = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
    }
    o->surface = surface;
    /* The plane the texture is over, after the description in the guest's record (PGSerializedTextureDescriptor
       then plane and rotation, 16 bits each: record +0x24 for v1, +0x2c for v2, the record starting at ref).
       macOS draws video and Safari's page tiles one plane at a time (R8 luma, RG8 chroma, R8 alpha): every view
       made over plane 0 left plane 1 empty, so chroma read back as zero (all green) and alpha as zero (blank pages). */
    uint16_t plane;
    memcpy(&plane, h.d + (h.tag == 0x39 ? 0x28 : 0x20), 2);
    static int plane0 = -1; /* HV_PVG_PLANE0 (testing): every view on plane 0, as before this was read */
    if (plane0 < 0) plane0 = getenv("HV_PVG_PLANE0") != NULL;
    if (plane0) plane = 0;
    if (surface->planar_desc && !surface->iosurface) {
        if (plane >= surface->plane_count) {
            [self complain:[NSString stringWithFormat:@"surface %llu: texture on plane %u of %u; using plane 0", h.mapping, plane, surface->plane_count]];
            plane = 0;
        }
        uint64_t at_plane = surface->first + surface->plane_from[plane];
        id<MTLBuffer> pages = surface->object;
        if (plane_bytes(surface, plane) && linear_texture_fits(device, t, at_plane, surface->plane_row[plane], pages.length))
            o->object = [pages newTextureWithDescriptor:t offset:at_plane bytesPerRow:surface->plane_row[plane]];
        if (o->object) {
            static int told;
            if (told++ < 8) fprintf(stderr, "hengevm: pvg-metal: surface %llu: %lux%lu format %lu on plane %u, on its pages at %llu, rows of %llu\n",
                                    h.mapping, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat, plane,
                                    (unsigned long long)at_plane, (unsigned long long)surface->plane_row[plane]);
            if (!plane) mapped_textures[@(h.mapping)] = o->object;
            return;
        }
        /* From here on this surface's GPU writes stay in the host copy, as they all did before. */
        [self complain:[NSString stringWithFormat:@"surface %llu: format %lu on plane %u cannot sit on its pages; host copy", h.mapping, (unsigned long)t.pixelFormat, plane]];
        [self newIOSurface:surface mapping:h.mapping];
    }
    if (surface->iosurface && plane >= IOSurfaceGetPlaneCount(surface->iosurface)) {
        [self complain:[NSString stringWithFormat:@"surface %llu: texture on plane %u of %zu; using plane 0", h.mapping, plane,
                        IOSurfaceGetPlaneCount(surface->iosurface)]];
        plane = 0;
    }
    if (plane) {
        static int told;
        if (told++ < 8) fprintf(stderr, "hengevm: pvg-metal: surface %llu: texture %lux%lu format %lu on plane %u\n", h.mapping,
                                (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat, plane);
    }
    if (surface->iosurface) {
        o->object = [device newTextureWithDescriptor:t iosurface:surface->iosurface plane:plane];
        if (!o->object) { /* video formats cannot be drawn into */
            t.usage = MTLTextureUsageShaderRead;
            o->object = [device newTextureWithDescriptor:t iosurface:surface->iosurface plane:plane];
        }
    }
    else if (linear_texture_fits(device, t, surface->first, surface->row, ((id<MTLBuffer>)surface->object).length))
        o->object = [(id<MTLBuffer>)surface->object newTextureWithDescriptor:t offset:surface->first bytesPerRow:surface->row];
    if (!o->object) {
        [self complain:[NSString stringWithFormat:@"surface %llu: format %lu row %llu not possible", h.mapping, (unsigned long)t.pixelFormat, surface->row]];
        t.storageMode = MTLStorageModePrivate;
        o->object = [device newTextureWithDescriptor:t]; /* something to bind: it stays empty */
    }
    if (!plane) mapped_textures[@(h.mapping)] = o->object;
}
