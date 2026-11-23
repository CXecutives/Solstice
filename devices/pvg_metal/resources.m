/* Heaps, buffers and textures, and the texture descriptions they are made from (part of pvg_metal.m). */

static void set_framebuffer_only(MTLTextureDescriptor *t, BOOL on) {
    SEL sel = sel_registerName("setFramebufferOnly:");
    if ([t respondsToSelector:sel]) ((void (*)(id, SEL, BOOL))objc_msgSend)(t, sel, on);
}

/* What Apple's host takes from both serialized forms: flags (framebuffer only bit 4, GPU
   optimized bit 6) and resource options, of which iOS has no managed memory. */
static void descriptor_common(MTLTextureDescriptor *t, uint8_t flags, uint16_t options) {
    set_framebuffer_only(t, (flags >> 4) & 1);
    t.allowGPUOptimizedContents = (flags >> 6) & 1;
    MTLResourceOptions o = options & 0x3ff;
#if TARGET_OS_IPHONE
    if ((o & 0xf0) == 0x10) o = (o & ~(MTLResourceOptions)0xf0) | MTLResourceStorageModeShared;
#endif
    t.resourceOptions = o;
}

/* Metal aborts the whole app on a swizzle channel outside 0...5 (seen as 193 when a surface's description was
   read short, see makeMappedTexture), so an unknown one falls back to the identity, logged a few times. */
static MTLTextureSwizzleChannels safe_swizzle(const uint8_t *sw, const uint8_t *desc, size_t desc_len, const char *what) {
    if (!(sw[0] | sw[1] | sw[2] | sw[3])) /* all Zero: never meant, it would draw nothing; an unread field */
        return MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
    for (int i = 0; i < 4; i++) {
        if (sw[i] > MTLTextureSwizzleAlpha) {
            static int told;
            if (told++ < 3) {
                fprintf(stderr, "hengevm: pvg-metal: %s swizzle %u %u %u %u is not a Metal swizzle; using RGBA. desc:", what, sw[0], sw[1], sw[2], sw[3]);
                for (size_t j = 0; j < desc_len; j++) fprintf(stderr, " %02x", desc[j]);
                fputc('\n', stderr);
            }
            return MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
        }
    }
    return MTLTextureSwizzleChannelsMake(sw[0], sw[1], sw[2], sw[3]);
}

/* The two serialized forms of a texture description, and the bytes each reads. */
enum { DESCRIPTOR_V1 = 24, DESCRIPTOR_V2 = 0x27 };
static MTLTextureDescriptor *descriptor_v1(const uint8_t *d) {
    MTLTextureDescriptor *t = [MTLTextureDescriptor new];
    t.textureType = (MTLTextureType)(d[0] & 0xf);
    t.usage = d[1];
    t.pixelFormat = (MTLPixelFormat)(d[2] | d[3] << 8);
    t.width = *(const uint32_t *)(d + 4);
    t.height = *(const uint32_t *)(d + 8);
    t.depth = *(const uint32_t *)(d + 12);
    t.mipmapLevelCount = *(const uint16_t *)(d + 16);
    t.sampleCount = *(const uint16_t *)(d + 18);
    t.arrayLength = *(const uint16_t *)(d + 20);
    descriptor_common(t, d[0], *(const uint16_t *)(d + 22));
    return t;
}

static MTLTextureDescriptor *descriptor_v2(const uint8_t *d) {
    MTLTextureDescriptor *t = [MTLTextureDescriptor new];
    uint32_t usage, w, h, depth;
    uint16_t mips, samples, array, options;
    memcpy(&usage, d + 3, 4), memcpy(&w, d + 7, 4), memcpy(&h, d + 11, 4), memcpy(&depth, d + 15, 4);
    memcpy(&mips, d + 19, 2), memcpy(&samples, d + 21, 2), memcpy(&array, d + 23, 2), memcpy(&options, d + 25, 2);
    t.textureType = (MTLTextureType)(d[0] & 0xf);
    t.pixelFormat = (MTLPixelFormat)(d[1] | d[2] << 8);
    t.usage = usage;
    t.width = w, t.height = h, t.depth = depth;
    t.mipmapLevelCount = mips, t.sampleCount = samples, t.arrayLength = array;
    descriptor_common(t, d[0], options);
    t.swizzle = safe_swizzle(d + 0x23, d, 0x27, "texture");
    if (t.usage & MTLTextureUsageRenderTarget) /* Metal aborts on a swizzled render target */
        t.swizzle = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
    return t;
}

/* A heap: {guest page, length, flags}. As on Apple's host its memory is the GPU's
   own, filled from the guest's pages when the guest says those changed. */
- (void)makeHeap:(HvObject *)o at:(uint64_t)at task:(uint32_t)task {
    struct __attribute__((packed)) { uint32_t vpage; uint64_t length; uint8_t flags; } h;
    if (hv_pvg_lite_task_read(lite, task, at, &h, sizeof h)) return;
    MTLHeapDescriptor *d = [MTLHeapDescriptor new];
    d.size = (NSUInteger)h.length;
    d.type = MTLHeapTypePlacement;
    d.storageMode = MTLStorageModePrivate;
    d.hazardTrackingMode = h.flags & 2 ? MTLHazardTrackingModeTracked : MTLHazardTrackingModeDefault;
    id<MTLHeap> heap = [device newHeapWithDescriptor:d];
    if (!heap && d.hazardTrackingMode == MTLHazardTrackingModeTracked) { /* not every GPU tracks placement heaps */
        d.hazardTrackingMode = MTLHazardTrackingModeDefault;
        heap = [device newHeapWithDescriptor:d];
        [self complain:@"placement heaps here cannot be tracked"];
    }
    if (!heap) { [self complain:[NSString stringWithFormat:@"heap of %llu bytes failed", h.length]]; return; }
    o->object = heap;
    o->heap_whole = [heap newBufferWithLength:(NSUInteger)h.length options:MTLResourceStorageModePrivate offset:0];
    o->length = (h.length + 0x3fff) & ~0x3fffull;
    o->vpage = h.vpage;
    o->guest_backed = YES;
    heap_bytes += h.length;
    if (getenv("HV_PVG_HEAP_LOG")) fprintf(stderr, "hengevm: pvg-metal: heap %llu KB at page %u, flags %x, now %llu MB of heaps\n", h.length >> 10, h.vpage, h.flags, heap_bytes >> 20);
}

/* A buffer in a heap: {heap, offset, length}. */
- (void)makeHeapBuffer:(HvObject *)o at:(uint64_t)at task:(uint32_t)task {
    struct __attribute__((packed)) { uint32_t heap; uint64_t offset, length; } h;
    if (hv_pvg_lite_task_read(lite, task, at, &h, sizeof h)) return;
    HvObject *parent = [self object:h.heap task:task];
    id<MTLHeap> heap = of_kind(parent ? parent->object : nil, @protocol(MTLHeap));
    o->parent = parent;
    o->object = [heap newBufferWithLength:(NSUInteger)h.length options:MTLResourceStorageModePrivate offset:(NSUInteger)h.offset];
    if (!o->object) {
        [self complain:[NSString stringWithFormat:@"heap buffer: %llu bytes at %llu of ref %u failed", h.length, h.offset, h.heap]];
        o->object = [device newBufferWithLength:(NSUInteger)h.length options:MTLResourceStorageModePrivate];
    }
}

- (void)makeBuffer:(HvObject *)o at:(uint64_t)at task:(uint32_t)task {
    struct __attribute__((packed)) { uint64_t length; uint32_t vpage; uint32_t flags; } h;
    if (hv_pvg_lite_task_read(lite, task, at, &h, sizeof h)) return;
    o->length = (h.length + 0x3fff) & ~0x3fffull;
    o->vpage = h.vpage;
    if (!map_pages(self, task, o)) return;
    o->plain_buffer = YES;
    o->object = buffer_over_mapping(self, o);
    if (!o->object) [self complain:@"buffer failed"];
}

- (void)makeTexture:(HvObject *)o at:(uint64_t)at size:(uint32_t)size task:(uint32_t)task {
    NSMutableData *all = [NSMutableData dataWithLength:size];
    if (hv_pvg_lite_task_read(lite, task, at, all.mutableBytes, size)) return;
    [self makeTexture:o from:all.bytes size:size];
}

- (void)makeTexture:(HvObject *)o from:(const uint8_t *)d size:(uint32_t)size {
    /* {length, page}, a layout table, {tag, size, ref}, the description. */
    if (size < 12 + 0x18) { [self complain:@"texture entry too small"]; return; }
    memcpy(&o->length, d, 8);
    memcpy(&o->vpage, d + 8, 4);
    const uint8_t *layout = d + 12;
    o->tex_mips = *(const uint16_t *)layout & 0x3fff;
    o->tex_slices = *(const uint16_t *)(layout + 2);
    memcpy(&o->tex_base, layout + 4, 8);
    memcpy(&o->tex_stride, layout + 12, 8);
    o->tex_block_h = layout[0x15];
    uint32_t table = o->tex_mips * 36;
    if (12 + 0x18 + table + 12 > size) { [self complain:@"texture entry too small"]; return; }
    const uint8_t *rec = layout + 0x18 + table;
    uint32_t tag = *(const uint32_t *)rec;
    if (12 + 0x18 + table + 12 + (tag == 0x34 || tag == 0x39 ? DESCRIPTOR_V2 : DESCRIPTOR_V1) > size) { [self complain:@"texture entry too small"]; return; }
    o->tex_layout = malloc(table);
    memcpy(o->tex_layout, layout + 0x18, table);
    MTLTextureDescriptor *t = (tag == 0x34 || tag == 0x39) ? descriptor_v2(rec + 12) : descriptor_v1(rec + 12);
    t.storageMode = MTLStorageModePrivate;
    t.usage |= MTLTextureUsageShaderRead;
    o->object = [device newTextureWithDescriptor:t];
    o->guest_backed = YES;
    if (!o->object) [self complain:[NSString stringWithFormat:@"texture format %lu %lux%lu failed", (unsigned long)t.pixelFormat, (unsigned long)t.width, (unsigned long)t.height]];
}

/* A texture over a buffer: {tag 9, size, ref, buffer ref, offset, bytes per row, description}. */
- (void)makeLinearTexture:(HvObject *)o at:(uint64_t)at size:(uint32_t)size task:(uint32_t)task {
    struct __attribute__((packed)) { uint32_t tag, size, ref, buffer; uint64_t offset, row; uint8_t d[64]; } h;
    memset(&h, 0, sizeof h);
    if (hv_pvg_lite_task_read(lite, task, at, &h, MIN(size, (uint32_t)sizeof h))) return;
    if (h.tag == 0x34 || h.tag == 0x14 || h.tag == 1) { /* no guest memory at all: {tag, size, ref, description} */
        const uint8_t *desc = (const uint8_t *)&h.buffer;
        MTLTextureDescriptor *t = h.tag == 0x34 ? descriptor_v2(desc) : descriptor_v1(desc);
        t.storageMode = MTLStorageModePrivate;
        o->object = [device newTextureWithDescriptor:t];
        if (!o->object) [self complain:[NSString stringWithFormat:@"texture format %lu %lux%lu samples %lu failed", (unsigned long)t.pixelFormat, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.sampleCount]];
        return;
    }
    if (h.tag == 0x15 || h.tag == 0x38) { /* in a heap: {tag, size, ref, heap, description, offset after 0x24 or 0x2c} */
        const uint8_t *desc = (const uint8_t *)&h.offset;
        uint64_t offset;
        memcpy(&offset, desc + (h.tag == 0x38 ? 0x2c : 0x24), 8);
        HvObject *parent = [self object:h.buffer task:task];
        id<MTLHeap> heap = of_kind(parent ? parent->object : nil, @protocol(MTLHeap));
        MTLTextureDescriptor *t = h.tag == 0x38 ? descriptor_v2(desc) : descriptor_v1(desc);
        t.resourceOptions = heap ? heap.resourceOptions : MTLResourceStorageModePrivate;
        o->parent = parent;
        o->object = [heap newTextureWithDescriptor:t offset:(NSUInteger)offset];
        if (!o->object) {
            [self complain:[NSString stringWithFormat:@"heap texture format %lu %lux%lu at %llu of ref %u failed", (unsigned long)t.pixelFormat, (unsigned long)t.width, (unsigned long)t.height, offset, h.buffer]];
            t.storageMode = MTLStorageModePrivate;
            o->object = [device newTextureWithDescriptor:t];
        }
        return;
    }
    if (h.tag == 7 || h.tag == 8 || h.tag == 0x1b) { /* a view: {tag, size, ref, parent, format u16, type u16, levels, slices, swizzle} */
        struct __attribute__((packed)) { uint16_t format, type; uint64_t levels[2], slices[2]; uint8_t swizzle[4]; } v;
        memcpy(&v, &h.offset, sizeof v);
        HvObject *parent = [self object:h.buffer task:task];
        id<MTLTexture> from = of_kind(parent ? parent->object : nil, @protocol(MTLTexture));
        if (!from) { [self complain:[NSString stringWithFormat:@"view of nothing (tag %u, ref %u)", h.tag, h.buffer]]; return; }
        o->parent = parent;
        o->surface = parent->surface;
        NSRange levels = NSMakeRange((NSUInteger)v.levels[0], (NSUInteger)v.levels[1]), slices = NSMakeRange((NSUInteger)v.slices[0], (NSUInteger)v.slices[1]);
        if (h.tag == 7) o->object = [from newTextureViewWithPixelFormat:(MTLPixelFormat)v.format];
        else if (h.tag == 8) o->object = [from newTextureViewWithPixelFormat:(MTLPixelFormat)v.format textureType:(MTLTextureType)v.type levels:levels slices:slices];
        else o->object = [from newTextureViewWithPixelFormat:(MTLPixelFormat)v.format textureType:(MTLTextureType)v.type levels:levels slices:slices
                                                     swizzle:safe_swizzle(v.swizzle, (const uint8_t *)&v, sizeof v, "view")];
        if (!o->object) [self complain:[NSString stringWithFormat:@"view tag %u of format %lu as %u failed", h.tag, (unsigned long)from.pixelFormat, v.format]];
        return;
    }
    if (h.tag != 9 && h.tag != 0x37) {
        uint32_t w[24] = {0};
        hv_pvg_lite_task_read(lite, task, at, w, sizeof w);
        NSMutableString *m = [NSMutableString stringWithFormat:@"serialized texture tag %u:", h.tag];
        for (int i = 0; i < 24; i++) [m appendFormat:@" %08x", w[i]];
        [self complain:m];
        return;
    }
    HvObject *b = [self object:h.buffer task:task];
    id<MTLBuffer> buffer = b ? b->object : nil;
    if (!buffer || ![buffer conformsToProtocol:@protocol(MTLBuffer)]) { [self complain:@"linear texture without a buffer"]; return; }
    MTLTextureDescriptor *t = h.tag == 0x37 ? descriptor_v2(h.d) : descriptor_v1(h.d);
    t.resourceOptions = buffer.resourceOptions;
    set_framebuffer_only(t, NO);
    t.usage |= MTLTextureUsageShaderRead;
    o->parent = b;
    o->follows = b, o->follows_generation = b->generation;
    if (linear_texture_fits(device, t, h.offset, h.row, buffer.length)) o->object = [buffer newTextureWithDescriptor:t offset:h.offset bytesPerRow:h.row];
    if (!o->object) [self complain:[NSString stringWithFormat:@"linear texture format %lu row %llu failed", (unsigned long)t.pixelFormat, h.row]];
}
