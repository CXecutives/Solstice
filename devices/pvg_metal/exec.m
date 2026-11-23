/* An exec: its resources, its command buffers and their completion (part of pvg_metal.m). */

/* One exec: {task, resources, buffers}, {ref, flags} per resource, {offset, length} per buffer. */
/* Commits without waiting: the next batch can be encoded while the GPU does this one. */
- (void)commit:(id<MTLCommandBuffer>)cb channel:(uint32_t)ch stamp:(uint32_t)stamp complete:(BOOL)complete {
    int sync = hv_knob.pvg_sync; /* HV_PVG_SYNC: wait for the GPU after every batch */
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

/* The pipelines an exec sets or asks about, made before any is waited for: their compiles (makeSerialized) start
   together, so a frame with several new ones waits about as long as for the slowest. Only command buffers in one
   piece in host memory (nearly all) are looked through. */
- (void)startPipelines:(const uint8_t *)bufs count:(uint32_t)nbuf task:(uint32_t)task {
    for (uint32_t b = 0; b < nbuf; b++) {
        uint64_t off, blen;
        memcpy(&off, bufs + b * 16, 8);
        memcpy(&blen, bufs + b * 16 + 8, 8);
        if (blen > (64u << 20) || blen < 16) continue;
        const uint8_t *p = task_span(self, task, off, blen);
        if (!p) continue;
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
        uint32_t type = info & 0xff;
        if ((uint64_t)(end - p) > seglen) end = p + seglen;
        if (type != 0 && type != 1 && type != 4) continue;
        while (p + 12 <= end) {
            uint32_t tag, size, ref;
            memcpy(&tag, p, 4), memcpy(&size, p + 4, 4);
            if (size < 8 || size > (uint64_t)(end - p)) break;
            BOOL names_pipeline = type == 0 ? tag == 116 : type == 1 ? tag == 208 : (tag == 450 || tag == 457 || tag == 466 || tag == 467);
            if (names_pipeline && size >= 12) {
                memcpy(&ref, p + 8, 4);
                [self object:ref task:task];
            }
            p += size;
        }
    }
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
    [self startPipelines:bufs count:nbuf task:task];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = nil;
    BOOL sync_after = NO, surfaces_blitted = NO;
    for (uint32_t i = 0; i < nres; i++) {
        HvObject *o = [self object:res[i * 2] task:task];
        if (!o) continue;
        if (o->mapped) refresh_pages(self, task, o);
        if (o->surface && [self syncSurface:o->surface blit:&blit commandBuffer:cb]) surfaces_blitted = YES;
        if (hv_knob.pvg_tally && (o->entry[0] & 0xff) == OBJ_MAPPED_TEXTURE) {
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
    /* The views the guest draws with are other textures over the same IOSurface than the copies' views, so Metal's
       own tracking does not order them: what this exec encodes waits for a fence the copies update. */
    if (surfaces_blitted) {
        if (!surfaces_in) surfaces_in = [device newFence];
        [blit updateFence:surfaces_in];
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
        if (!e && type == 1) {
            e = [cb computeCommandEncoder], pipeline_set = NO;
            if (surfaces_blitted) [(id<MTLComputeCommandEncoder>)e waitForFence:surfaces_in];
        }
        if (!e && type == 2) {
            e = [cb blitCommandEncoder];
            if (surfaces_blitted) [(id<MTLBlitCommandEncoder>)e waitForFence:surfaces_in];
        }
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
                    if (e && surfaces_blitted) [(id<MTLRenderCommandEncoder>)e waitForFence:surfaces_in beforeStages:MTLRenderStageVertex];
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
        fprintf(stderr, "hengevm: pvg-metal: %llu execs, %llu draws, %llu failed, %llu synced, %llu remaps, %llu surface copies, %.0f s; encoding %.2f s (%.2f s of it waiting for pipelines), waiting for the GPU %.2f s\n", (unsigned long long)execs, (unsigned long long)draws, (unsigned long long)failed, (unsigned long long)synced, (unsigned long long)remaps, (unsigned long long)surfaces_copied, now_seconds() - t0, encode_time, pipe_wait, gpu_wait_time);
        encode_time = gpu_wait_time = pipe_wait = 0;
    }
    return YES;
}
