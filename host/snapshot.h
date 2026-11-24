#ifndef SOLSTICEVM_SNAPSHOT_H
#define SOLSTICEVM_SNAPSHOT_H

#include <stddef.h>
#include <stdint.h>

/* Instant resume: the whole machine (CPUs, RAM, devices, the screen) in one file, and back.

   Saving needs a machine paused with hv_vm_pause (every CPU out of guest code, devices idle, the GPU's own memory
   copied back into the guest's). Restoring goes into a machine just made by hv_vm_create with the same settings, before
   hv_vm_start. ident is the caller's own description of what the file is valid for (the app's build, the Mac, its disk
   as it was when saved); a file made under another ident, or by another build of the engine, is refused.

   The disk is not in the file: it has to be exactly as it was when the file was written, so a file must be resumed at
   most once, and never after the Mac has run on without it. */
int hv_snapshot_save(const char *path, const char *ident, char *err, size_t errlen);
/* hv_snapshot_restore: 0 restored; -2 the file can never be resumed (none there, damaged, another ident or build, another
   disk); -1 it failed for a reason of the moment (memory, reading) or the machine has another shape than the file
   (hv_snapshot_shape), and the file may still be good. */
int hv_snapshot_restore(const char *path, const char *ident, char *err, size_t errlen);
/* 0 if path holds a complete snapshot made with ident by this build; its size in bytes and when it was made. */
int hv_snapshot_check(const char *path, const char *ident, uint64_t *bytes, int64_t *saved_at);
/* The shape a snapshot made with ident needs (its RAM in bytes, its CPUs): the one place that decides, restore compares
   the machine with it. 0, or nonzero as hv_snapshot_check. */
int hv_snapshot_shape(const char *path, const char *ident, uint64_t *ram_bytes, uint32_t *ncpus);

#endif
