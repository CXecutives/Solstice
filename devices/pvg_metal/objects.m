- (HvObject *)object:(uint32_t)ref task:(uint32_t)task {
    if (!ref || task >= HV_TASKS) return nil;
    uint64_t list = hv_pvg_lite_task_objects(lite, task);
    uint32_t e[3];
    if (!list || task_copy(self, task, list + (uint64_t)ref * 12, e, 12)) return nil;
    HvObject *__strong *slot = obj_slot(&task_objs[task], ref, YES);
    if (!slot) {
        [self complain:[NSString stringWithFormat:@"task %u names object %u, past any object list", task, ref]];
        return nil;
    }
    HvObject *o = *slot;
    if (o && !memcmp(o->entry, e, 12)) {
        /* macOS 14's driver names a surface before it writes the surface's description: try again a while.
           And it reuses surface ids: a texture over a surface that has since been replaced is made again. */
        BOOL replaced = o->object && (e[0] & 0xff) == OBJ_MAPPED_TEXTURE && hv_pvg_lite_old_driver(lite) &&
                        o->surface != [self currentSurface:o->on_mapping];
        if (replaced) o->retries = 0;
        if ((!o->object || replaced) && (e[0] & 0xff) == OBJ_MAPPED_TEXTURE && o->retries < 600) {
            uint32_t tries = o->retries + 1;
            o = nil;
            HvObject *again = [HvObject new];
            memcpy(again->entry, e, 12);
            again->retries = tries;
            *slot = again;
            uint64_t at = (uint64_t)e[2] << 32 | e[1];
            [self makeMappedTexture:again at:at task:task];
            static int told;
            if (again->object && told++ < 30) fprintf(stderr, "hengevm: pvg-metal: task %u ref %u: texture made on try %u%s\n", task, ref, tries, replaced ? " (surface replaced)" : "");
            return again;
        }
        if (!o->follows) return o;
        if (o->follows->mapped) refresh_pages(self, task, o->follows);
        if (o->follows->generation == o->follows_generation) return o;
    }
    o = [HvObject new];
    memcpy(o->entry, e, 12);
    *slot = o;
    uint32_t type = e[0] & 0xff, size = e[0] >> 8;
    uint64_t at = (uint64_t)e[2] << 32 | e[1];
    switch (type) {
    case OBJ_BUFFER: [self makeBuffer:o at:at task:task]; break;
    case OBJ_TEXTURE: case 3: /* 3: macOS 13's driver, the same {length, page, layout, mips, record} entry */
        [self makeTexture:o at:at size:size task:task]; break;
    case OBJ_FUNCTION: o->object = [self makeFunction:at task:task]; break;
    case OBJ_SERIALIZED: o->object = [self makeSerialized:at length:size task:task]; break;
    case OBJ_LINEAR_TEXTURE: case 9: [self makeLinearTexture:o at:at size:size task:task]; break;
    case 13: [self makeHeap:o at:at task:task]; break;
    case 14: [self makeHeapBuffer:o at:at task:task]; break;
    case 19: /* macOS 27: a buffer, with the same {length, page, flags} entry as type 1 (16 KB ones seen). The guest
                has object info (tags 450...) written into these, so leaving them out broke its argument buffers:
                black layers, and "info 450 ... no buffer" over and over */
        [self makeBuffer:o at:at task:task];
        break;
    case 0: break; /* an empty slot */
    case OBJ_MAPPED_TEXTURE: [self makeMappedTexture:o at:at task:task]; break;
    default: {
        uint32_t w[24] = {0};
        hv_pvg_lite_task_read(lite, task, at, w, sizeof w);
        NSMutableString *m = [NSMutableString stringWithFormat:@"object type %u size %u:", type, size];
        for (int i = 0; i < 24; i++) [m appendFormat:@" %08x", w[i]];
        [self complain:m];
        break;
    }
    }
    return o;
}

- (id)get:(uint32_t)ref task:(uint32_t)task {
    HvObject *o = [self object:ref task:task];
    return o ? o->object : nil;
}

/* The object's guest memory as a buffer, once it has some. */
static id<MTLBuffer> guest_copy(HvReplay *r, uint32_t task, HvObject *o) {
    if (!o->vpage || !o->length) return nil;
    if (!o->mapped && !map_pages(r, task, o)) return nil;
    refresh_pages(r, task, o);
    if (!o->guest_copy) o->guest_copy = buffer_over_mapping(r, o);
    return o->guest_copy;
}

static BOOL has_guest_pages(HvObject *o) {
    uint64_t n = (o->length + 0x3fff) >> 14;
    for (uint64_t i = 0; o->pages && i < n; i++)
        if (o->pages[i]) return YES;
    return NO;
}

/* Between guest memory and the GPU's own copy, in the layout the guest was told. */
- (void)page:(HvObject *)o toGuest:(BOOL)down task:(uint32_t)task blit:(id<MTLBlitCommandEncoder> *)blit commandBuffer:(id<MTLCommandBuffer>)cb {
    id<MTLBuffer> copy = guest_copy(self, task, o);
    if (!copy || !has_guest_pages(o)) return;
    if (o->heap_whole) {
        if (!*blit) *blit = [cb blitCommandEncoder];
        NSUInteger bytes = MIN(copy.length, o->heap_whole.length);
        if (down) [*blit copyFromBuffer:o->heap_whole sourceOffset:0 toBuffer:copy destinationOffset:0 size:bytes];
        else [*blit copyFromBuffer:copy sourceOffset:0 toBuffer:o->heap_whole destinationOffset:0 size:bytes];
        return;
    }
    id<MTLTexture> tex = o->object;
    if (!tex || !o->tex_layout || tex.sampleCount > 1 || tex.isFramebufferOnly) return;
    NSUInteger faces = tex.textureType == MTLTextureTypeCube || tex.textureType == MTLTextureTypeCubeArray ? 6 : 1;
    if (!*blit) *blit = [cb blitCommandEncoder];
    for (uint32_t s = 0; s < o->tex_slices * faces; s++)
        for (uint32_t m = 0; m < o->tex_mips; m++) {
            const uint8_t *mip = o->tex_layout + m * 36;
            uint64_t off, row;
            uint32_t w, h, d;
            memcpy(&off, mip, 8), memcpy(&row, mip + 0x10, 8), memcpy(&w, mip + 0x18, 4), memcpy(&h, mip + 0x1c, 4), memcpy(&d, mip + 0x20, 4);
            uint32_t bh = o->tex_block_h ? o->tex_block_h : 1;
            uint64_t from = o->tex_base + o->tex_stride * s + off;
            uint64_t image = row * ((h + bh - 1) / bh);
            if (from + image * d > o->length) continue;
            if (down)
                [*blit copyFromTexture:tex sourceSlice:s sourceLevel:m sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, d)
                              toBuffer:copy destinationOffset:from destinationBytesPerRow:row destinationBytesPerImage:image];
            else
                [*blit copyFromBuffer:copy sourceOffset:from sourceBytesPerRow:row sourceBytesPerImage:image
                           sourceSize:MTLSizeMake(w, h, d) toTexture:tex destinationSlice:s destinationLevel:m destinationOrigin:MTLOriginMake(0, 0, 0)];
        }
}

/* The guest asks to see what the GPU made: {task, count, refs}. */
- (void)synchronize:(const uint32_t *)a length:(uint32_t)n {
    if (n < 8) return;
    uint32_t task = a[0], count = a[1];
    if (n < 8 + count * 4ull) return;
    id<MTLCommandBuffer> cb = nil;
    id<MTLBlitCommandEncoder> blit = nil;
    for (uint32_t i = 0; i < count; i++) {
        HvObject *o = obj_known(self, task, a[2 + i]);
        if (!o || !o->guest_backed || !o->host_valid) continue;
        if (!cb) cb = [queue commandBuffer];
        [self page:o toGuest:YES task:task blit:&blit commandBuffer:cb];
        o->guest_stale = NO;
    }
    [blit endEncoding];
    if (cb) {
        [self commit:cb channel:0 stamp:0 complete:NO];
        synced++;
    }
}

/* {task, count, {ref, host invalid, host valid, guest invalid, guest valid}}. */
- (void)invalidate:(const uint32_t *)a length:(uint32_t)n {
    if (n < 8 || n < 8 + a[1] * 8ull) return;
    const uint8_t *e = (const uint8_t *)(a + 2);
    for (uint32_t i = 0; i < a[1]; i++, e += 8) {
        HvObject *o = obj_known(self, a[0], *(const uint32_t *)e);
        if (!o) continue;
        if (e[6]) o->guest_stale = YES;
        if (e[7]) o->guest_stale = NO;
        if (e[4]) o->host_valid = NO;
        if (e[5]) o->host_valid = YES;
    }
}
