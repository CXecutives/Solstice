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
    check("lighten: sh parses it", sh_parses("lighten", lighten_script));
    check("unlighten: sh parses it", sh_parses("unlighten", unlighten_script));
    const char *from = strstr(lighten_script, "<<'EOF'\n"), *to = from ? strstr(from, "\nEOF\n") : NULL;
    check("lighten: writes the daemon from a here-document", from && to);
    if (from && to) {
        from += strlen("<<'EOF'\n");
        char path[256], cmd[320];
        snprintf(path, sizeof path, "%s/hv-test-spins.plist", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
        check("lighten: the daemon written", !write_file(path, from, (size_t)(to - from) + 1));
        snprintf(cmd, sizeof cmd, "plutil -lint -s '%s'", path);
        check("lighten: the daemon is a valid property list", system(cmd) == 0);
        snprintf(cmd, sizeof cmd, "plutil -extract Label raw -o - '%s' | grep -qx '" HV_SPINS_LABEL "'", path);
        check("lighten: the daemon's label", system(cmd) == 0);
        snprintf(cmd, sizeof cmd, "plutil -extract ProgramArguments.2 raw -o - '%s' | grep -qx 'kern.ticket_lock_spins=8'", path);
        check("lighten: the daemon sets kern.ticket_lock_spins to 8", system(cmd) == 0);
        snprintf(cmd, sizeof cmd, "plutil -extract RunAtLoad raw -o - '%s' | grep -qx true", path);
        check("lighten: the daemon runs at every boot", system(cmd) == 0);
    }
    check("lighten: owned by root:wheel", strstr(lighten_script, "sudo chown root:wheel " HV_SPINS_PLIST) != NULL);
    check("lighten: mode 0644", strstr(lighten_script, "sudo chmod 644 " HV_SPINS_PLIST) != NULL);
    check("lighten: started now", strstr(lighten_script, "sudo launchctl bootstrap system " HV_SPINS_PLIST) != NULL);
    const char *sudo = strstr(lighten_script, "if sudo -v </dev/tty; then"), *fi = sudo ? strstr(sudo, "\nfi\n") : NULL;
    const char *tee = strstr(lighten_script, "sudo tee " HV_SPINS_PLIST);
    check("lighten: the daemon is set up in the part with the password", sudo && fi && tee && tee > sudo && tee < fi);
    check("unlighten: stops the daemon", strstr(unlighten_script, "sudo launchctl bootout system/" HV_SPINS_LABEL) != NULL);
    check("unlighten: removes it", strstr(unlighten_script, "sudo rm -f " HV_SPINS_PLIST) != NULL);
    check("unlighten: back to xnu's 100 spins", strstr(unlighten_script, "kern.ticket_lock_spins=100") != NULL);
    printf("share scripts: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
