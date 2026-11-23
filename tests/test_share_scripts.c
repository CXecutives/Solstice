// The scripts share.c serves to macOS (/.henge/lighten and /.henge/unlighten): sh parses them, the LaunchDaemon that
// sets kern.ticket_lock_spins at boot is a valid property list installed root:wheel 0644 and started at once, and
// unlighten takes it all back.
#include "../host/share.c"

static int failures, checks;

static void check(const char *what, int ok) {
    checks++;
    if (!ok) printf("  FAIL %s\n", what), failures++;
}

static int write_file(const char *path, const char *s, size_t n) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    size_t w = fwrite(s, 1, n, f);
    return fclose(f) == 0 && w == n ? 0 : -1;
}

static int sh_parses(const char *name, const char *script) {
    char path[256], cmd[320];
    snprintf(path, sizeof path, "%s/hv-test-%s.sh", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", name);
    if (write_file(path, script, strlen(script))) return 0;
    snprintf(cmd, sizeof cmd, "/bin/sh -n '%s'", path);
    return system(cmd) == 0;
}

int main(void) {
    check("tune: sh parses it", sh_parses("tune", tune_script));
    check("lighten: sh parses it", sh_parses("lighten", lighten_script));
    check("unlighten: sh parses it", sh_parses("unlighten", unlighten_script));
    /* Set Up brings only what nobody sees; how macOS looks and behaves is the optional lighten's business. */
    check("Set Up runs tune", strstr(install_script, "/.henge/tune | sh") != NULL);
    check("Set Up does not run lighten", strstr(install_script, "/.henge/lighten") == NULL);
    check("lighten starts with tune", strstr(lighten_script, "/.henge/tune | sh") != NULL);
    static const char *const visible[] = {"Animation", "animation", "launchanim", "screensaver", "Widgets", "Siri",
                                          "Assistant", "Suggestions", "CrashReporter", "mdutil", "tmutil",
                                          "Desktop Pictures", "killall", "AutomaticCheckEnabled", "commerce", "show-recents"};
    for (size_t i = 0; i < sizeof visible / sizeof visible[0]; i++)
        if (strstr(tune_script, visible[i])) printf("  tune touches something visible: %s\n", visible[i]), check("tune: nothing visible", 0);
    const char *from = strstr(tune_script, "<<'EOF'\n"), *to = from ? strstr(from, "\nEOF\n") : NULL;
    check("tune: writes the daemon from a here-document", from && to);
    if (from && to) {
        from += strlen("<<'EOF'\n");
        char path[256], cmd[320];
        snprintf(path, sizeof path, "%s/hv-test-spins.plist", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
        check("tune: the daemon written", !write_file(path, from, (size_t)(to - from) + 1));
        snprintf(cmd, sizeof cmd, "plutil -lint -s '%s'", path);
        check("tune: the daemon is a valid property list", system(cmd) == 0);
        snprintf(cmd, sizeof cmd, "plutil -extract Label raw -o - '%s' | grep -qx '" HV_SPINS_LABEL "'", path);
        check("tune: the daemon's label", system(cmd) == 0);
        snprintf(cmd, sizeof cmd, "plutil -extract ProgramArguments.2 raw -o - '%s' | grep -qx 'kern.ticket_lock_spins=8'", path);
        check("tune: the daemon sets kern.ticket_lock_spins to 8", system(cmd) == 0);
        static const char *const slack[] = {"kern.timer_coalesce_bg_ns_max=250000000", "kern.timer_coalesce_tier3_ns_max=150000000"};
        for (int i = 0; i < 2; i++) {
            snprintf(cmd, sizeof cmd, "plutil -extract ProgramArguments.%d raw -o - '%s' | grep -qx '%s'", 3 + i, path, slack[i]);
            check("tune: the daemon sets the background timer slack", system(cmd) == 0);
            snprintf(cmd, sizeof cmd, "sysctl -n %.*s >/dev/null 2>&1", (int)(strchr(slack[i], '=') - slack[i]), slack[i]);
            check("tune: macOS has that timer setting (on this runner)", system(cmd) == 0);
        }
        snprintf(cmd, sizeof cmd, "plutil -extract RunAtLoad raw -o - '%s' | grep -qx true", path);
        check("tune: the daemon runs at every boot", system(cmd) == 0);
    }
    check("tune: owned by root:wheel", strstr(tune_script, "sudo chown root:wheel " HV_SPINS_PLIST) != NULL);
    check("tune: mode 0644", strstr(tune_script, "sudo chmod 644 " HV_SPINS_PLIST) != NULL);
    check("tune: started now", strstr(tune_script, "sudo launchctl bootstrap system " HV_SPINS_PLIST) != NULL);
    const char *sudo = strstr(tune_script, "if sudo -v </dev/tty; then"), *fi = sudo ? strstr(sudo, "\nfi\n") : NULL;
    const char *tee = strstr(tune_script, "sudo tee " HV_SPINS_PLIST);
    check("tune: the daemon is set up in the part with the password", sudo && fi && tee && tee > sudo && tee < fi);
    check("unlighten: stops the daemon", strstr(unlighten_script, "sudo launchctl bootout system/" HV_SPINS_LABEL) != NULL);
    check("unlighten: removes it", strstr(unlighten_script, "sudo rm -f " HV_SPINS_PLIST) != NULL);
    check("unlighten: back to xnu's 100 spins", strstr(unlighten_script, "kern.ticket_lock_spins=100") != NULL);
    printf("share scripts: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
