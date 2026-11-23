/* The hv_pvg_metal_* functions the device and the app call (part of pvg_metal.m). */

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
        r->compiler = dispatch_queue_create("hengevm.pipelines", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_USER_INITIATED, 0));
        r->archiver = dispatch_queue_create("hengevm.archive", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        r->pipe_lock = OS_UNFAIR_LOCK_INIT;
        r->presenter = dispatch_queue_create("hengevm.present", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        r->cursor_queue = dispatch_queue_create("hengevm.cursor", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        r->present_every = 1.0 / hv_knob.hz;
        r->overlay_matched = -1;
        /* Screenshots of the drawable (the GPU test) want the pointer in it. */
        r->overlay_never = hv_knob.pvg_gpu_test;
        r->screen_lock = OS_UNFAIR_LOCK_INIT;
        r->walk_epoch = 1;
        r->mapped_textures = [NSMutableDictionary new];
        r->surfaces = [NSMutableDictionary new];
        r->planar = [NSMutableDictionary new];
        r->planar_uses = [NSMutableDictionary new];
        r->planar_hashes = [NSMutableDictionary new];
        r->complaints = [NSMutableSet new];
        r->shot = hv_knob.pvg_shot;
        [r openArchive];
#if !TARGET_OS_IPHONE
        if (hv_knob.pvg_gpu_test) r->layer = [CAMetalLayer layer];
#endif
#if !TARGET_OS_IPHONE
        if (r->shot) {
            double every = hv_knob.pvg_shot_secs;
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
        [r flushPipelines];
        dispatch_sync(r->worker, ^{
            r->lite = NULL;
            for (uint32_t t = 0; t < HV_TASKS; t++) obj_clear(&r->task_objs[t]);
            r->surfaces = nil;
            r->mapped_textures = nil;
            r->planar = nil;
            r->screen_tex = nil;
            r->cursor_tex = nil;
            r->last_cb = nil;
            r->test_readback = nil;
            free(r->frame); r->frame = NULL;
            free(r->base); r->base = NULL;
            free(r->cursor); r->cursor = NULL;
            for (NSValue *old in r->retired_frames) free(old.pointerValue);
            r->retired_frames = nil;
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
                        [r present:shown];
                    }
                    if (op == 4) [r cursorGlyph:args length:n];
                    if (op == 5 && n >= 8) {
                        os_unfair_lock_lock(&r->screen_lock);
                        r->cursor_shown = args[1] & 1;
                        os_unfair_lock_unlock(&r->screen_lock);
                        if (hv_knob.pvg_cursor_log) fprintf(stderr, "pvgcursor show %u\n", args[1]);
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
        [r flushPipelines]; /* a suspended app may not come back */
        dispatch_sync(r->worker, ^{
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
