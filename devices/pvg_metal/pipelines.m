/* Functions, pipelines, the saved-pipeline archives and the other serialized objects (part of pvg_metal.m). */

/* A kernel that does nothing. Metal's deserializer aborts the whole app when a compute pipeline's function is nil, which
   happens when this OS cannot load the library macOS sent ("This library format is not supported on this platform", seen on
   iPadOS 17 with macOS 15). The lookup has failed either way, so makeSerialized drops the pipeline: a missing effect, not a
   crash. */
- (id)computeStandIn {
    if (!stand_in) {
        NSError *err = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:@"#include <metal_stdlib>\nkernel void hv_stand_in() {}\n" options:nil error:&err];
        stand_in = [lib newFunctionWithName:@"hv_stand_in"];
        if (!stand_in) [self complain:[NSString stringWithFormat:@"stand-in kernel: %@", err.localizedDescription]];
    }
    return stand_in;
}

- (id)makeFunction:(uint64_t)at task:(uint32_t)task {
    if (hv_knob.pvg_fail_libs) { /* testing: every library refused, as an OS that cannot load them does */
        [self complain:@"library: refused (HV_PVG_FAIL_LIBS)"];
        return nil;
    }
    struct __attribute__((packed)) { uint64_t off; uint32_t len; uint32_t tag, size; } h;
    if (hv_pvg_lite_task_read(lite, task, at, &h, sizeof h)) return nil;
    if (h.tag != 0xf) { /* Apple's host takes only this record as a function */
        [self complain:[NSString stringWithFormat:@"function record tag %u, not 15", h.tag]];
        return nil;
    }
    NSMutableData *lib = [NSMutableData dataWithLength:h.len];
    if (hv_pvg_lite_task_read(lite, task, h.off, lib.mutableBytes, h.len)) return nil;
    /* iOS 17 refuses macOS's libraries as they are (a macOS 15 build, AIR 2.7): relabelled as iOS 17 ones
       (devices/metallib.c), header and the bitcode's target, it loads them. Stage 1 (the header alone) is not
       tried after the library as sent: iOS 17 loads such a library, but every pipeline made from it then fails
       "Target OS is incompatible", the module still saying macOS (issue 44). The stage that worked is tried first
       from then on. Stage 3 (the version metadata too) only when asked for: HV_PVG_RELABEL=3. HV_PVG_NO_RELABEL:
       never. */
    static int start_stage = -1; /* 0: as sent; 1, 2, 3: relabelled */
    int no_relabel = hv_knob.pvg_no_relabel;
    if (start_stage < 0) start_stage = hv_knob.pvg_relabel; /* HV_PVG_RELABEL=N (testing): every library relabelled at stage N from the start */
    NSError *err = nil, *first_err = nil;
    id<MTLLibrary> library = nil;
    int last_stage = no_relabel ? 0 : start_stage >= 3 ? 3 : 2, loaded_at = -1;
    for (int stage = no_relabel ? 0 : start_stage; stage <= last_stage && !library; stage = stage ? stage + 1 : 2) {
        NSMutableData *try = lib;
        if (stage) {
            try = [lib mutableCopy];
            const char *why = NULL;
            if (hv_metallib_relabel(try.mutableBytes, try.length, stage, &why) <= 0) continue;
            if (why) [self complain:[NSString stringWithFormat:@"library: relabelled (stage %d) only in part: %s", stage, why]];
        }
        dispatch_data_t data = dispatch_data_create(try.bytes, try.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        err = nil;
        library = [device newLibraryWithData:data error:&err];
        if (library) loaded_at = stage;
        if (!library && !first_err) first_err = err;
        if (library && (stage != start_stage || (stage && first_err == nil && !hv_knob.pvg_relabel_quiet))) {
            [self complain:[NSString stringWithFormat:@"library: loaded relabelled for iOS 17 (stage %d; as sent: %@)", stage,
                                                      first_err.localizedDescription ?: @"not tried"]];
            start_stage = stage;
        } else if (!library && stage) {
            [self complain:[NSString stringWithFormat:@"library: relabelled (stage %d): %@", stage, err.localizedDescription]];
        }
    }
    if (!library) {
        [self complain:[NSString stringWithFormat:@"library: %@", (first_err ?: err).localizedDescription]];
        return nil;
    }
    {   /* m4 fork: while tracing, keep each library macOS sends, to read its shaders on a Mac. Also, unless
           HV_SHADER_DUMP=0, the first 48 that had to be relabelled (Documents/shaders, as sent): what an OS that
           refuses them was sent, for relabelling to be checked against on a Mac. */
        static int relabelled_kept = 0;
        const char *tf = hv_knob.pvg_trace_file;
        int sd = hv_knob.shader_dump >= 0;
        int keep = sd ? hv_knob.shader_dump != 0 : loaded_at > 0 && relabelled_kept < 48;
        if (keep && !sd) relabelled_kept++;
        if (tf && keep && (sd || hv_pvg_trace_on())) { /* only while tracing (or asked): not on every launch */
            NSString *dir = [[[NSString stringWithUTF8String:tf] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"shaders"];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *name = [NSString stringWithFormat:@"%@-%llx.metallib", library.functionNames.firstObject ?: @"lib", (unsigned long long)at];
            [lib writeToFile:[dir stringByAppendingPathComponent:name] atomically:NO];
        }
    }
    if (library.functionNames.count != 1) { /* Apple's host: "Unexpected function count in library" */
        [self complain:[NSString stringWithFormat:@"library with %lu functions", (unsigned long)library.functionNames.count]];
        return nil;
    }
    return [library newFunctionWithName:library.functionNames.firstObject];
}

/* A pipeline's descriptor from the guest's serialized form, as Apple's host makes it: a failed function lookup or a
   missing vertex, tile or compute function and there is no pipeline. */
- (id)pipelineDescriptor:(uint32_t)tag data:(NSData *)all task:(uint32_t)task {
    const uint32_t *w = all.bytes;
    id<HvMetalSPI> spi = (id)device;
    HvContext *ctx = [HvContext new];
    ctx->replay = self, ctx->task = task;
    if (tag == 0xb) ctx->standIn = [self computeStandIn];
    dispatch_data_t data = dispatch_data_create((const uint8_t *)all.bytes + 16, w[3], NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    id descriptor = tag == 0xe ? [spi newRenderPipelineDescriptorWithSerializedData:data deserializationContext:ctx]
                  : tag == 0x33 ? [spi newTileRenderPipelineDescriptorWithSerializedData:data deserializationContext:ctx]
                                : [spi newComputePipelineDescriptorWithSerializedData:data deserializationContext:ctx];
    if (!descriptor || ctx->failure) {
        [self complain:[NSString stringWithFormat:@"%@ descriptor %u: %@", tag == 0xb ? @"compute" : @"pipeline", tag, ctx->failure]];
        return nil;
    }
    id function = tag == 0xe ? [(MTLRenderPipelineDescriptor *)descriptor vertexFunction]
                : tag == 0x33 ? [(MTLTileRenderPipelineDescriptor *)descriptor tileFunction]
                              : [(MTLComputePipelineDescriptor *)descriptor computeFunction];
    if (!function) {
        [self complain:[NSString stringWithFormat:@"pipeline %u without its %s function", tag, tag == 0xe ? "vertex" : tag == 0x33 ? "tile" : "compute"]];
        return nil;
    }
    return descriptor;
}

/* Saved pipelines. iOS empties its own Metal shader cache between launches, so every boot compiled each of macOS's
   pipelines again (420 to 550 ms apiece on the Duo). They are kept in binary archives instead, in Application Support
   (iOS purges Caches), named for the OS build and GPU: a compiled pipeline is only good for the compiler and GPU that
   made it, and archives from another build are removed rather than loaded.
   Each save writes a new file holding only the pipelines added since the last save, and every file is loaded at start:
   on the Duo, serializing an archive that was loaded from a file wrote only what had been added to it, so one file
   rewritten in place kept losing the earlier boots' pipelines. So the files only grow in number: at start the oldest
   go, if need be, until a session's worth of room is left under ARCHIVE_FILES and 7/8 of the size cap (a pipeline of
   theirs still in use is compiled and saved again once); past the caps a session adds nothing more. They cannot be
   merged: re-serializing a loaded archive loses its content, and which file a pipeline came from is not known.
   HV_PVG_ARCHIVE=0: none (for A/B); HV_PVG_ARCHIVE=reset: start again. HV_PVG_ARCHIVE_MB: the cap (default 768). */
static unsigned long long archive_cap(void) {
    return (unsigned long long)hv_knob.pvg_archive_mb << 20;
}

enum { ARCHIVE_FILES = 256, ARCHIVE_ROOM = 32 }; /* saved files at most; left free for a session at its start */

/* Whether nothing more may be saved, with this many files of this many bytes saved. */
static BOOL archive_full_at(NSUInteger files, unsigned long long bytes, unsigned long long cap) {
    return files >= ARCHIVE_FILES || bytes > cap;
}

/* How many of the oldest saved files (sizes oldest first) go at start, for this session to have room. */
static NSUInteger archive_evict(const unsigned long long *bytes, NSUInteger files, unsigned long long cap) {
    unsigned long long total = 0;
    for (NSUInteger i = 0; i < files; i++) total += bytes[i];
    NSUInteger k = 0;
    while (k < files && (files - k > ARCHIVE_FILES - ARCHIVE_ROOM || total > cap - cap / 8)) total -= bytes[k++];
    return k;
}

- (id<MTLBinaryArchive>)emptyArchive {
    NSError *err = nil;
    id<MTLBinaryArchive> a = [device newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:&err];
    if (!a) fprintf(stderr, "hengevm: pvg-metal: saved pipelines unavailable: %s\n", err.localizedDescription.UTF8String ?: "?");
    return a;
}

- (void)openArchive {
    const char *opt = hv_knob.pvg_archive;
    if (opt && !strcmp(opt, "0")) {
        fprintf(stderr, "hengevm: pvg-metal: saved pipelines off (HV_PVG_ARCHIVE=0)\n");
        return;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *dir = [[fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject
        URLByAppendingPathComponent:@"Henge/Pipelines" isDirectory:YES];
    NSError *err = nil;
    if (!dir || ![fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&err]) {
        fprintf(stderr, "hengevm: pvg-metal: saved pipelines: no folder: %s\n", err.localizedDescription.UTF8String ?: "?");
        return;
    }
    [dir setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil]; /* rebuilt by any boot: not worth a backup */
    char build[64] = "unknown";
    size_t len = sizeof build;
    sysctlbyname("kern.osversion", build, &len, NULL, 0);
    NSString *gpu = [[device.name componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet]
        componentsJoinedByString:@"-"];
    archive_dir = dir;
    archive_prefix = [NSString stringWithFormat:@"pipelines-%s-%@-", build, gpu];
    NSMutableArray<id<MTLBinaryArchive>> *loaded = [NSMutableArray new];
    unsigned long long bytes = 0;
    unsigned unreadable = 0;
    NSArray<NSURL *> *files = [[fm contentsOfDirectoryAtURL:dir includingPropertiesForKeys:nil options:0 error:nil]
        sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [a.lastPathComponent compare:b.lastPathComponent options:NSNumericSearch]; }];
    NSMutableArray<NSURL *> *saved = [NSMutableArray new];
    NSMutableData *sizes = [NSMutableData new];
    for (NSURL *u in files) {
        NSString *name = u.lastPathComponent;
        int n = 0;
        BOOL ours = [name hasPrefix:archive_prefix] && [name hasSuffix:@".bin"] &&
                    sscanf(name.UTF8String + archive_prefix.length, "%d.bin", &n) == 1 && !(opt && !strcmp(opt, "reset"));
        if (!ours) { /* another build, an unfinished save, or a reset */
            [fm removeItemAtURL:u error:nil];
            continue;
        }
        unsigned long long size = [[fm attributesOfItemAtPath:u.path error:nil] fileSize];
        [saved addObject:u];
        [sizes appendBytes:&size length:sizeof size];
        if (n >= archive_next) archive_next = n + 1;
    }
    NSUInteger evicted = archive_evict(sizes.bytes, saved.count, archive_cap());
    for (NSUInteger i = 0; i < saved.count; i++) {
        NSURL *u = saved[i];
        NSString *name = u.lastPathComponent;
        if (i < evicted) { /* the oldest, for room */
            [fm removeItemAtURL:u error:nil];
            continue;
        }
        MTLBinaryArchiveDescriptor *d = [MTLBinaryArchiveDescriptor new];
        d.url = u;
        err = nil;
        id<MTLBinaryArchive> a = [device newBinaryArchiveWithDescriptor:d error:&err];
        if (!a) {
            fprintf(stderr, "hengevm: pvg-metal: saved pipelines: %s unreadable, removed: %s\n", name.UTF8String, err.localizedDescription.UTF8String ?: "?");
            [fm removeItemAtURL:u error:nil];
            unreadable++;
            continue;
        }
        [loaded addObject:a];
        bytes += ((const unsigned long long *)sizes.bytes)[i];
    }
    archive = [self emptyArchive];
    if (!archive) return;
    archives = loaded;
    archive_bytes = bytes;
    archive_full = archive_full_at(loaded.count, bytes, archive_cap());
    fprintf(stderr, "hengevm: pvg-metal: saved pipelines: %lu files, %.1f MB%s%s%s\n", (unsigned long)loaded.count, bytes / 1048576.0,
            unreadable ? " (some unreadable, removed)" : "", evicted ? " (the oldest removed for room)" : "",
            archive_full ? " (full: nothing more is added)" : "");
}

- (id)newState:(uint32_t)tag descriptor:(id)descriptor options:(MTLPipelineOption)options error:(NSError **)err {
    if (tag == 0xe) return [device newRenderPipelineStateWithDescriptor:descriptor options:options reflection:nil error:err];
    if (tag == 0x33) return [device newRenderPipelineStateWithTileDescriptor:descriptor options:options reflection:nil error:err];
    return [device newComputePipelineStateWithDescriptor:descriptor options:options reflection:nil error:err];
}

/* A render (0xe), tile (0x33) or compute (0xb) pipeline, on the compiler queue (several at once). Looked up in the
   saved archives first; on a miss it is compiled, and then added to the archive being filled on the archiver queue,
   so the next boot finds it. */
- (id)pipelineState:(uint32_t)tag descriptor:(id)descriptor error:(NSError **)err {
    double t0 = now_seconds();
    os_unfair_lock_lock(&pipe_lock);
    NSArray<id<MTLBinaryArchive>> *saved = archives;
    BOOL saving = archive != nil;
    os_unfair_lock_unlock(&pipe_lock);
    if (saved.count) {
        [descriptor setBinaryArchives:saved];
        id state = [self newState:tag descriptor:descriptor options:MTLPipelineOptionFailOnBinaryArchiveMiss error:nil];
        if (state) {
            os_unfair_lock_lock(&pipe_lock);
            pipes_hit++;
            hit_ms += (now_seconds() - t0) * 1e3;
            os_unfair_lock_unlock(&pipe_lock);
            return state;
        }
    }
    id state = [self newState:tag descriptor:descriptor options:MTLPipelineOptionNone error:err];
    if (state) {
        os_unfair_lock_lock(&pipe_lock);
        uint64_t compiled = ++pipes_compiled, hit = pipes_hit;
        double each = (compile_ms += (now_seconds() - t0) * 1e3) / compiled, hit_each = hit ? hit_ms / hit : 0.0;
        os_unfair_lock_unlock(&pipe_lock);
        if (compiled == 1 || compiled % 100 == 0)
            fprintf(stderr, "hengevm: pvg-metal: pipelines: %llu compiled (%.0f ms each), %llu from the saved archives (%.1f ms each)\n",
                    compiled, each, hit, hit_each);
        if (saving) dispatch_async(archiver, ^{ [self savePipeline:tag descriptor:descriptor]; });
    }
    return state;
}

/* A pipeline compiled this session into the archive being filled (archiver queue), unless one of the archives has it
   (another process made the same one). A render pipeline with no fragment function (depth only, or rasterization
   off) is not saved: Metal refuses to add one ("expecting 'fragment' stage"). */
- (void)savePipeline:(uint32_t)tag descriptor:(id)descriptor {
    if (!archive || archive_full) return;
    if (tag == 0xe && ![(MTLRenderPipelineDescriptor *)descriptor fragmentFunction]) {
        pipes_unsaveable++;
        return;
    }
    os_unfair_lock_lock(&pipe_lock);
    NSArray<id<MTLBinaryArchive>> *all = [archives arrayByAddingObject:archive];
    os_unfair_lock_unlock(&pipe_lock);
    [descriptor setBinaryArchives:all];
    if ([self newState:tag descriptor:descriptor options:MTLPipelineOptionFailOnBinaryArchiveMiss error:nil]) return;
    NSError *e = nil;
    BOOL added = tag == 0xe    ? [archive addRenderPipelineFunctionsWithDescriptor:descriptor error:&e]
                 : tag == 0x33 ? [archive addTileRenderPipelineFunctionsWithDescriptor:descriptor error:&e]
                               : [archive addComputePipelineFunctionsWithDescriptor:descriptor error:&e];
    if (added) {
        archive_dirty = YES;
        pipes_unsaved++;
        [self scheduleArchiveSave];
    } else {
        pipes_unsaveable++;
        [self complain:[NSString stringWithFormat:@"saved pipelines: pipeline %u not added: %@", tag, e.localizedDescription]];
    }
}

/* Every pipeline compile under way finished, and what they added saved: the Mac stops or is suspended. */
- (void)flushPipelines {
    dispatch_barrier_sync(compiler, ^{});
    dispatch_sync(archiver, ^{ [self saveArchive]; });
}

/* Written once compiling has been quiet for a few seconds (a boot or an app launch compiles in bursts), or after 400
   new ones in a long burst, and when the Mac stops or is suspended. On the archiver queue, as the archive is added to
   there. */
- (void)scheduleArchiveSave {
    if (pipes_unsaved >= 400) {
        [self saveArchive];
        return;
    }
    uint32_t seq = ++archive_save_seq;
    HvReplay *__weak weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * (int64_t)NSEC_PER_SEC), archiver, ^{
        HvReplay *r = weak;
        if (r && r->archive_save_seq == seq && !atomic_load(&r->stopping)) [r saveArchive];
    });
}

/* The archive being filled goes to a new file of its own, then joins the saved ones and an empty one takes its place. */
- (void)saveArchive {
    if (!archive || !archive_dirty) return;
    double t0 = now_seconds();
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *to = [archive_dir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@%d.bin", archive_prefix, archive_next]];
    NSURL *tmp = [to URLByAppendingPathExtension:@"new"];
    [fm removeItemAtURL:tmp error:nil];
    NSError *err = nil;
    if (![archive serializeToURL:tmp error:&err] || rename(tmp.fileSystemRepresentation, to.fileSystemRepresentation) != 0) {
        [self complain:[NSString stringWithFormat:@"saved pipelines: not written: %@", err ? err.localizedDescription : @(strerror(errno))]];
        [fm removeItemAtURL:tmp error:nil];
        return;
    }
    id<MTLBinaryArchive> next = [self emptyArchive];
    if (!next) return; /* keeps filling the same one, and a later save writes it again in full under a new number */
    unsigned long long bytes = [[fm attributesOfItemAtPath:to.path error:nil] fileSize];
    archive_next++;
    archive_bytes += bytes;
    os_unfair_lock_lock(&pipe_lock);
    archives = [archives arrayByAddingObject:archive];
    archive = next;
    uint64_t hit = pipes_hit, compiled = pipes_compiled;
    double hit_each = hit ? hit_ms / hit : 0.0, each = compiled ? compile_ms / compiled : 0.0;
    os_unfair_lock_unlock(&pipe_lock);
    archive_dirty = NO;
    if (archive_full_at(archives.count, archive_bytes, archive_cap())) archive_full = YES;
    fprintf(stderr, "hengevm: pvg-metal: saved pipelines: %llu added in file %d (%.1f MB, %.1f MB in %lu files) in %.0f ms%s; this session %llu from the "
                    "archives (%.1f ms each), %llu compiled (%.0f ms each), %llu not saveable\n",
            pipes_unsaved, archive_next - 1, bytes / 1048576.0, archive_bytes / 1048576.0, (unsigned long)archives.count,
            (now_seconds() - t0) * 1e3, archive_full ? " (now full)" : "", hit, hit_each, compiled, each, pipes_unsaveable);
    pipes_unsaved = 0;
}

/* A pipeline compiled on the compiler queue: the worker goes on with other work, and waits only where the pipeline is
   first used (get:). Several made before a first use compile side by side. */
- (HvPendingPipeline *)compile:(uint32_t)tag descriptor:(id)descriptor name:(NSString *)name failure:(NSString *)what {
    HvPendingPipeline *p = [HvPendingPipeline new];
    p->done = dispatch_group_create();
    dispatch_group_enter(p->done);
    dispatch_async(compiler, ^{
        @autoreleasepool {
            NSError *err = nil;
            id state = [self pipelineState:tag descriptor:descriptor error:&err];
            if (!state) p->failure = [NSString stringWithFormat:@"%@: %@", what, err.localizedDescription];
            else if (name) objc_setAssociatedObject(state, "hvname", name, OBJC_ASSOCIATION_RETAIN);
            p->state = state;
            dispatch_group_leave(p->done);
        }
    });
    return p;
}

/* What a pending pipeline became, once it is there (worker). */
- (void)resolve:(HvObject *)o {
    HvPendingPipeline *p = o->pending;
    double t0 = now_seconds();
    dispatch_group_wait(p->done, DISPATCH_TIME_FOREVER);
    pipe_wait += now_seconds() - t0;
    o->pending = nil;
    o->object = p->state;
    if (p->failure) [self complain:p->failure];
}

- (id)makeSerialized:(uint64_t)at length:(uint32_t)size task:(uint32_t)task {
    NSMutableData *all = [NSMutableData dataWithLength:size];
    if (hv_pvg_lite_task_read(lite, task, at, all.mutableBytes, size)) return nil;
    const uint32_t *w = all.bytes;
    uint32_t tag = w[0];
    if ((tag == 0xe || tag == 0x33 || tag == 0xb) && (size < 16 || w[3] > size - 16)) { /* Apple's host checks this too */
        [self complain:[NSString stringWithFormat:@"pipeline %u: %u bytes of data in a %u-byte record", tag, size >= 16 ? w[3] : 0, size]];
        return nil;
    }
    if (tag == 0xe || tag == 0x33) { /* render or tile pipeline: {tag, size, ref, length, data} */
        id descriptor = [self pipelineDescriptor:tag data:all task:task];
        if (!descriptor) return nil;
        if (tag == 0xe && hv_knob.shader_dump > 0) { /* m4 fork: blend state as this iOS read it */
            MTLRenderPipelineDescriptor *rp = descriptor;
            for (int i = 0; i < 4; i++) {
                MTLRenderPipelineColorAttachmentDescriptor *c = rp.colorAttachments[i];
                if (c.pixelFormat == MTLPixelFormatInvalid) continue;
                fprintf(stderr, "hvpipe: %s c%d fmt %lu blend %d rgb %lu*src %lu %lu*dst alpha %lu*src %lu %lu*dst mask %lx\n",
                        rp.fragmentFunction.name.UTF8String ?: "?", i, (unsigned long)c.pixelFormat, (int)c.blendingEnabled,
                        (unsigned long)c.sourceRGBBlendFactor, (unsigned long)c.rgbBlendOperation, (unsigned long)c.destinationRGBBlendFactor,
                        (unsigned long)c.sourceAlphaBlendFactor, (unsigned long)c.alphaBlendOperation, (unsigned long)c.destinationAlphaBlendFactor,
                        (unsigned long)c.writeMask);
            }
        }
        NSString *name = nil;
        if (tag == 0xe && hv_pvg_trace_on()) {
            MTLRenderPipelineDescriptor *rp = descriptor;
            name = [NSString stringWithFormat:@"%@ / %@ -> fmt %lu blend %d", rp.vertexFunction.name, rp.fragmentFunction.name,
                                              (unsigned long)rp.colorAttachments[0].pixelFormat, (int)rp.colorAttachments[0].blendingEnabled];
        }
        return [self compile:tag descriptor:descriptor name:name failure:[NSString stringWithFormat:@"pipeline %u", tag]];
    }
    if (tag == 0xb) { /* compute pipeline: {tag, size, ref, length, data} */
        id descriptor = [self pipelineDescriptor:tag data:all task:task];
        if (!descriptor) return nil;
        NSString *name = hv_pvg_trace_on() ? [NSString stringWithFormat:@"compute %@", [[descriptor computeFunction] name]] : nil;
        return [self compile:tag descriptor:descriptor name:name failure:@"compute pipeline"];
    }
    if (tag == 3) { /* sampler: {tag, size, ref, bits, lod min, lod max, ...} */
        uint64_t bits;
        memcpy(&bits, w + 3, 8);
        MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
        d.minFilter = (MTLSamplerMinMagFilter)(bits & 3);
        d.magFilter = (MTLSamplerMinMagFilter)((bits >> 2) & 3);
        d.lodAverage = (bits >> 4) & 1;
        d.compareFunction = (MTLCompareFunction)((bits >> 5) & 7);
        d.sAddressMode = (MTLSamplerAddressMode)((bits >> 8) & 15);
        d.tAddressMode = (MTLSamplerAddressMode)((bits >> 12) & 15);
        d.rAddressMode = (MTLSamplerAddressMode)((bits >> 16) & 15);
        d.borderColor = (MTLSamplerBorderColor)((bits >> 20) & 15);
        d.mipFilter = (MTLSamplerMipFilter)((bits >> 24) & 3);
        NSUInteger aniso = (bits >> 26) & 31;
        d.maxAnisotropy = aniso ? aniso : 1;
        d.normalizedCoordinates = (bits >> 31) & 1;
        d.supportArgumentBuffers = (bits >> 32) & 1;
        float lod[2];
        memcpy(lod, w + 5, 8);
        d.lodMinClamp = lod[0], d.lodMaxClamp = lod[1];
        id s = [device newSamplerStateWithDescriptor:d];
        if (!s) [self complain:@"sampler failed"];
        return s;
    }
    if (tag == 0xd) return [device newFence];
    if (tag == 4) { /* depth and stencil: {tag, size, ref, flags, front {ops, read, write}, back {...}} */
        MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
        uint32_t f = w[3];
        d.depthCompareFunction = (MTLCompareFunction)(f & 7);
        d.depthWriteEnabled = (f >> 3) & 1;
        for (int side = 0; side < 2; side++) {
            if (!((f >> (4 + side)) & 1)) continue;
            const uint32_t *t = w + 4 + side * 3;
            MTLStencilDescriptor *sd = [MTLStencilDescriptor new];
            sd.stencilCompareFunction = (MTLCompareFunction)(t[0] & 7);
            sd.stencilFailureOperation = (MTLStencilOperation)((t[0] >> 3) & 7);
            sd.depthFailureOperation = (MTLStencilOperation)((t[0] >> 6) & 7);
            sd.depthStencilPassOperation = (MTLStencilOperation)((t[0] >> 9) & 7);
            sd.readMask = t[1], sd.writeMask = t[2];
            if (side == 0) d.frontFaceStencil = sd;
            else d.backFaceStencil = sd;
        }
        return [device newDepthStencilStateWithDescriptor:d];
    }
    [self complain:[NSString stringWithFormat:@"serialized object tag %u", tag]];
    return nil;
}
