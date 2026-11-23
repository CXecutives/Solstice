/* The settings table (core/knobs.def) as the engine parses it: defaults, each type, out-of-range values, unknown HV_
   names, and a second machine taking the environment as it is then. Expectations come from the table itself. */
#include "knobs.h"
#include "machine.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;

/* Split so tools/knobs.py --check does not take it for a setting someone uses. */
#define UNKNOWN "HV_" "NOT_A_SETTING"

static int failures;

static void check(int ok, const char *name, const char *what) {
    if (!ok) {
        printf("FAIL %s: %s\n", name, what);
        failures++;
    }
}

/* Load with name=value (NULL: unset); the number of problems the load found. */
static int load_with(const char *name, const char *value) {
    if (value) setenv(name, value, 1);
    else unsetenv(name);
    int problems = hv_knobs_load();
    unsetenv(name);
    return problems;
}

static void num(char *buf, size_t n, long long v) { snprintf(buf, n, "%lld", v); }

static void check_FLAG(const char *name, int *v, int def, long long lo, long long hi) {
    (void)lo, (void)hi;
    check(*v == def, name, "default");
    load_with(name, "0");
    check(*v == 1, name, "set (even to 0) is on");
    load_with(name, NULL);
    check(*v == def, name, "unset is the default");
}

static void check_BOOL(const char *name, int *v, int def, long long lo, long long hi) {
    (void)lo, (void)hi;
    check(*v == def, name, "default");
    load_with(name, "0");
    check(*v == 0, name, "0 is off");
    load_with(name, "7");
    check(*v == 1, name, "a number is on");
    load_with(name, "");
    check(*v == 1, name, "empty is on");
}

static void check_INT(const char *name, int *v, int def, long long lo, long long hi) {
    char buf[32];
    check(*v == def, name, "default");
    check(def >= lo && def <= hi, name, "default in range");
    num(buf, sizeof buf, lo);
    check(load_with(name, buf) == 0 && *v == lo, name, "low end");
    num(buf, sizeof buf, hi);
    check(load_with(name, buf) == 0 && *v == hi, name, "high end");
    if (lo > INT_MIN) {
        num(buf, sizeof buf, lo - 1);
        check(load_with(name, buf) == 1 && *v == def, name, "below the range falls back to the default");
    }
    if (hi < INT_MAX) {
        num(buf, sizeof buf, hi + 1);
        check(load_with(name, buf) == 1 && *v == def, name, "above the range falls back to the default");
    }
}

static void check_DOUBLE(const char *name, double *v, double def, double lo, double hi) {
    char buf[64];
    check(*v == def, name, "default");
    check(def >= lo && def <= hi, name, "default in range");
    snprintf(buf, sizeof buf, "%.17g", hi);
    check(load_with(name, buf) == 0 && *v == hi, name, "high end");
    snprintf(buf, sizeof buf, "%.17g", lo - 1);
    check(load_with(name, buf) == 1 && *v == def, name, "below the range falls back to the default");
    snprintf(buf, sizeof buf, "%.17g", hi + 1);
    check(load_with(name, buf) == 1 && *v == def, name, "above the range falls back to the default");
}

static void check_HEX(const char *name, uint64_t *v, uint64_t def, long long lo, long long hi) {
    (void)lo, (void)hi;
    check(*v == def, name, "default");
    load_with(name, "fffffe0000004000");
    check(*v == 0xfffffe0000004000ull, name, "hex without 0x");
    load_with(name, "0x1f");
    check(*v == 0x1f, name, "hex with 0x");
}

static void check_STR(const char *name, const char **v, const char *def, long long lo, long long hi) {
    (void)lo, (void)hi;
    check(def ? *v && !strcmp(*v, def) : !*v, name, "default");
    setenv(name, "some text", 1);
    hv_knobs_load();
    const char *first = *v;
    hv_knobs_load();
    check(first && !strcmp(first, "some text") && *v == first, name, "the text, kept in place while it does not change");
    load_with(name, NULL);
    check(def ? *v && !strcmp(*v, def) : !*v, name, "unset is the default");
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    /* From a clean slate: the environment CI runs with (tools/shipped_env.py) goes. */
    for (;;) {
        char **e = environ;
        while (*e && strncmp(*e, "HV_", 3)) e++;
        if (!*e) break;
        char name[128];
        snprintf(name, sizeof name, "%.*s", (int)strcspn(*e, "="), *e);
        unsetenv(name);
    }
    check(hv_knobs_load() == 0, "environment", "no problems without HV_ settings");

#define KNOB(field, name, type, def, lo, hi, doc) check_##type(name, &hv_knob.field, def, lo, hi);
#include "knobs.def"
#undef KNOB
    printf("%d settings: defaults, parsing and ranges\n", HV_KNOB_COUNT);

    check(load_with(UNKNOWN, "1") == 1, UNKNOWN, "an unknown HV_ name is a problem");
    check(hv_knobs_load() == 0, "environment", "clean again");

    /* hv_knob_set: whole numbers by name, nothing else. */
    static const char *const names[HV_KNOB_COUNT] = {
#define KNOB(field, name, type, def, lo, hi, doc) name,
#include "knobs.def"
#undef KNOB
    };
    static HvMachine m;
    check(hv_machine_init(&m, 4 << 20) == 0, "machine", "made");
    for (int i = 0; i < HV_KNOB_COUNT; i++)
        check((hv_knob_set(&m, names[i], 1) != 0) == (hv_knob_int(i) != NULL), names[i], "hv_knob_set takes whole numbers only");
    check(!hv_knob_set(&m, UNKNOWN, 1), UNKNOWN, "hv_knob_set refuses unknown names");
    hv_machine_free(&m);

    /* Each machine takes the environment as it is when it is made (two Macs in one launch, #183): HV_HZ at both ends. */
    long long want[2] = {0, 0};
#define KNOB(field, name, type, def, lo, hi, doc) \
    if (!strcmp(name, "HV_HZ")) want[0] = (long long)(lo), want[1] = (long long)(hi);
#include "knobs.def"
#undef KNOB
    for (int round = 0; round < 2; round++) {
        char buf[32];
        num(buf, sizeof buf, want[round]);
        setenv("HV_HZ", buf, 1);
        check(hv_machine_init(&m, 4 << 20) == 0, "machine", "made again");
        check(hv_knob.hz == want[round], "HV_HZ", "a new machine reads the environment again");
        hv_machine_free(&m);
    }
    unsetenv("HV_HZ");
    printf("%s\n", failures ? "FAIL" : "ok");
    return failures != 0;
}
