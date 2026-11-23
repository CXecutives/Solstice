/* The Mac's screen drawn into the target at the target's own pixels (part of pvg_metal.m). Core Animation scaled the
   Mac-sized frame bilinearly by a fractional factor (1.4x on an iPhone 16 Pro, 1.84x on an iPad Air 4): soft text. Here
   the picture is aspect-fit and centred on whole pixels and scaled by its own pass: nearest pixel at a whole factor
   (exact), Catmull-Rom with a mild contrast-adaptive sharpening when enlarging, an area average when shrinking
   (portrait). A half-float screen gets a little noise against banding when it becomes 8 bits. It runs only when the
   Mac changes the screen. */

typedef enum { FIT_EXACT = 0, FIT_SHARP = 1, FIT_SHRINK = 2 } HvFitMode;
typedef struct {
    uint32_t x, y, w, h; /* the picture in the target, in its pixels from the top left */
    HvFitMode mode;
} HvFit;

/* Where a W x H screen goes in a target of out_w x out_h pixels: aspect-fit and centred, at a whole multiple of the
   screen's pixels when that is within a pixel of the fit. */
static HvFit screen_fit(uint32_t out_w, uint32_t out_h, uint32_t W, uint32_t H) {
    HvFit f = {0, 0, out_w, out_h, FIT_EXACT};
    if (!W || !H || !out_w || !out_h) return f;
    double s = MIN((double)out_w / W, (double)out_h / H), k = floor(s + 1e-9);
    if (k >= 1 && (s - k) * MAX(W, H) < 1.0) {
        f.w = (uint32_t)k * W, f.h = (uint32_t)k * H;
    } else {
        f.w = MIN(out_w, (uint32_t)lround(W * s)), f.h = MIN(out_h, (uint32_t)lround(H * s));
        f.mode = s > 1 ? FIT_SHARP : FIT_SHRINK;
    }
    f.x = (out_w - f.w) / 2, f.y = (out_h - f.h) / 2;
    return f;
}

/* The target's size in pixels: its bounds at its scale, or the screen's own size where it has none (a layer that is
   not laid out, as the GPU test's). Metal's textures go to 16384 a side. */
static void target_pixels(CAMetalLayer *t, uint32_t W, uint32_t H, uint32_t *out_w, uint32_t *out_h) {
    CGSize b = t.bounds.size;
    CGFloat scale = t.contentsScale > 0 ? t.contentsScale : 1;
    double w = round(b.width * scale), h = round(b.height * scale), big = MAX(w, h);
    if (w < 1 || h < 1) {
        *out_w = W, *out_h = H;
        return;
    }
    if (big > 16384) w = floor(w * 16384 / big), h = floor(h * 16384 / big);
    *out_w = (uint32_t)w, *out_h = (uint32_t)h;
}

/* The picture's place in the target's own coordinates (points), from where the presenter draws it. */
static CGRect fit_in_layer(CAMetalLayer *t, uint32_t W, uint32_t H) {
    CGRect bounds = t ? t.bounds : CGRectZero;
    if (!W || !H || bounds.size.width <= 0 || bounds.size.height <= 0) return CGRectZero;
    uint32_t ow, oh;
    target_pixels(t, W, H, &ow, &oh);
    HvFit fit = screen_fit(ow, oh, W, H);
    CGFloat rx = bounds.size.width / ow, ry = bounds.size.height / oh;
#if TARGET_OS_IPHONE
    CGFloat y = fit.y;
#else
    CGFloat y = oh - fit.y - fit.h; /* a Mac's layers count from the bottom */
#endif
    return CGRectMake(bounds.origin.x + fit.x * rx, bounds.origin.y + y * ry, fit.w * rx, fit.h * ry);
}

typedef struct { /* screen_out's parameters, as the shader lays them out */
    float origin[2], size[2], src[2]; /* the picture in the target, in pixels; the screen's size */
    float bright;
    uint32_t mode, half_float, linear, taps, pad;
} ScreenParams;

static NSString *const screen_shaders = @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct V { float4 at [[position]]; float2 uv; };\n"
    "struct P { float2 origin, size, src; float bright; uint mode, half_float, linear, taps, pad; };\n"
    "vertex V screen_v(uint i [[vertex_id]], constant float4 &rect [[buffer(0)]]) {\n"
    "  float2 c = float2(i & 1, (i >> 1) & 1);\n"
    "  V o; o.at = float4(rect.xy + c * rect.zw, 0, 1); o.uv = float2(c.x, 1 - c.y); return o; }\n"
    /* Catmull-Rom from five bilinear taps (the corners of the 4x4 dropped), p in the screen's pixels */
    "static float3 catmull_rom(texture2d<float> t, sampler s, float2 p, float2 n) {\n"
    "  float2 tc = floor(p - 0.5) + 0.5, f = p - tc;\n"
    "  float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f)), w1 = 1.0 + f * f * (-2.5 + 1.5 * f);\n"
    "  float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f)), w3 = f * f * (-0.5 + 0.5 * f), w12 = w1 + w2;\n"
    "  float2 t0 = (tc - 1.0) / n, t3 = (tc + 2.0) / n, t12 = (tc + w2 / w12) / n;\n"
    "  float3 r = t.sample(s, float2(t12.x, t0.y)).rgb * (w12.x * w0.y) + t.sample(s, float2(t0.x, t12.y)).rgb * (w0.x * w12.y)\n"
    "           + t.sample(s, t12).rgb * (w12.x * w12.y) + t.sample(s, float2(t3.x, t12.y)).rgb * (w3.x * w12.y)\n"
    "           + t.sample(s, float2(t12.x, t3.y)).rgb * (w12.x * w3.y);\n"
    "  return r / (w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y); }\n"
    "fragment float4 screen_out(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant P &p [[buffer(0)]]) {\n"
    "  float2 px = (v.at.xy - p.origin) / p.size * p.src;\n" /* where this pixel's centre is on the screen */
    "  float3 c;\n"
    "  if (p.mode == 0) {\n" /* a whole factor: the pixel it covers, exactly */
    "    c = t.read(uint2(clamp(px, float2(0.0), p.src - 1.0))).rgb;\n"
    "  } else if (p.mode == 1) {\n"
    "    c = catmull_rom(t, s, px, p.src);\n"
    /* no darker or lighter than the four nearest pixels (no halos), and sharpened by its difference from bilinear,
       less where the contrast is high already (AMD's CAS idea) */
    "    float2 q = clamp(floor(px - 0.5), float2(0.0), p.src - 1.0), q1 = min(q + 1.0, p.src - 1.0);\n"
    "    float3 a = t.read(uint2(q)).rgb, b = t.read(uint2(q1.x, q.y)).rgb, d = t.read(uint2(q.x, q1.y)).rgb, e = t.read(uint2(q1)).rgb;\n"
    "    float3 lo = min(min(a, b), min(d, e)), hi = max(max(a, b), max(d, e));\n"
    "    float3 amp = sqrt(saturate(min(lo, 1.0 - hi) / max(hi, float3(1e-4))));\n"
    "    c = clamp(c + 0.5 * amp * (c - t.sample(s, px / p.src).rgb), lo, hi);\n"
    "  } else {\n" /* shrinking: the average over the pixel's footprint, taps x taps bilinear samples */
    "    float2 foot = p.src / p.size;\n"
    "    float n = float(p.taps);\n"
    "    c = float3(0.0);\n"
    "    for (uint y = 0; y < p.taps; y++) for (uint x = 0; x < p.taps; x++)\n"
    "      c += t.sample(s, (px + ((float2(x, y) + 0.5) / n - 0.5) * foot) / p.src).rgb;\n"
    "    c /= n * n;\n"
    "  }\n"
    "  if (p.half_float) {\n"
    "    c = saturate(c);\n"
    "    if (p.linear) c = select(1.055 * powr(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);\n"
    "  }\n"
    "  c *= p.bright;\n"
    /* interleaved gradient noise, a fraction of an 8-bit step: smooth gradients without bands */
    "  if (p.half_float) c += (fract(52.9829189 * fract(dot(v.at.xy, float2(0.06711056, 0.00583715)))) - 0.5) / 255.0;\n"
    "  return float4(c, 1); }\n"
    "fragment float4 screen_cursor(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant float &bright [[buffer(1)]]) {\n"
    "  float4 c = t.sample(s, v.uv); return float4(c.rgb * bright, c.a); }\n";

- (BOOL)makeScreenPipelines {
    if (screen_pipe && cursor_pipe) return YES;
    NSError *err = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:screen_shaders options:nil error:&err];
    if (!lib) { [self complain:[NSString stringWithFormat:@"screen shaders: %@", err.localizedDescription]]; return NO; }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"screen_v"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    d.fragmentFunction = [lib newFunctionWithName:@"screen_out"];
    screen_pipe = [device newRenderPipelineStateWithDescriptor:d error:&err];
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
    if (!screen_pipe || !cursor_pipe || !screen_sampler || !cursor_sampler) {
        [self complain:[NSString stringWithFormat:@"screen pipelines: %@", err.localizedDescription]];
        screen_pipe = cursor_pipe = nil;
        return NO;
    }
    return YES;
}

/* The screen drawn into out (all of it: black around the picture), where fit says and as its mode says. The encoder is
   left open, for the pointer. */
- (id<MTLRenderCommandEncoder>)drawScreen:(id<MTLTexture>)tex half:(BOOL)half fit:(HvFit)fit into:(id<MTLTexture>)out
                            commandBuffer:(id<MTLCommandBuffer>)cb {
    float ow = (float)out.width, oh = (float)out.height;
    BOOL fills = fit.x == 0 && fit.y == 0 && fit.w == out.width && fit.h == out.height;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = out;
    pass.colorAttachments[0].loadAction = fills ? MTLLoadActionDontCare : MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass];
    [e setRenderPipelineState:screen_pipe];
    float rect[4] = {fit.x / ow * 2 - 1, 1 - (fit.y + fit.h) / oh * 2, fit.w / ow * 2, fit.h / oh * 2};
    [e setVertexBytes:rect length:sizeof rect atIndex:0];
    uint32_t W = (uint32_t)tex.width, H = (uint32_t)tex.height;
    ScreenParams p = {{(float)fit.x, (float)fit.y}, {(float)fit.w, (float)fit.h}, {(float)W, (float)H}, brightness_now(),
                      fit.mode, half, half && hv_half_mode_get() == 1, 0, 0};
    if (fit.mode == FIT_SHRINK) p.taps = MIN(4u, MAX(2u, (uint32_t)ceil((double)W / MAX(fit.w, 1u))));
    [e setFragmentBytes:&p length:sizeof p atIndex:0];
    [e setFragmentTexture:tex atIndex:0];
    [e setFragmentSamplerState:screen_sampler atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    return e;
}

