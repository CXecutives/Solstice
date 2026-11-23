/* The guest's sound on the host (Mac or iOS): the default output device through an AudioUnit
   whose render callback pulls PCM straight from the virtio-snd ring. The unit
   is set to the stream's own format, and CoreAudio converts to the device.

   Everything that touches the unit runs on one serial queue, never on a CPU thread under the device lock (starting
   and stopping a unit can take many milliseconds). While the unit is not playing (iOS took the audio session away
   for a call, Siri or an alarm, or the device refused the format) the device drains the stream by the wall clock
   (host_off), so the guest's sound and anything paced by it go on; when the session comes back the unit starts
   again. */
#include "audio_mac.h"

#include <AudioToolbox/AudioToolbox.h>
#include <TargetConditionals.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

/* The Mac's default output device, or the iOS app's own output (the app sets its audio session to playback). */
#if TARGET_OS_IPHONE
#define HV_OUTPUT_UNIT kAudioUnitSubType_RemoteIO
#else
#define HV_OUTPUT_UNIT kAudioUnitSubType_DefaultOutput
#endif

/* A unit that would not start (the session not active again yet) is tried again this often, this many times. */
#define RETRY_NS (1000ull * 1000 * 1000)
#define RETRIES 10

static dispatch_queue_t queue;
static pthread_once_t queue_once = PTHREAD_ONCE_INIT;
static _Atomic int interrupted; /* iOS took the session: not even trying to play */

/* The queue's own state. */
static HvVirtioSnd *dev;
static AudioComponentInstance unit;
static unsigned cur_channels, cur_format, cur_rate;
static int want;                                 /* the guest's stream is playing */
static unsigned want_channels, want_format, want_rate;
static int retries;
static unsigned generation; /* a retry from before a newer request is dropped */

typedef struct Req {
    int kind; /* 0 start, 1 stop, 2 interruption change, 3 rebuild (the media services were reset) */
    HvVirtioSnd *d;
    unsigned channels, format, rate;
} Req;

static void make_queue(void) {
    queue = dispatch_queue_create("solstice.audio", DISPATCH_QUEUE_SERIAL);
}

static OSStatus render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                       UInt32 frames, AudioBufferList *io) {
    (void)flags, (void)ts, (void)bus, (void)frames;
    HvVirtioSnd *d = ref;
    for (UInt32 i = 0; i < io->mNumberBuffers; i++)
        hv_virtio_snd_pull(d, io->mBuffers[i].mData, io->mBuffers[i].mDataByteSize);
    return noErr;
}

/* Queue: the player is (not) playing what the guest sends; the CPU thread is woken to switch the clock drain. */
static void set_off(int off) {
    if (!dev || atomic_exchange(&dev->host_off, off) == off) return;
    hv_machine_wake(dev->vio.m);
}

static void dispose(void) {
    if (!unit) return;
    AudioOutputUnitStop(unit); /* waits for the render callback to finish */
    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);
    unit = NULL;
    cur_channels = cur_format = cur_rate = 0;
}

static int make_unit(void) {
    AudioComponentDescription desc = {kAudioUnitType_Output, HV_OUTPUT_UNIT, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp || AudioComponentInstanceNew(comp, &unit) != noErr) {
        unit = NULL;
        return -1;
    }
    unsigned bytes = want_format == HV_VSND_FMT_S16 ? 2 : 4;
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = want_rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = (want_format == HV_VSND_FMT_FLOAT ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) |
                     kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = f.mBytesPerFrame = bytes * want_channels;
    f.mFramesPerPacket = 1;
    f.mChannelsPerFrame = want_channels;
    f.mBitsPerChannel = bytes * 8;
    AURenderCallbackStruct cb = {render, dev};
    if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f) != noErr ||
        AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb) != noErr ||
        AudioUnitInitialize(unit) != noErr) {
        fprintf(stderr, "hengevm: sound: the output device refused %u ch, format %u, %u Hz\n", want_channels, want_format, want_rate);
        AudioComponentInstanceDispose(unit);
        unit = NULL;
        return -1;
    }
    cur_channels = want_channels, cur_format = want_format, cur_rate = want_rate;
    return 0;
}

static void retry(void *ctx);

/* Queue: bring the unit to what is wanted. */
static void apply(void) {
    if (!dev) return;
    if (!want || atomic_load(&interrupted)) {
        if (unit) AudioOutputUnitStop(unit);
        if (want) set_off(1);
        return;
    }
    if (unit && (want_channels != cur_channels || want_format != cur_format || want_rate != cur_rate)) dispose();
    if (!unit && make_unit() != 0) {
        set_off(1); /* the format itself: no retry */
        return;
    }
    UInt32 running = 0, size = sizeof running;
    if (AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size) != noErr) running = 0;
    /* Off the clock before the first render callback, so no poll drains by the clock while the player plays. */
    if (!running) set_off(0);
    if (!running && AudioOutputUnitStart(unit) != noErr) {
        set_off(1);
        if (retries++ < RETRIES)
            dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)RETRY_NS), queue, (void *)(uintptr_t)generation, retry);
        else fprintf(stderr, "hengevm: sound: the output does not start; the stream plays on silently\n");
        return;
    }
    retries = 0;
    set_off(0);
}

static void retry(void *ctx) {
    if ((unsigned)(uintptr_t)ctx == generation) apply();
}

static void run(void *ctx) {
    Req *q = ctx;
    generation++;
    switch (q->kind) {
    case 0:
        dev = q->d;
        want = 1, want_channels = q->channels, want_format = q->format, want_rate = q->rate;
        retries = 0;
        break;
    case 1:
        want = 0;
        break;
    case 2:
        retries = 0;
        if (atomic_load(&interrupted)) set_off(1);
        break;
    case 3:
        dispose(); /* the old unit is dead with the services it was made from */
        retries = 0;
        break;
    }
    apply();
    free(q);
}

static void post(int kind, HvVirtioSnd *d, unsigned channels, unsigned format, unsigned rate) {
    pthread_once(&queue_once, make_queue);
    Req *q = malloc(sizeof *q);
    if (!q) return;
    *q = (Req){kind, d, channels, format, rate};
    dispatch_async_f(queue, q, run);
}

/* CPU thread, device lock held: only a request to the queue. A failure there shows as host_off. */
static int start(void *opaque, unsigned channels, unsigned format, unsigned rate_hz) {
    post(0, opaque, channels, format, rate_hz);
    return 0;
}

static void stop(void *opaque) {
    post(1, opaque, 0, 0, 0);
}

static void attach(void *ctx) {
    dev = ctx;
    want = 0;
    retries = 0;
}

void hv_audio_attach(HvVirtioSnd *d) {
    pthread_once(&queue_once, make_queue);
    dispatch_sync_f(queue, d, attach);
    atomic_store(&d->host_off, 0);
    d->backend = (HvVirtioSndBackend){start, stop, d};
}

static void detach(void *ctx) {
    (void)ctx;
    dispose();
    dev = NULL;
    want = 0;
    generation++;
}

void hv_audio_detach(void) {
    pthread_once(&queue_once, make_queue);
    dispatch_sync_f(queue, NULL, detach);
}

void hv_audio_interrupted(void) {
    atomic_store(&interrupted, 1);
    post(2, NULL, 0, 0, 0);
}

void hv_audio_resume(int rebuild) {
    atomic_store(&interrupted, 0);
    post(rebuild ? 3 : 2, NULL, 0, 0, 0);
}

void hv_audio_route_changed(void) {
    post(2, NULL, 0, 0, 0);
}
