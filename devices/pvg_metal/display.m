/* Every possible half-float value to a display byte, as the screen would show it in the current mode (see hv_half_mode). */
static const uint8_t *half_to_byte(void) {
    static uint8_t *tables[2];
    int mode = hv_half_mode_get();
    if (tables[mode]) return tables[mode];
    uint8_t *t = malloc(65536);
    for (uint32_t i = 0; i < 65536; i++) {
        uint16_t bits = (uint16_t)i;
        __fp16 h;
        memcpy(&h, &bits, 2);
        float v = h;
        t[i] = !(v > 0) ? 0 : v >= 1 ? 255 : (uint8_t)(hv_half_shown(v, mode) * 255.0f + 0.5f);
    }
    tables[mode] = t;
    return t;
}

/* Op 4: a new pointer image in the kernel task's memory, premultiplied BGRA:
   {port, 0, offset, mapped length, stride, width, height, hot x, hot y, sum}. */
- (void)cursorGlyph:(const uint32_t *)a length:(uint32_t)n {
    if (n < 0x2c) return;
    uint64_t off, stride;
    memcpy(&off, a + 2, 8), memcpy(&stride, a + 6, 8);
    uint16_t w, h, hx, hy;
    memcpy(&w, (const uint8_t *)a + 0x20, 2), memcpy(&h, (const uint8_t *)a + 0x22, 2);
    memcpy(&hx, (const uint8_t *)a + 0x24, 2), memcpy(&hy, (const uint8_t *)a + 0x26, 2);
    if (!w || !h || w > 512 || h > 512 || stride < (uint64_t)w * 4 || stride > 8192) return;
    uint8_t *bits = malloc((size_t)stride * h);
    if (hv_pvg_lite_task_read(lite, 0, off, bits, (uint32_t)stride * h)) {
        free(bits);
        [self complain:@"pointer image unreadable"];
        return;
    }
    free(cursor);
    MTLTextureDescriptor *ct = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    ct.storageMode = MTLStorageModeShared;
    id<MTLTexture> glyph = [device newTextureWithDescriptor:ct];
    [glyph replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:bits bytesPerRow:(NSUInteger)stride];
    os_unfair_lock_lock(&screen_lock);
    cursor = bits, cursor_w = w, cursor_h = h, cursor_stride = (uint32_t)stride, cursor_hot_x = hx, cursor_hot_y = hy;
    cursor_tex = glyph;
    cursor_seq++;
    os_unfair_lock_unlock(&screen_lock);
    if (getenv("HV_PVG_CURSOR_LOG")) fprintf(stderr, "pvgcursor glyph %ux%u hot %d,%d stride %u first alpha %u\n", w, h, hx, hy, (uint32_t)stride, bits[(size_t)(h / 2) * stride + (size_t)(w / 2) * 4 + 3]);
    [self drawCursor];
}

- (BOOL)hasDisplayLayer {
    os_unfair_lock_lock(&screen_lock);
    BOOL attached = layer != nil;
    os_unfair_lock_unlock(&screen_lock);
    return attached;
}

/* Puts back what the pointer covered, and draws it where the shared page says it is now. */
- (void)drawCursor {
    if ([self hasDisplayLayer]) {
        [self cursorChanged];
        return;
    }
    if (!frame || !base) return;
    uint32_t w = frame_w, h = frame_h;
    for (int y = drawn_y; y < drawn_y + drawn_h; y++) memcpy(frame + (size_t)y * w * 4 + (size_t)drawn_x * 4, base + (size_t)y * w * 4 + (size_t)drawn_x * 4, (size_t)drawn_w * 4);
    drawn_w = drawn_h = 0;
    const uint8_t *page = hv_pvg_lite_display_page(lite);
    if (!page || !cursor || !(cursor_shown || page[0xe04])) return;
    uint32_t where = __atomic_load_n((const uint32_t *)(page + 0xe00), __ATOMIC_ACQUIRE);
    if (getenv("HV_PVG_CURSOR_LOG")) {
        static uint32_t last;
        if (where != last) fprintf(stderr, "pvgcursor at %u,%u shown %d flag %d\n", where & 0xffff, where >> 16, cursor_shown, page[0xe04]);
        last = where;
    }
    if (where == 0xffffffff) return;
    /* Bigger than the guest draws it. The hot spot stays where it points. */
    const int scale = cursor_scale();
    /* The pointer's place is in the display mode's pixels; a scaled resolution's frame is smaller than the mode. */
    uint32_t mw = w, mh = h;
    hv_pvg_lite_mode(&mw, &mh);
    if (!mw || !mh) mw = w, mh = h;
    int x = (int)((uint64_t)(where & 0xffff) * w / mw) - cursor_hot_x * scale, y = (int)((uint64_t)(where >> 16) * h / mh) - cursor_hot_y * scale;
    int cw = (int)cursor_w * scale, ch = (int)cursor_h * scale;
    int x0 = x < 0 ? 0 : x, y0 = y < 0 ? 0 : y;
    int x1 = x + cw > (int)w ? (int)w : x + cw, y1 = y + ch > (int)h ? (int)h : y + ch;
    if (x1 <= x0 || y1 <= y0) return;
    for (int py = y0; py < y1; py++) {
        const uint8_t *row = cursor + (size_t)((py - y) / scale) * cursor_stride;
        uint8_t *dst = frame + (size_t)py * w * 4 + (size_t)x0 * 4;
        for (int px = x0; px < x1; px++, dst += 4) {
            const uint8_t *src = row + (size_t)((px - x) / scale) * 4;
            uint32_t keep = 255u - src[3];
            dst[0] = (uint8_t)(src[0] + (dst[0] * keep + 127) / 255);
            dst[1] = (uint8_t)(src[1] + (dst[1] * keep + 127) / 255);
            dst[2] = (uint8_t)(src[2] + (dst[2] * keep + 127) / 255);
        }
    }
    drawn_x = x0, drawn_y = y0, drawn_w = x1 - x0, drawn_h = y1 - y0;
}

static NSString *const screen_shaders = @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct V { float4 at [[position]]; float2 uv; };\n"
    "vertex V screen_v(uint i [[vertex_id]], constant float4 &rect [[buffer(0)]]) {\n"
    "  float2 c = float2(i & 1, (i >> 1) & 1);\n"
    "  V o; o.at = float4(rect.xy + c * rect.zw, 0, 1); o.uv = float2(c.x, 1 - c.y); return o; }\n"
    "fragment float4 screen_plain(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant float &bright [[buffer(1)]]) {\n"
    "  return float4(t.sample(s, v.uv).rgb * bright, 1); }\n"
    "fragment float4 screen_linear(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant uint &mode [[buffer(0)]],\n"
    "                              constant float &bright [[buffer(1)]]) {\n"
    "  float3 c = saturate(t.sample(s, v.uv).rgb);\n"
    "  if (mode == 1) c = select(1.055 * powr(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);\n"
    "  return float4(c * bright, 1); }\n"
    "fragment float4 screen_cursor(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant float &bright [[buffer(1)]]) {\n"
    "  float4 c = t.sample(s, v.uv); return float4(c.rgb * bright, c.a); }\n";

- (BOOL)prepareScreenForLayer:(CAMetalLayer *)target {
    if (!screen_pipe || !linear_pipe || !cursor_pipe) {
        NSError *err = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:screen_shaders options:nil error:&err];
        if (!lib) { [self complain:[NSString stringWithFormat:@"screen shaders: %@", err.localizedDescription]]; return NO; }
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"screen_v"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        d.fragmentFunction = [lib newFunctionWithName:@"screen_plain"];
        screen_pipe = [device newRenderPipelineStateWithDescriptor:d error:&err];
        d.fragmentFunction = [lib newFunctionWithName:@"screen_linear"];
        linear_pipe = [device newRenderPipelineStateWithDescriptor:d error:&err];
        d.fragmentFunction = [lib newFunctionWithName:@"screen_cursor"];
        d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        cursor_pipe = [device newRenderPipelineStateWithDescriptor:d error:&err];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        screen_sampler = [device newSamplerStateWithDescriptor:sd];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
        cursor_sampler = [device newSamplerStateWithDescriptor:sd];
        if (!screen_pipe || !linear_pipe || !cursor_pipe || !screen_sampler || !cursor_sampler) { [self complain:[NSString stringWithFormat:@"screen pipelines: %@", err.localizedDescription]]; return NO; }
    }
    // Pipelines are shared, but a newly connected monitor has a fresh layer.
    if (prepared_layer != target) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        target.device = device;
        target.pixelFormat = MTLPixelFormatBGRA8Unorm;
        target.framebufferOnly = !getenv("HV_PVG_GPU_TEST"); /* the GPU test copies the drawable out */
        target.allowsNextDrawableTimeout = YES;
        target.maximumDrawableCount = 3;
        [CATransaction commit];
        prepared_layer = target;
        fprintf(stderr, "hengevm: pvg-metal: half-float display surfaces are shown %s (HV_PVG_HALF=%s)\n",
                hv_half_mode_get() == 1 ? "as LINEAR light with an sRGB encode" : "as display-encoded values, passed through", hv_half_mode_get() == 1 ? "linear" : "encoded/default");
    }
    return YES;
}

/* The display, drawn by the GPU. Waiting for a drawable can take until the screen's next
   refresh, so that happens on a thread of its own and never holds up the guest's GPU work:
   this only says what to show next. Whatever is newest when a drawable comes is what is shown. */
- (void)kickPresenter:(BOOL)fresh {
    /* screen_lock held */
    if (atomic_load(&stopping)) return;
    if (fresh) screen_requests++;
    if (presenter_running || !layer || !screen_tex || drawable_retry_pending) return;
    if (drawable_retry_cooldown) {
        double delay = drawable_retry_cooldown - now_seconds();
        if (delay > 0) {
            if (!fresh) return;
            // Coalesce fresh work arriving during cooldown; it may be the guest's
            // last update. Automatic retries alone never reopen an exhausted budget.
            drawable_retry_pending = YES;
            uint64_t generation = layer_generation;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), presenter, ^{
                os_unfair_lock_lock(&self->screen_lock);
                if (self->layer_generation == generation) {
                    self->drawable_retry_pending = NO;
                    self->drawable_retry_cooldown = self->drawable_retry_deadline = 0;
                    [self kickPresenter:NO];
                }
                os_unfair_lock_unlock(&self->screen_lock);
            });
            return;
        }
        drawable_retry_cooldown = drawable_retry_deadline = 0;
    }
    presenter_running = YES;
    dispatch_async(presenter, ^{ [self presentLoop]; });
}

- (void)showOnLayer:(uint64_t)mapping {
    HvObject *surface = hv_pvg_lite_old_driver(lite) ? [self currentSurface:mapping] : (surfaces[@(mapping)] ?: [self newSurface:mapping]); /* not met yet: a resumed machine's screen */
    if (!surface) { [self complain:[NSString stringWithFormat:@"swap to unknown surface %llu", mapping]]; return; }
    on_screen = mapping;
    BOOL half = surface->fourcc == 'RGhA';
    if (!screen_tex) fprintf(stderr, "hengevm: display scanout format %s (%ux%u)\n",
                             half ? "RGBA16Float" : "BGRA8Unorm", surface->surface_w, surface->surface_h);
    if (!surface->scanout) {
        MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:half ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm
                                                                                     width:surface->surface_w height:surface->surface_h mipmapped:NO];
        t.storageMode = MTLStorageModeShared;
        t.usage = MTLTextureUsageShaderRead;
        if (linear_texture_fits(device, t, surface->first, surface->row, ((id<MTLBuffer>)surface->object).length))
            surface->scanout = [(id<MTLBuffer>)surface->object newTextureWithDescriptor:t offset:surface->first bytesPerRow:surface->row];
        if (!surface->scanout) { [self complain:[NSString stringWithFormat:@"no scanout for surface %llu, row %llu", mapping, surface->row]]; return; }
    }
    os_unfair_lock_lock(&screen_lock);
    if (screen_tex && (screen_w != surface->surface_w || screen_h != surface->surface_h)) [self targetChanged]; /* a new mode */
    screen_tex = surface->scanout, screen_half = half, screen_w = surface->surface_w, screen_h = surface->surface_h;
    screen_dirty = YES;
    [self kickPresenter:YES];
    os_unfair_lock_unlock(&screen_lock);
}

/* The pointer moved or changed, with no need to go through the GPU queue's worker: its layer moves, or, while that is
   not laid out, the screen is drawn again with the pointer in it. */
- (void)cursorChanged {
    os_unfair_lock_lock(&screen_lock);
    if (cursor_layer_ok) [self queueCursorUpdate];
    else if (screen_tex) {
        screen_dirty = YES;
        [self kickPresenter:YES];
    }
    os_unfair_lock_unlock(&screen_lock);
}

/* One layer update on its way, at most one a refresh: the newest position is read when it runs. screen_lock held. */
- (void)queueCursorUpdate {
    if (cursor_queued || atomic_load(&stopping) || !cursor_queue) return;
    cursor_queued = YES;
    double wait = cursor_next - now_seconds();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, wait > 0 ? (int64_t)(wait * NSEC_PER_SEC) : 0), cursor_queue, ^{ [self updateCursorLayer]; });
}

/* The target, or its size, changed (the app lays its view out again, or another screen takes over): the pointer goes
   back into the frame until the layout has settled, then onto its layer again (enableCursorLayer). screen_lock held,
   with the new target's generation. */
- (void)targetChanged {
    if (!cursor_queue) return;
    cursor_layer_ok = NO;
    overlay_hold = YES;
    [self queueCursorUpdate]; /* hides it, or takes it off a target that went */
    if (overlay_never || !layer) return;
    uint64_t generation = layer_generation;
    /* SwiftUI's layout animations here take 0.25 s, a rotation about 0.35 s. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 450 * NSEC_PER_MSEC), cursor_queue, ^{ [self enableCursorLayer:generation]; });
}

- (void)enableCursorLayer:(uint64_t)generation {
    os_unfair_lock_lock(&screen_lock);
    BOOL settled = layer_generation == generation && layer && !atomic_load(&stopping);
    if (settled) {
        cursor_layer_ok = YES;
        overlay_hold = YES; /* shown once a frame without the pointer in it is on screen */
        if (screen_tex) {
            screen_dirty = YES;
            [self kickPresenter:YES];
        }
    }
    os_unfair_lock_unlock(&screen_lock);
}

/* A frame drawn without the pointer is on screen: the layer can show it now. */
- (void)releaseCursorHold:(uint64_t)generation {
    os_unfair_lock_lock(&screen_lock);
    if (layer_generation == generation && cursor_layer_ok && overlay_hold) {
        overlay_hold = NO;
        [self queueCursorUpdate];
    }
    os_unfair_lock_unlock(&screen_lock);
}

/* The pointer's image for its layer: premultiplied BGRA as the guest gave it, dimmed as the screen is (colour times
   brightness, alpha kept, which is what drawing it into the dimmed frame gave). */
static CGImageRef cursor_image(const uint8_t *bits, uint32_t w, uint32_t h, uint32_t stride, int bright, CGColorSpaceRef space) {
    size_t row = (size_t)w * 4;
    NSMutableData *d = [NSMutableData dataWithLength:row * h];
    uint8_t *out = d.mutableBytes;
    for (uint32_t y = 0; y < h; y++) {
        const uint8_t *in = bits + (size_t)y * stride;
        uint8_t *o = out + (size_t)y * row;
        for (size_t x = 0; x < row; x += 4) {
            for (int c = 0; c < 3; c++) o[x + c] = (uint8_t)((in[x + c] * bright + 500) / 1000);
            o[x + 3] = in[x + 3];
        }
    }
    CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)d);
    CGImageRef img = dp ? CGImageCreate(w, h, 8, 32, row, space, (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                                        dp, NULL, false, kCGRenderingIntentDefault) : NULL;
    CGDataProviderRelease(dp);
    return img;
}

/* Cursor queue: the pointer's layer where the guest's shared page says the pointer is now. Off the main thread, in a
   transaction of its own: Core Animation takes layer changes from any thread. */
- (void)updateCursorLayer {
    /* Nothing of Core Animation's under screen_lock: the main thread takes that lock while it lays out layers. */
    int bright = (int)(brightness_now() * 1000 + 0.5f);
    CGFloat scale = cursor_scale();
    os_unfair_lock_lock(&screen_lock);
    cursor_queued = NO;
    cursor_next = now_seconds() + hv_present_every(present_every, hv_pvg_present_hz()); /* paced as the screen */
    CAMetalLayer *target = atomic_load(&stopping) ? nil : layer;
    BOOL visible = target && cursor_layer_ok && !overlay_hold && cursor && screen_w && screen_h;
    uint32_t W = screen_w, H = screen_h, cw = cursor_w, ch = cursor_h, stride = cursor_stride;
    int hx = cursor_hot_x, hy = cursor_hot_y;
    BOOL shown = cursor_shown;
    uint64_t seq = cursor_seq;
    NSData *bits = visible && (seq != overlay_seq || bright != overlay_bright || overlay_matched < 0)
                       ? [NSData dataWithBytes:cursor length:(size_t)stride * ch] : nil;
    os_unfair_lock_unlock(&screen_lock);
    int matched = target && target.colorspace != NULL;
    if (visible && !bits && matched != overlay_matched) { /* only the colour matching changed */
        os_unfair_lock_lock(&screen_lock);
        if (cursor && cursor_seq == seq) bits = [NSData dataWithBytes:cursor length:(size_t)stride * ch];
        os_unfair_lock_unlock(&screen_lock);
        if (!bits) visible = NO; /* a new image is on its way, with its own update */
    }
    const uint8_t *page = target && lite ? hv_pvg_lite_display_page(lite) : NULL; /* target: not stopping */
    uint32_t where = page ? __atomic_load_n((const uint32_t *)(page + 0xe00), __ATOMIC_ACQUIRE) : 0xffffffff;
    if (where == 0xffffffff || !(shown || page[0xe04])) visible = NO;
    CGRect bounds = target ? target.bounds : CGRectZero;
    NSString *gravity = target.contentsGravity;
    CGRect content = bounds;
    if (W && H && bounds.size.width > 0 && bounds.size.height > 0 && ![gravity isEqualToString:kCAGravityResize]) {
        CGFloat sx = bounds.size.width / W, sy = bounds.size.height / H;
        CGFloat s = [gravity isEqualToString:kCAGravityResizeAspectFill] ? MAX(sx, sy) : MIN(sx, sy);
        content = CGRectMake(bounds.origin.x + (bounds.size.width - W * s) / 2, bounds.origin.y + (bounds.size.height - H * s) / 2, W * s, H * s);
        if (![gravity isEqualToString:kCAGravityResizeAspect] && ![gravity isEqualToString:kCAGravityResizeAspectFill]) visible = NO;
    }
    if (content.size.width <= 0 || content.size.height <= 0) visible = NO;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!overlay_box && target) {
        overlay_box = [CALayer layer];
        overlay_box.masksToBounds = YES;
        overlay_box.anchorPoint = CGPointZero;
        overlay_glyph = [CALayer layer];
        overlay_glyph.anchorPoint = CGPointZero;
        [overlay_box addSublayer:overlay_glyph];
    }
    CAMetalLayer *parent = overlay_parent;
    if (overlay_box && parent != target) {
        [overlay_box removeFromSuperlayer];
        if (target) [target addSublayer:overlay_box];
        overlay_parent = target;
    }
    if (overlay_box) overlay_box.hidden = !visible;
    if (visible && overlay_box) {
        if (bits) {
            CGColorSpaceRef space = matched ? CGColorSpaceRetain(target.colorspace) : CGColorSpaceCreateDeviceRGB();
            CGImageRef img = cursor_image(bits.bytes, cw, ch, stride, bright, space);
            CGColorSpaceRelease(space);
            overlay_glyph.contents = (__bridge_transfer id)img;
            overlay_seq = seq, overlay_bright = bright, overlay_matched = matched;
        }
        /* Where the presenter would draw it: the place in the display mode's pixels (the surface can be smaller,
           a scaled resolution), the size from the guest's image times the pointer scale. */
        uint32_t MW = W, MH = H;
        hv_pvg_lite_mode(&MW, &MH);
        if (!MW || !MH) MW = W, MH = H;
        CGFloat x = ((CGFloat)(where & 0xffff) - hx * scale) / MW, y = ((CGFloat)(where >> 16) - hy * scale) / MH;
        CGFloat w = cw * scale / MW, h = ch * scale / MH;
#if !TARGET_OS_IPHONE
        y = 1 - y - h; /* a Mac's layers count from the bottom */
#endif
        overlay_box.bounds = CGRectMake(0, 0, content.size.width, content.size.height);
        overlay_box.position = content.origin;
        overlay_glyph.frame = CGRectMake(x * content.size.width, y * content.size.height, w * content.size.width, h * content.size.height);
        NSString *filter = atomic_load(&cursor_sharp) ? kCAFilterNearest : kCAFilterLinear;
        overlay_glyph.magnificationFilter = filter;
        overlay_glyph.minificationFilter = filter;
    }
    [CATransaction commit];
    [CATransaction flush];
}

- (void)presentLoop {
    for (;;) @autoreleasepool {
        /* Under a present cap (hot, Low Power Mode: hv_pvg_present_hz) the next frame is taken a whole interval after
           the last present, the newest there is then; frames meanwhile only mark the screen dirty. */
        double wait = hv_present_wait(last_present, now_seconds(), present_every,
                                      hv_present_every(present_every, hv_pvg_present_hz()));
        if (wait > 0) usleep((useconds_t)(wait * 1e6));
        os_unfair_lock_lock(&screen_lock);
        if (!screen_dirty || !layer) {
            presenter_running = NO;
            os_unfair_lock_unlock(&screen_lock);
            return;
        }
        screen_dirty = NO;
        CAMetalLayer *target = layer; // retained across nextDrawable and a concurrent disconnect
        uint64_t generation = layer_generation, requests = screen_requests;
        id<MTLTexture> tex = screen_tex, ctex = cursor_tex;
        BOOL half = screen_half, shown = cursor_shown;
        uint32_t W = screen_w, H = screen_h, cw0 = cursor_w, ch0 = cursor_h;
        int hx = cursor_hot_x, hy = cursor_hot_y;
        os_unfair_lock_unlock(&screen_lock);
        if (![self prepareScreenForLayer:target]) {
            os_unfair_lock_lock(&screen_lock);
            BOOL changed = layer_generation != generation;
            if (!changed) presenter_running = NO;
            os_unfair_lock_unlock(&screen_lock);
            if (changed) continue;
            return;
        }
        CGSize want = CGSizeMake(W, H);
        if (!CGSizeEqualToSize(target.drawableSize, want)) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            target.drawableSize = want;
            [CATransaction commit];
        }
        id<CAMetalDrawable> drawable = [target nextDrawable]; /* the wait is here */
        if (!drawable) {
            os_unfair_lock_lock(&screen_lock);
            screen_dirty = YES;
            BOOL changed = layer_generation != generation;
            if (!changed) {
                presenter_running = NO;
                double now = now_seconds();
                if (!drawable_retry_deadline) drawable_retry_deadline = now + 2;
                BOOL exhausted = now >= drawable_retry_deadline;
                if (exhausted) {
                    drawable_retry_cooldown = now + 1;
                    // A fresh frame/cursor event received while nextDrawable waited
                    // must not lose its wakeup at the transition into cooldown.
                    if (screen_requests != requests) [self kickPresenter:YES];
                } else {
                    // A monitor can connect before its first drawable is available.
                    // Retry even if the guest is idle, but never poll a hidden target forever.
                    drawable_retry_pending = YES;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), presenter, ^{
                        os_unfair_lock_lock(&self->screen_lock);
                        if (self->layer_generation == generation) {
                            self->drawable_retry_pending = NO;
                            [self kickPresenter:NO];
                        }
                        os_unfair_lock_unlock(&self->screen_lock);
                    });
                }
            }
            os_unfair_lock_unlock(&screen_lock);
            if (changed) continue;
            return;
        }
        /* Something newer came during the wait? Then that is the frame to show. */
        os_unfair_lock_lock(&screen_lock);
        tex = screen_tex, half = screen_half, ctex = cursor_tex, shown = cursor_shown;
        cw0 = cursor_w, ch0 = cursor_h, hx = cursor_hot_x, hy = cursor_hot_y;
        BOOL pointer_in_frame = !cursor_layer_ok, hold = overlay_hold; /* else its layer shows it */
        BOOL same_target = layer_generation == generation && layer == target;
        BOOL same_size = screen_w == W && screen_h == H;
        if (same_target && same_size) {
            screen_dirty = NO;
            drawable_retry_deadline = 0;
        }
        os_unfair_lock_unlock(&screen_lock);
        if (!same_target || !same_size) { /* a target or mode change during nextDrawable */
            os_unfair_lock_lock(&screen_lock);
            screen_dirty = YES;
            os_unfair_lock_unlock(&screen_lock);
            continue;
        }
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass];
        [e setRenderPipelineState:half ? linear_pipe : screen_pipe];
        float rect[4] = {-1, -1, 2, 2};
        [e setVertexBytes:rect length:sizeof rect atIndex:0];
        [e setFragmentTexture:tex atIndex:0];
        [e setFragmentSamplerState:screen_sampler atIndex:0];
        if (half) {
            uint32_t half_mode = (uint32_t)hv_half_mode_get();
            [e setFragmentBytes:&half_mode length:sizeof half_mode atIndex:0];
        }
        float bright = brightness_now();
        [e setFragmentBytes:&bright length:sizeof bright atIndex:1];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        const uint8_t *page = hv_pvg_lite_display_page(lite);
        uint32_t where = page ? __atomic_load_n((const uint32_t *)(page + 0xe00), __ATOMIC_ACQUIRE) : 0xffffffff;
        if (pointer_in_frame && ctex && where != 0xffffffff && (shown || page[0xe04])) {
            const float scale = cursor_scale();
            float x = (float)(where & 0xffff) - hx * scale, y = (float)(where >> 16) - hy * scale;
            float cw = cw0 * scale, ch = ch0 * scale;
            /* The pointer's place is in the display mode's pixels, not the surface's: with a scaled resolution
               chosen in macOS (1280x988 on a 1864x1440 display) the surface is smaller than the mode, and the
               pointer was drawn further right and down than where it clicks. Seen on a phone: the pointer at
               1842 of 1864 with a 1600 wide surface, and the Dock's magnification under where it is drawn now.
               The guest stops the pointer 128 x (mode / surface - 1) pixels short of the right and bottom edges
               there and crops its image, while what it clicks goes on to the edge; open. */
            uint32_t MW = W, MH = H;
            hv_pvg_lite_mode(&MW, &MH);
            if (!MW || !MH) MW = W, MH = H;
            float r[4] = {x / MW * 2 - 1, 1 - (y + ch) / MH * 2, cw / MW * 2, ch / MH * 2};
            [e setRenderPipelineState:cursor_pipe];
            [e setVertexBytes:r length:sizeof r atIndex:0];
            [e setFragmentTexture:ctex atIndex:0];
            cursor_settings_refresh();
            [e setFragmentSamplerState:atomic_load(&cursor_sharp) ? cursor_sampler : screen_sampler atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }
        [e endEncoding];
#if !TARGET_OS_IPHONE
        if (getenv("HV_PVG_GPU_TEST")) { /* the same pixels for a screenshot: this is the path a phone runs */
            NSUInteger bytes = (NSUInteger)W * H * 4;
            if (!test_readback || test_readback.length < bytes) test_readback = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
            id<MTLBuffer> rb = test_readback;
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
                      toBuffer:rb destinationOffset:0 destinationBytesPerRow:(NSUInteger)W * 4 destinationBytesPerImage:bytes];
            [b endEncoding];
            [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                (void)done;
                dispatch_async(self->worker, ^{
                    if (!self->frame || self->frame_w != W || self->frame_h != H) {
                        self->frame = malloc((size_t)W * H * 4), self->frame_w = W, self->frame_h = H;
                    }
                    memcpy(self->frame, rb.contents, (size_t)W * H * 4);
                    self->frames++;
                });
            }];
        }
#endif
        /* Once this frame is on screen: the pointer's layer may show (it was waiting for a frame without the pointer
           drawn in), and a target with a frame of its own on it is opaque from then on (the compositor need not blend
           it with what is behind; before its first frame what is behind is the boot screen). */
        BOOL first_here = opaque_layer != target;
        if ((!pointer_in_frame && hold) || first_here) {
            __weak CAMetalLayer *weak_target = target;
            [drawable addPresentedHandler:^(id<MTLDrawable> shown_drawable) {
                (void)shown_drawable;
                /* never a lock of ours on the thread presenting it: queued */
                if (!pointer_in_frame && hold) dispatch_async(self->cursor_queue, ^{ [self releaseCursorHold:generation]; });
                if (first_here) dispatch_async(self->presenter, ^{
                    CAMetalLayer *t = weak_target;
                    if (!t) return;
                    self->opaque_layer = t;
                    if (t.opaque) return;
                    [CATransaction begin];
                    [CATransaction setDisableActions:YES];
                    t.opaque = YES;
                    [CATransaction commit];
                    [CATransaction flush];
                });
            }];
        }
        // Serialize the final check and commit with set_layer: a switch that has
        // returned must not be followed by a commit to its old target.
        os_unfair_lock_lock(&screen_lock);
        if (layer_generation == generation && layer == target) {
            /* No faster than macOS draws (HV_HZ): a ProMotion panel stays at that rate instead of following every
               change, and three drawables queue at most that far ahead. */
            [cb presentDrawable:drawable afterMinimumDuration:present_every];
            [cb commit];
            last_present = now_seconds();
            gpu_frames++;
        } else {
            screen_dirty = YES;
        }
        os_unfair_lock_unlock(&screen_lock);
    }
}

/* What the display should show: at most a few times a second by CPU, for tests and the boot's first frames. */
- (void)present:(uint64_t)mapping {
    if (atomic_load(&stopping)) return;
    double now = now_seconds();
    on_screen = mapping;
    if ([self hasDisplayLayer]) {
        late = NO;
        [self showOnLayer:mapping];
        return;
    }
    if (now - last_capture < 0.066) { /* 15 a second is plenty until this is GPU work */
        late_mapping = mapping, late = YES;
        if (!late_queued) {
            late_queued = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 70 * NSEC_PER_MSEC), worker, ^{
                self->late_queued = NO;
                if (self->late) [self present:self->late_mapping];
            });
        }
        return;
    }
    late = NO;
    HvObject *surface = hv_pvg_lite_old_driver(lite) ? [self currentSurface:mapping] : (surfaces[@(mapping)] ?: [self newSurface:mapping]); /* not met yet: a resumed machine's screen */
    if (!surface) { [self complain:[NSString stringWithFormat:@"swap to unknown surface %llu", mapping]]; return; }
    last_capture = now;
    [last_cb waitUntilCompleted]; /* the CPU copies the pixels here, so the GPU must be done with them */
    NSUInteger bpp = surface->fourcc == 'RGhA' ? 8 : 4, row = surface->row;
    uint32_t w = surface->surface_w, h = surface->surface_h;
    if (!frame || !base || frame_w != w || frame_h != h) {
        free(base);
        base = malloc((size_t)w * h * 4);
        uint8_t *old = frame;
        frame = calloc((size_t)w * h, 4); /* the old one may be on screen for a moment yet: a small leak beats a crash */
        if (old) {
            if (!retired_frames) retired_frames = [NSMutableArray new];
            [retired_frames addObject:[NSValue valueWithPointer:old]];
        }
        frame_w = w, frame_h = h;
        drawn_w = drawn_h = 0;
    }
    uint8_t *out = base;
    const uint8_t *src = surface->mapped + surface->first;
    const uint8_t *lut = half_to_byte();
    if (bpp == 8) {
        for (uint32_t y = 0; y < h; y++) {
            const uint16_t *in = (const uint16_t *)(src + y * row);
            uint8_t *o = out + (size_t)y * w * 4;
            for (uint32_t x = 0; x < w; x++, in += 4, o += 4) {
                o[0] = lut[in[2]], o[1] = lut[in[1]], o[2] = lut[in[0]], o[3] = 255;
            }
        }
    } else {
        for (uint32_t y = 0; y < h; y++) memcpy(out + (size_t)y * w * 4, src + y * row, (size_t)w * 4);
    }
    memcpy(frame, base, (size_t)w * h * 4);
    drawn_w = drawn_h = 0;
    [self drawCursor];
    frames++;
}

#if !TARGET_OS_IPHONE
/* Debugging: HV_PVG_SHOT=prefix keeps what is on the display, every HV_PVG_SHOT_SECS seconds it has changed. */
- (void)saveShot {
    if (!frame || frames == frames_shot) return;
    frames_shot = frames;
    char path[1100];
    snprintf(path, sizeof path, "%s-%04u.png", shot, shots++);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(frame, frame_w, frame_h, 8, (size_t)frame_w * 4, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (dest) {
        CGImageDestinationAddImage(dest, img, NULL);
        CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }
    CFRelease(url), CGImageRelease(img), CGContextRelease(ctx), CGColorSpaceRelease(cs);
}
#endif
