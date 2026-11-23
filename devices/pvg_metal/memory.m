/* Objects by ref and the guest task memory under them (part of pvg_metal.m, which includes it). */

/* The slot for a task's ref, made if asked for; NULL for a ref past OBJ_REFS (or no memory). Slots never move once
   made, so one stays valid while making its object looks up others. */
static HvObject *__strong *obj_slot(HvTaskObjects *t, uint32_t ref, BOOL make) {
    if (ref >= OBJ_REFS) return NULL;
    uint32_t p = ref / OBJ_PAGE;
    if (p >= t->pages) {
        if (!make) return NULL;
        uint32_t n = t->pages ? t->pages : 8;
        while (n <= p) n *= 2;
        HvObject *__strong **grown = (HvObject *__strong **)realloc(t->page, n * sizeof *grown);
        if (!grown) return NULL;
        memset(grown + t->pages, 0, (n - t->pages) * sizeof *grown);
        t->page = grown, t->pages = n;
    }
    if (!t->page[p]) {
        if (!make) return NULL;
        t->page[p] = (HvObject *__strong *)calloc(OBJ_PAGE, sizeof(HvObject *));
        if (!t->page[p]) return NULL;
    }
    return &t->page[p][ref % OBJ_PAGE];
}

/* All of a task's objects let go (the task ended, or the replay did). */
static void obj_clear(HvTaskObjects *t) {
    for (uint32_t p = 0; p < t->pages; p++) {
        if (!t->page[p]) continue;
        for (uint32_t i = 0; i < OBJ_PAGE; i++) t->page[p][i] = nil;
        free(t->page[p]);
    }
    free(t->page);
    t->page = NULL, t->pages = 0;
}

/* x if it is that kind of object, else nil: a ref names any object, and Metal crashes on the wrong kind. */
static id of_kind(id x, Protocol *kind) { return [x conformsToProtocol:kind] ? x : nil; }

/* An object already made for a ref, or nil. */
static HvObject *obj_known(HvReplay *r, uint32_t task, uint32_t ref) {
    if (task >= HV_TASKS) return nil;
    HvObject *__strong *s = obj_slot(&r->task_objs[task], ref, NO);
    return s ? *s : nil;
}

/* A new command on the worker: the walk memo and the page checks start over. */
static void new_command(HvReplay *r) {
    if (++r->walk_epoch == 0) {
        memset(r->walk, 0, sizeof r->walk);
        r->walk_epoch = 1;
    }
}

/* The host page under task page vpn, or NULL: walked once per page and command. */
static uint8_t *task_page(HvReplay *r, uint32_t task, uint64_t vpn) {
    HvWalk *w = &r->walk[(vpn ^ (uint64_t)task * 0x9e3779b1u) % HV_WALK];
    if (w->epoch == r->walk_epoch && w->vpn == vpn && w->task == task) return w->host;
    uint32_t page = hv_pvg_lite_task_page(r->lite, task, vpn << 14);
    w->host = page ? r->guest_page(r->lite, page) : NULL;
    w->vpn = vpn, w->task = task, w->epoch = r->walk_epoch;
    return w->host;
}

/* n bytes of task memory copied out; 0, or -1 if a page of it is not there. */
static int task_copy(HvReplay *r, uint32_t task, uint64_t off, void *to, uint64_t n) {
    uint8_t *d = to;
    while (n) {
        uint8_t *page = task_page(r, task, off >> 14);
        if (!page) return -1;
        uint64_t in = off & 0x3fff, c = 0x4000 - in < n ? 0x4000 - in : n;
        memcpy(d, page + in, c);
        d += c, off += c, n -= c;
    }
    return 0;
}

/* n bytes of task memory where they are, if they are in one piece in host memory: in one page, or in pages that follow
   each other there (guest RAM is one mapping, and the guest's allocator mostly hands out runs). NULL if not. */
static const uint8_t *task_span(HvReplay *r, uint32_t task, uint64_t off, uint64_t n) {
    if (!n) return NULL;
    uint64_t vpn = off >> 14, last = (off + n - 1) >> 14;
    uint8_t *first = task_page(r, task, vpn);
    if (!first) return NULL;
    for (uint64_t v = vpn + 1; v <= last; v++)
        if (task_page(r, task, v) != first + ((v - vpn) << 14)) return NULL;
    return first + (off & 0x3fff);
}

/* Room for n page numbers, kept for the next time. */
static uint32_t *pages_scratch(HvReplay *r, uint64_t n) {
    if (n > r->pages_cap) {
        free(r->pages_scratch);
        r->pages_scratch = malloc(n * 4);
        r->pages_cap = r->pages_scratch ? n : 0;
    }
    return r->pages_scratch;
}

/* A contiguous view of a task's guest pages; holes are left as zero pages. */
/* A range of task memory at one address, page by page. Metal pins a buffer's
   pages when the buffer is made, so a mapping never changes under a buffer: when
   the guest's pages change there is a new mapping and a new buffer. (A GPU still
   writing to pages the guest has freed and used again would corrupt its memory.) */
static BOOL map_pages(HvReplay *r, uint32_t task, HvObject *o) {
    uint64_t n = (o->length + 0x3fff) >> 14;
    vm_address_t base = 0;
    if (vm_allocate(mach_task_self(), &base, n << 14, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) return NO;
    uint32_t *pages = calloc(n, 4);
    r->task_pages(r->lite, task, o->vpage, n, pages);
    for (uint64_t i = 0; i < n; i++) {
        uint8_t *src = pages[i] ? r->guest_page(r->lite, pages[i]) : NULL;
        if (!src) {
            pages[i] = 0;
            continue;
        }
        vm_address_t to = base + (i << 14);
        vm_prot_t cur, max;
        kern_return_t kr = vm_remap(mach_task_self(), &to, 0x4000, 0, VM_FLAGS_OVERWRITE, mach_task_self(), (vm_address_t)src, FALSE, &cur, &max, VM_INHERIT_NONE);
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "hengevm: pvg-metal: vm_remap failed: %d\n", kr);
            vm_deallocate(mach_task_self(), base, n << 14);
            free(pages);
            return NO;
        }
    }
    free(o->pages);
    o->pages = pages;
    o->mapped = (uint8_t *)base;
    o->checked = r->walk_epoch;
    return YES;
}

/* A buffer over the mapping, that frees it when the last user is done. */
static id<MTLBuffer> buffer_over_mapping(HvReplay *r, HvObject *o) {
    uint8_t *base = o->mapped;
    NSUInteger bytes = (NSUInteger)((o->length + 0x3fff) & ~0x3fffull);
    id<MTLBuffer> b = [r->device newBufferWithBytesNoCopy:base length:bytes options:MTLResourceStorageModeShared
                                              deallocator:^(void *at, NSUInteger size) { vm_deallocate(mach_task_self(), (vm_address_t)at, size); }];
    if (b) o->mapping_in_buffer = YES;
    return b;
}

/* What a made object costs while it is kept: a buffer's length, else what Metal allocated for it. */
static uint64_t object_bytes(id x) {
    if ([x conformsToProtocol:@protocol(MTLBuffer)]) return [(id<MTLBuffer>)x length];
    if ([x conformsToProtocol:@protocol(MTLResource)]) return [(id<MTLResource>)x allocatedSize];
    return 0;
}

/* An object the guest may still reach through an address it was told, kept for as long as o lives. Many generations
   of one object are logged: a buffer's map the same guest RAM (no new memory), but each pins its pages. */
enum { RETIRED_LOGGED = 32 };
static void retire(HvObject *o, id old) {
    if (!old) return;
    if (!o->retired) o->retired = [NSMutableArray new];
    [o->retired addObject:old];
    uint64_t bytes = object_bytes(old);
    o->retired_bytes += bytes;
    atomic_fetch_add(&retired_bytes_live, bytes);
    if (o->retired.count == RETIRED_LOGGED) {
        static int told;
        if (told++ < 8) fprintf(stderr, "hengevm: pvg-metal: an object made again %d times since the guest was told its address; all kept\n", RETIRED_LOGGED);
    }
}

/* A remade object takes over what its predecessor kept, and the predecessor's object itself if the guest had its address. */
static void inherit_retired(HvObject *o, HvObject *old) {
    if (!old || old == o) return;
    if (old->retired) {
        if (!o->retired) o->retired = old->retired;
        else [o->retired addObjectsFromArray:old->retired];
        o->retired_bytes += old->retired_bytes;
        old->retired = nil, old->retired_bytes = 0;
    }
    if (old->address_told) retire(o, old->object);
}

static uint64_t gpu_address_of(id x) {
    return [x conformsToProtocol:@protocol(MTLBuffer)] ? [(id<MTLBuffer>)x gpuAddress] : 0;
}

/* The guest's table for this range against what is mapped: a change means a new mapping. Once a command: one exec
   names the same buffer many times (each resource, each texture made from it, each info query). */
static void refresh_pages(HvReplay *r, uint32_t task, HvObject *o) {
    if (!o || !o->mapped || o->checked == r->walk_epoch) return;
    uint64_t n = (o->length + 0x3fff) >> 14;
    uint32_t *now = pages_scratch(r, n);
    if (!now) return;
    o->checked = r->walk_epoch;
    r->task_pages(r->lite, task, o->vpage, n, now);
    if (memcmp(now, o->pages, n * 4) == 0) return;
    uint8_t *old = o->mapped;
    BOOL old_in_buffer = o->mapping_in_buffer;
    if (!map_pages(r, task, o)) return;
    if (!old_in_buffer) vm_deallocate(mach_task_self(), (vm_address_t)old, n << 14);
    o->mapping_in_buffer = NO;
    o->generation++;
    o->guest_copy = nil;
    HvRemapNote *note = &r->remap_ring[r->remap_next++ % REMAP_RING];
    *note = (HvRemapNote){.task = task, .vpage = o->vpage, .length = o->length, .told = o->address_told,
                          .old_address = o->plain_buffer ? gpu_address_of(o->object) : 0};
    if (o->plain_buffer) {
        if (o->address_told) retire(o, o->object); /* and with it its old mapping */
        o->object = buffer_over_mapping(r, o);
        note->new_address = gpu_address_of(o->object);
    }
    r->remaps++;
}

/* A resource and what it replaced while the guest held its address, for useResources: a shader may read through any
   of them. Returns the new count, at most cap. */
static uint32_t with_retired(HvObject *o, id x, __unsafe_unretained id<MTLResource> *items, uint32_t have, uint32_t cap) {
    if (have < cap) items[have++] = x;
    for (id old in o ? o->retired : nil) {
        if (have >= cap) break;
        if ([old conformsToProtocol:@protocol(MTLResource)]) items[have++] = old;
    }
    return have;
}

/* The guest was told o's GPU address or resource id. */
static void mark_told(HvObject *o) {
    if (o) o->address_told = YES;
}
