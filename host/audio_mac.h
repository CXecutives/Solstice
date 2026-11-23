#ifndef HENGEVM_AUDIO_MAC_H
#define HENGEVM_AUDIO_MAC_H

#include "virtio_snd.h"

/* Play the guest's virtio-snd output on the Mac's default output device. */
void hv_audio_attach(HvVirtioSnd *d);
/* Stops and disposes the output unit, waiting for its last render callback. */
void hv_audio_detach(void);
/* iOS took the audio session (a call, Siri, an alarm): the stream drains by the wall clock until hv_audio_resume.
   Any thread. */
void hv_audio_interrupted(void);
/* The session is back, or the route changed: the player plays again if the guest's stream does. rebuild: the media
   services were reset, so the output unit is made anew. Any thread. */
void hv_audio_resume(int rebuild);
/* The output route changed: the player starts again if it stopped and no interruption holds it. Any thread. */
void hv_audio_route_changed(void);

#endif
