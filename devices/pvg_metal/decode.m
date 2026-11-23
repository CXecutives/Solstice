/* The serialized calls: render, compute, blit and object queries, each record checked (part of pvg_metal.m). */

/* A record's bytes, as a pointer into the buffer's private copy. */
typedef struct {
    const uint8_t *p;
    uint32_t size;
} Rec;

#define U32(off) (*(const uint32_t *)(r.p + (off)))
#define U16(off) (*(const uint16_t *)(r.p + (off)))
#define U64(off) ({ uint64_t _v; memcpy(&_v, r.p + (off), 8); _v; })

- (id<MTLRenderCommandEncoder>)beginPass:(Rec)r task:(uint32_t)task commandBuffer:(id<MTLCommandBuffer>)cb {
    if (r.size < 0x48) { /* the depth and stencil attachments, which every pass record has */
        [self complain:[NSString stringWithFormat:@"render pass of %u bytes, too short: skipped", r.size]];
        return nil;
    }
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
        if (left < 0) left = hv_knob.pvg_passdump;
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
        uint32_t c0ref = r.size >= 0x50 ? U32(0x4c) : 0;
        HvObject *co = [self object:c0ref task:task];
        fprintf(stderr, "trace: pass c0 ref %u %lux%lu fmt %lu load %lu store %lu clear %.2f %.2f %.2f %.2f surface %s heap %d\n", U32(0x4c), (unsigned long)c0.width, (unsigned long)c0.height, (unsigned long)c0.pixelFormat, (unsigned long)d.colorAttachments[0].loadAction, (unsigned long)d.colorAttachments[0].storeAction, cc.red, cc.green, cc.blue, cc.alpha, co && co->surface ? "yes" : "no", c0.heap != nil);
    }
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:d];
    if (!e) {
        NSMutableString *m = [NSMutableString stringWithString:@"no render encoder:"];
        for (int i = 0; i < 8; i++) {
            MTLRenderPassColorAttachmentDescriptor *c = d.colorAttachments[i];
            uint32_t at = 0x4c + (uint32_t)i * 0x3c, ref = at + 4 <= r.size ? U32(at) : 0;
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

/* The bytes a call's record needs for what its handler reads at fixed places, by tag; a list after a count is checked
   where it is read. Records point into memory the guest shares, so a count is read once. Tags not listed read nothing
   at fixed places (or are not handled). */
static const uint8_t render_min[] = {
    [0] = 20, [1] = 8, [2] = 26, [3] = 8, [4] = 34, [5] = 10, [6] = 24, [7] = 12, [8] = 32, [9] = 14, [10] = 48, [11] = 18,
    [12] = 46, [13] = 16, [14] = 58, [15] = 22, [16] = 16, [17] = 28, [18] = 26, [19] = 38, [24] = 8, [25] = 8, [27] = 8,
    [28] = 48, [29] = 18, [101] = 16, [104] = 4, [107] = 4, [108] = 12, [109] = 4, [110] = 8, [111] = 12, [112] = 8,
    [113] = 8, [114] = 8, [115] = 4, [116] = 4, [117] = sizeof(MTLScissorRect), [119] = 8, [122] = 20, [123] = 4, [124] = 4,
    [125] = 8, [126] = 12, [127] = 8, [128] = 8, [129] = 8, [130] = sizeof(MTLViewport), [134] = 4, [135] = 8, [137] = 8,
    [154] = 4, [155] = sizeof(MTLSize), [157] = 8, [161] = 8, [162] = sizeof(MTLSize) + sizeof(MTLRegion), [164] = 12,
    [165] = 8, [166] = 20,
};
static const uint8_t compute_min[] = { /* tag - 200 */
    [0] = 2 * sizeof(MTLSize), [2] = 2 * sizeof(MTLSize), [3] = 8, [4] = 8, [6] = 8, [7] = 12, [8] = 4, [9] = sizeof(MTLRegion),
    [11] = 12, [12] = 4, [13] = 4, [16] = 8,
};
static const uint8_t blit_min[] = { /* tag - 300 */
    [0] = 0x58, [1] = 0x20, [2] = 0x56, [3] = 0x58, [6] = 21, [7] = 4, [16] = 4, [17] = 4,
};
static BOOL record_fits(const uint8_t *table, size_t n, uint32_t tag, uint32_t size) { return tag >= n || size >= table[tag]; }
#define FITS(table, tag, size) record_fits(table, sizeof table, tag, size)

/* Metal's argument tables, a stage: 31 buffers, 128 textures (A13 and later), 16 samplers. */
enum { BUFFER_SLOTS = 31, TEXTURE_SLOTS = 128, SAMPLER_SLOTS = 16 };

/* Where count bindings from index go in a table of limit slots: what does not fit is left out. NO when none fit. */
static BOOL bind_range(uint32_t index, uint32_t count, uint32_t limit, NSRange *out) {
    if (index >= limit || !count) return NO;
    *out = NSMakeRange(index, MIN(count, limit - index));
    return YES;
}

- (void)render:(id<MTLRenderCommandEncoder>)e tag:(uint32_t)tag rec:(Rec)r task:(uint32_t)task {
    if (!FITS(render_min, tag, r.size)) {
        [self complain:[NSString stringWithFormat:@"render command %u: %u bytes, too short", tag, r.size]];
        return;
    }
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
    case 27: { /* {count, stages}, the heaps */
        uint32_t n = U32(0);
        if (r.size >= 8 + n * 4ull) [self useHeaps:(const uint32_t *)(r.p + 8) count:n task:task encoder:e stages:U32(4) & 0xffff];
        break;
    }
    case 134: { /* {count}, the heaps */
        uint32_t n = U32(0);
        if (r.size >= 4 + n * 4ull) [self useHeaps:(const uint32_t *)(r.p + 4) count:n task:task encoder:e stages:-1];
        break;
    }
    case 116: { /* Metal crashes on a missing pipeline, and on drawing without one */
        id state = [self get:U32(0) task:task];
        if (state) [e setRenderPipelineState:state];
        pipeline_set = state != nil;
        if (tracing) fprintf(stderr, "trace:  pipeline %u %s\n", U32(0), [objc_getAssociatedObject(state, "hvname") UTF8String]);
        break;
    }
    case 125: case 110: case 157: { /* vertex, fragment, tile buffers: {index, count}, {ref, offset}... */
        uint32_t index = U32(0), count = U32(4);
        NSRange range;
        if (r.size < 8 + count * 12ull || !bind_range(index, count, BUFFER_SLOTS, &range)) break;
        count = (uint32_t)range.length;
        __unsafe_unretained id<MTLBuffer> buffers[BUFFER_SLOTS];
        id strong[BUFFER_SLOTS];
        NSUInteger offsets[BUFFER_SLOTS];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 12) task:task];
            buffers[i] = strong[i];
            offsets[i] = (NSUInteger)U64(12 + i * 12);
        }
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
    case 126: if (U32(0) < BUFFER_SLOTS) [e setVertexBufferOffset:(NSUInteger)U64(4) atIndex:U32(0)]; break;
    case 111: if (U32(0) < BUFFER_SLOTS) [e setFragmentBufferOffset:(NSUInteger)U64(4) atIndex:U32(0)]; break;
    case 114: case 161: { /* fragment, tile textures */
        uint32_t index = U32(0), count = U32(4);
        NSRange range;
        if (r.size < 8 + count * 4ull || !bind_range(index, count, TEXTURE_SLOTS, &range)) break;
        count = (uint32_t)range.length;
        __unsafe_unretained id<MTLTexture> items[TEXTURE_SLOTS];
        id strong[TEXTURE_SLOTS];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
        }
        if (tracing) for (uint32_t i = 0; i < count; i++) {
            id<MTLTexture> x = strong[i];
            HvObject *xo = [self object:U32(8 + i * 4) task:task];
            fprintf(stderr, "trace:  tex %u ref %u %lux%lu fmt %lu type %u swz %d%d%d%d surface %s heap %d valid %d\n", index + i, U32(8 + i * 4), (unsigned long)x.width, (unsigned long)x.height, (unsigned long)x.pixelFormat, xo ? xo->entry[0] & 0xff : 0, x.swizzle.red, x.swizzle.green, x.swizzle.blue, x.swizzle.alpha, xo && xo->surface ? "yes" : "no", x.heap != nil, xo ? xo->host_valid : 0);
        }
        if (tag == 114) [e setFragmentTextures:items withRange:range];
        else [e setTileTextures:items withRange:range];
        break;
    }
    case 112: { /* fragment samplers */
        uint32_t index = U32(0), count = U32(4);
        NSRange range;
        if (r.size < 8 + count * 4ull || !bind_range(index, count, SAMPLER_SLOTS, &range)) break;
        count = (uint32_t)range.length;
        __unsafe_unretained id<MTLSamplerState> items[SAMPLER_SLOTS];
        id strong[SAMPLER_SLOTS];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
        }
        [e setFragmentSamplerStates:items withRange:range];
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
        NSRange range;
        if (r.size < 8 + count * 4ull || !bind_range(index, count, TEXTURE_SLOTS, &range)) break;
        count = (uint32_t)range.length;
        __unsafe_unretained id<MTLTexture> items[TEXTURE_SLOTS];
        id strong[TEXTURE_SLOTS];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
        }
        [e setVertexTextures:items withRange:range];
        break;
    }
    case 127: { /* vertex samplers */
        uint32_t index = U32(0), count = U32(4);
        NSRange range;
        if (r.size < 8 + count * 4ull || !bind_range(index, count, SAMPLER_SLOTS, &range)) break;
        count = (uint32_t)range.length;
        __unsafe_unretained id<MTLSamplerState> items[SAMPLER_SLOTS];
        id strong[SAMPLER_SLOTS];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
        }
        [e setVertexSamplerStates:items withRange:range];
        break;
    }
    case 113: case 128: { /* samplers with LOD clamps: {index, count}, refs, minimums, maximums */
        uint32_t index = U32(0), count = U32(4), all = count;
        NSRange range;
        if (r.size < 8 + count * 12ull || !bind_range(index, count, SAMPLER_SLOTS, &range)) break;
        count = (uint32_t)range.length;
        __unsafe_unretained id<MTLSamplerState> items[SAMPLER_SLOTS];
        id strong[SAMPLER_SLOTS];
        float lo[SAMPLER_SLOTS], hi[SAMPLER_SLOTS];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
            memcpy(&lo[i], r.p + 8 + all * 4 + i * 4, 4);
            memcpy(&hi[i], r.p + 8 + all * 8 + i * 4, 4);
        }
        if (tag == 113) [e setFragmentSamplerStates:items lodMinClamps:lo lodMaxClamps:hi withRange:range];
        else [e setVertexSamplerStates:items lodMinClamps:lo lodMaxClamps:hi withRange:range];
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
        NSRange range;
        if (r.size < 8 + count * 20ull || !bind_range(index, count, BUFFER_SLOTS, &range)) break;
        count = (uint32_t)range.length;
        __unsafe_unretained id<MTLBuffer> buffers[BUFFER_SLOTS];
        id strong[BUFFER_SLOTS];
        NSUInteger offsets[BUFFER_SLOTS], strides[BUFFER_SLOTS];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 20) task:task];
            buffers[i] = strong[i];
            offsets[i] = (NSUInteger)U64(12 + i * 20);
            strides[i] = (NSUInteger)U64(20 + i * 20);
        }
        [e setVertexBuffers:buffers offsets:offsets attributeStrides:strides withRange:range];
        break;
    }
    case 166: if (U32(0) < BUFFER_SLOTS) [e setVertexBufferOffset:(NSUInteger)U64(4) attributeStride:(NSUInteger)U64(12) atIndex:U32(0)]; break;
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
    if (tag >= 200 && !FITS(compute_min, tag - 200, r.size)) {
        [self complain:[NSString stringWithFormat:@"compute command %u: %u bytes, too short", tag, r.size]];
        return;
    }
    if (!pipeline_set && (tag == 200 || tag == 202)) return;
    switch (tag) {
    case 209: {
        MTLRegion region;
        memcpy(&region, r.p, sizeof region);
        [e setStageInRegion:region];
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
        NSRange range;
        if (r.size < 8 + count * 12ull || !bind_range(index, count, BUFFER_SLOTS, &range)) break;
        count = (uint32_t)range.length;
        __unsafe_unretained id<MTLBuffer> buffers[BUFFER_SLOTS];
        id strong[BUFFER_SLOTS];
        NSUInteger offsets[BUFFER_SLOTS];
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
        [e setBuffers:buffers offsets:offsets withRange:range];
        break;
    }
    case 207:
        if (tracing) fprintf(stderr, "trace:  cbuf %u offset now %llu\n", U32(0), (unsigned long long)U64(4));
        if (U32(0) < BUFFER_SLOTS) [e setBufferOffset:(NSUInteger)U64(4) atIndex:U32(0)];
        break;
    case 206: {
        uint32_t index = U32(0), count = U32(4);
        NSRange range;
        if (r.size < 8 + count * 4ull || !bind_range(index, count, TEXTURE_SLOTS, &range)) break;
        count = (uint32_t)range.length;
        __unsafe_unretained id<MTLTexture> items[TEXTURE_SLOTS];
        id strong[TEXTURE_SLOTS];
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
        [e setTextures:items withRange:range];
        break;
    }
    case 204: {
        uint32_t index = U32(0), count = U32(4);
        NSRange range;
        if (r.size < 8 + count * 4ull || !bind_range(index, count, SAMPLER_SLOTS, &range)) break;
        count = (uint32_t)range.length;
        __unsafe_unretained id<MTLSamplerState> items[SAMPLER_SLOTS];
        id strong[SAMPLER_SLOTS];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
        }
        [e setSamplerStates:items withRange:range];
        break;
    }
    case 211: if (U32(8) < BUFFER_SLOTS) [e setThreadgroupMemoryLength:(NSUInteger)U64(0) atIndex:U32(8)]; break;
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
        if (U32(0) && U32(4) && U32(0) <= 256 && U32(4) <= 256) [e setImageblockWidth:U32(0) height:U32(4)];
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
    if (tag >= 300 && !FITS(blit_min, tag - 300, r.size)) {
        [self complain:[NSString stringWithFormat:@"blit command %u: %u bytes, too short", tag, r.size]];
        return;
    }
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
    if (r.size < (tag == 460 ? 20u : 16u)) {
        [self complain:[NSString stringWithFormat:@"info command %u: %u bytes, too short", tag, r.size]];
        return;
    }
    uint32_t ref = U32(0), bufref = U32(4);
    uint64_t off = U64(8);
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
