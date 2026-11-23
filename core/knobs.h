/* The engine's settings from the environment (core/knobs.def), parsed once per load into hv_knob: reading one is a plain
   load, with no libc and no SIMD, so the light paths (hv_tlb_refill, hv_ijc_resolve, hv_light) may read them too. */
#ifndef HV_KNOBS_H
#define HV_KNOBS_H

#include <stdint.h>

#define HV_KNOB_CTYPE_FLAG int
#define HV_KNOB_CTYPE_BOOL int
#define HV_KNOB_CTYPE_INT int
#define HV_KNOB_CTYPE_DOUBLE double
#define HV_KNOB_CTYPE_HEX uint64_t
#define HV_KNOB_CTYPE_STR const char *

typedef struct HvKnobs {
#define KNOB(field, name, type, def, lo, hi, doc) HV_KNOB_CTYPE_##type field;
#include "knobs.def"
#undef KNOB
} HvKnobs;

/* Index of each setting (the table's order), for hv_knob_int and the tests. */
enum {
#define KNOB(field, name, type, def, lo, hi, doc) HV_KNOB_##field,
#include "knobs.def"
#undef KNOB
    HV_KNOB_COUNT
};

extern HvKnobs hv_knob;

/* Parse the environment into hv_knob: every setting, again at each call (each machine creation; the Mac tool's main;
   the app after EngineTuning sets them; a test after setenv). A value outside its range falls back to the default and an
   HV_ name not in the table is unknown: both are said on stderr once for each environment, and counted in the result. */
int hv_knobs_load(void);
/* The setting with this HV_ name or index, if it is a whole number (FLAG, BOOL, INT); NULL otherwise. */
int *hv_knob_int_named(const char *name);
int *hv_knob_int(int index);

#endif
