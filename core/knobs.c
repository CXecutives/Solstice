/* The one place the engine reads HV_* from the environment: core/knobs.def parsed into hv_knob (core/knobs.h). */
#include "knobs.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;

/* The defaults until the first load, so nothing read before it sees zeros. */
HvKnobs hv_knob = {
#define KNOB(field, name, type, def, lo, hi, doc) .field = def,
#include "knobs.def"
#undef KNOB
};

typedef struct {
    const char *name;
    int whole; /* FLAG, BOOL, INT: an int in hv_knob */
    size_t off;
} KnobInfo;

#define KNOB_WHOLE_FLAG 1
#define KNOB_WHOLE_BOOL 1
#define KNOB_WHOLE_INT 1
#define KNOB_WHOLE_DOUBLE 0
#define KNOB_WHOLE_HEX 0
#define KNOB_WHOLE_STR 0
static const KnobInfo knobs[HV_KNOB_COUNT] = {
#define KNOB(field, name, type, def, lo, hi, doc) {name, KNOB_WHOLE_##type, __builtin_offsetof(HvKnobs, field)},
#include "knobs.def"
#undef KNOB
};

static int problems; /* in this load */
static int say;      /* this environment was not seen at the last load: say what is wrong with it */

static void complain(const char *name, const char *value, const char *want) {
    problems++;
    if (say) fprintf(stderr, "solstice: %s=%s is not %s: the default is used\n", name, value, want);
}

static int parse_FLAG(const char *name, const char *v, int def, long long lo, long long hi) {
    (void)name, (void)lo, (void)hi;
    return v ? 1 : def;
}

static int parse_BOOL(const char *name, const char *v, int def, long long lo, long long hi) {
    (void)name, (void)lo, (void)hi;
    return v ? !*v || atoi(v) != 0 : def;
}

static int parse_INT(const char *name, const char *v, int def, long long lo, long long hi) {
    if (!v) return def;
    long long n = atoi(v);
    if (n >= lo && n <= hi) return (int)n;
    char want[64];
    snprintf(want, sizeof want, "in %lld..%lld", lo, hi);
    complain(name, v, want);
    return def;
}

static double parse_DOUBLE(const char *name, const char *v, double def, double lo, double hi) {
    if (!v) return def;
    double d = atof(v);
    if (d >= lo && d <= hi) return d;
    char want[64];
    snprintf(want, sizeof want, "in %g..%g", lo, hi);
    complain(name, v, want);
    return def;
}

static uint64_t parse_HEX(const char *name, const char *v, uint64_t def, long long lo, long long hi) {
    (void)name, (void)lo, (void)hi;
    return v ? (uint64_t)strtoull(v, NULL, 16) : def;
}

/* The text stays where it is while it does not change: a string another thread may be reading is never freed (a
   changed one is copied and the old copy left, a few bytes for each change). */
static const char *parse_STR(const char *name, const char *v, const char *def, long long lo, long long hi, const char *was) {
    (void)name, (void)lo, (void)hi;
    if (!v) return def;
    if (was && was != def && !strcmp(was, v)) return was;
    const char *copy = strdup(v);
    return copy ? copy : def;
}
#define PARSE_FLAG(field, name, def, lo, hi) parse_FLAG(name, getenv(name), def, lo, hi)
#define PARSE_BOOL(field, name, def, lo, hi) parse_BOOL(name, getenv(name), def, lo, hi)
#define PARSE_INT(field, name, def, lo, hi) parse_INT(name, getenv(name), def, lo, hi)
#define PARSE_DOUBLE(field, name, def, lo, hi) parse_DOUBLE(name, getenv(name), def, lo, hi)
#define PARSE_HEX(field, name, def, lo, hi) parse_HEX(name, getenv(name), def, lo, hi)
#define PARSE_STR(field, name, def, lo, hi) parse_STR(name, getenv(name), def, lo, hi, hv_knob.field)

static int known(const char *entry) {
    size_t len = strcspn(entry, "=");
    for (int i = 0; i < HV_KNOB_COUNT; i++)
        if (strlen(knobs[i].name) == len && !strncmp(knobs[i].name, entry, len)) return 1;
    return 0;
}

int hv_knobs_load(void) {
    /* Said once for each environment: a hash of every HV_ entry, compared with the last load's. */
    static uint64_t last_seen;
    uint64_t h = 1469598103934665603ull;
    for (char **e = environ; e && *e; e++)
        if (!strncmp(*e, "HV_", 3))
            for (const char *c = *e; *c; c++) h = (h ^ (uint8_t)*c) * 1099511628211ull;
    say = h != last_seen;
    last_seen = h;
    problems = 0;
    HvKnobs k;
#define KNOB(field, name, type, def, lo, hi, doc) k.field = PARSE_##type(field, name, def, lo, hi);
#include "knobs.def"
#undef KNOB
    for (char **e = environ; e && *e; e++)
        if (!strncmp(*e, "HV_", 3) && !known(*e)) {
            problems++;
            if (say) fprintf(stderr, "solstice: %.*s is not a setting (core/knobs.def)\n", (int)strcspn(*e, "="), *e);
        }
    hv_knob = k;
    return problems;
}

int *hv_knob_int(int index) {
    if (index < 0 || index >= HV_KNOB_COUNT || !knobs[index].whole) return NULL;
    return (int *)(void *)((char *)&hv_knob + knobs[index].off);
}

int *hv_knob_int_named(const char *name) {
    for (int i = 0; i < HV_KNOB_COUNT; i++)
        if (!strcmp(name, knobs[i].name)) return hv_knob_int(i);
    return NULL;
}
