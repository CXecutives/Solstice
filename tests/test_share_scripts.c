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

/* One connection's whole exchange: the request bytes in (in pieces of `piece` bytes, 0: at once), what the server
   answered out. */
static const char *exchange(const char *req, size_t piece) {
    static char out[65536];
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) return "";
    size_t len = strlen(req);
    for (size_t at = 0; at < len;) {
        size_t n = piece && len - at > piece ? piece : len - at;
        send_all(sv[0], req + at, n);
        at += n;
    }
    shutdown(sv[0], SHUT_WR);
    Conn *c = calloc(1, sizeof *c);
    c->fd = sv[1];
    connection(c); /* runs it to the end and closes its side */
    size_t n = 0;
    for (ssize_t r; n + 1 < sizeof out && (r = recv(sv[0], out + n, sizeof out - 1 - n, 0)) > 0;) n += (size_t)r;
    out[n] = 0;
    close(sv[0]);
    return out;
}

static double seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int status_is(const char *resp, int status) {
    int got = 0;
    return sscanf(resp, "HTTP/1.1 %d", &got) == 1 && got == status;
}

static void test_server(void) {
    /* Only requests made to 10.0.2.4 itself (DNS rebinding sends the attacker's own name). */
    check("Host 10.0.2.4: served", status_is(exchange("GET /.henge/token HTTP/1.1\r\nHost: 10.0.2.4\r\n\r\n", 0), 200));
    check("Host 10.0.2.4:80 (spaces after): served", status_is(exchange("GET /.henge/token HTTP/1.1\r\nHost: 10.0.2.4:80  \r\n\r\n", 0), 200));
    check("another Host: refused", status_is(exchange("GET /.henge/token HTTP/1.1\r\nHost: rebind.example\r\n\r\n", 0), 421));
    check("a Host that only starts right: refused", status_is(exchange("GET / HTTP/1.1\r\nHost: 10.0.2.40\r\n\r\n", 0), 421));
    check("no Host: refused", status_is(exchange("GET /.henge/token HTTP/1.1\r\n\r\n", 0), 421));
    check("two Hosts: refused", status_is(exchange("GET / HTTP/1.1\r\nHost: 10.0.2.4\r\nHost: rebind.example\r\n\r\n", 0), 421));
    check("an absolute target's host counts", status_is(exchange("GET http://rebind.example/.henge/token HTTP/1.1\r\nHost: 10.0.2.4\r\n\r\n", 0), 421));

    /* The clipboard only with the key, which /.henge/token gives. */
    hv_share_set_clipboard("from the device");
    const char *t = exchange("GET /.henge/token HTTP/1.1\r\nHost: 10.0.2.4\r\n\r\n", 0);
    const char *body = strstr(t, "\r\n\r\n");
    char key[80] = "";
    if (body) snprintf(key, sizeof key, "%s", body + 4);
    check("the key is 32 hex digits", strlen(key) == 32 && strspn(key, "0123456789abcdef") == 32);
    check("the key is the server's", strcmp(key, share_token()) == 0);
    /* A helper from before the key sends none and asks again as soon as it is answered: it is held as long as a
       long-poll, then refused. A wrong key is refused at once. */
    keyless_hold_seconds = 1;
    double t0 = seconds();
    check("clipboard without the key: refused",
          status_is(exchange("GET /.henge/clipboard?since=0 HTTP/1.1\r\nHost: 10.0.2.4\r\n\r\n", 0), 403));
    check("clipboard without the key: held first", seconds() - t0 >= 0.9);
    t0 = seconds();
    check("clipboard with a wrong key: refused",
          status_is(exchange("PUT /.henge/clipboard HTTP/1.1\r\nHost: 10.0.2.4\r\nX-Henge-Token: 0123\r\nContent-Length: 1\r\n\r\nx", 0), 403));
    check("clipboard GET with a wrong key: refused",
          status_is(exchange("GET /.henge/clipboard?since=0 HTTP/1.1\r\nHost: 10.0.2.4\r\nX-Henge-Token: 0123\r\n\r\n", 0), 403));
    check("a wrong key: refused at once", seconds() - t0 < 0.5);
    char req[512];
    snprintf(req, sizeof req, "GET /.henge/clipboard?since=0 HTTP/1.1\r\nHost: 10.0.2.4\r\nX-Henge-Token: %s\r\n\r\n", key);
    const char *r = exchange(req, 0);
    check("clipboard with the key: the device's", status_is(r, 200) && strstr(r, "\r\n\r\nfrom the device"));
    /* The same, byte by byte, and two requests in one write: the read-ahead buffer keeps them apart. */
    check("a request in one-byte pieces", status_is(exchange(req, 1), 200));
    snprintf(req, sizeof req, "PUT /.henge/clipboard HTTP/1.1\r\nHost: 10.0.2.4\r\nX-Henge-Token: %s\r\nContent-Length: 9\r\n\r\nfrom gues"
                              "GET /.henge/token HTTP/1.1\r\nHost: 10.0.2.4\r\n\r\n", key);
    r = exchange(req, 0);
    const char *second = strstr(r + 1, "HTTP/1.1 ");
    check("two requests in one write: both answered", status_is(r, 204) && second && status_is(second, 200) && strstr(second, key));
    char *guest = hv_share_take_clipboard();
    check("the guest's clipboard arrived", guest && !strcmp(guest, "from gues"));
    free(guest);

    /* A PUT too big for the free space is refused before its body is sent: no 100 Continue, and the connection ends. */
    const char *tmp = getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp";
    check("the folder", realpath(tmp, root) != NULL);
    r = exchange("PUT /solstice-too-big HTTP/1.1\r\nHost: 10.0.2.4\r\nContent-Length: 1000000000000000\r\nExpect: 100-continue\r\n\r\n", 0);
    check("PUT without room: 507 before any 100 Continue", status_is(r, 507) && !strstr(r, "100 Continue"));
    check("PUT without room: the connection closes", strstr(r, "Connection: close\r\n") != NULL);
    char left[PATH_MAX];
    snprintf(left, sizeof left, "%s/solstice-too-big", root);
    check("PUT without room: nothing written", access(left, F_OK) != 0);

    /* Ranges: the whole file, a part, the last bytes; past the end, backwards or empty ones cannot be given (416). */
    long long from, to;
    check("no range: the whole file", range_of(-1, -1, 1000, &from, &to) == 0 && from == 0 && to == 999);
    check("bytes=100-199", range_of(100, 199, 1000, &from, &to) == 1 && from == 100 && to == 199);
    check("bytes=100-: to the end", range_of(100, -1, 1000, &from, &to) == 1 && from == 100 && to == 999);
    check("bytes=900-5000: cut at the end", range_of(900, 5000, 1000, &from, &to) == 1 && to == 999);
    check("bytes=-100: the last 100", range_of(-1, 100, 1000, &from, &to) == 1 && from == 900 && to == 999);
    check("bytes=-5000: all of it", range_of(-1, 5000, 1000, &from, &to) == 1 && from == 0);
    check("bytes=100-50: 416", range_of(100, 50, 1000, &from, &to) == -1);
    check("bytes=1000-: 416", range_of(1000, -1, 1000, &from, &to) == -1);
    check("bytes=-0: 416", range_of(-1, 0, 1000, &from, &to) == -1);
    check("a range of an empty file: 416", range_of(0, -1, 0, &from, &to) == -1);
}

/* Connections that sit idle are closed after idle_seconds, so a full set of them does not keep the next one out. */
static void test_idle(void) {
    idle_seconds = 1;
    const char *path = "/tmp/solstice-share-test.sock";
    check("the server starts", hv_share_start(root[0] ? root : "/tmp", path, NULL) == 0);
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    strcpy(addr.sun_path, path);
    int idle[MAX_CONNS];
    for (int i = 0; i < MAX_CONNS; i++) {
        idle[i] = socket(AF_UNIX, SOCK_STREAM, 0);
        for (int tries = 0; connect(idle[i], (struct sockaddr *)&addr, sizeof addr) != 0 && tries < 100; tries++) usleep(10000);
    }
    int held = 0;
    for (int tries = 0; !held && tries < 100; tries++) { /* until the server has a thread on each of them */
        pthread_mutex_lock(&conns_mu);
        held = conns == MAX_CONNS;
        pthread_mutex_unlock(&conns_mu);
        if (!held) usleep(10000);
    }
    check("all connections taken", held);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct timeval wait = {.tv_sec = 10};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof wait);
    setsockopt(idle[0], SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof wait);
    check("one more connects", connect(fd, (struct sockaddr *)&addr, sizeof addr) == 0);
    static const char req[] = "GET /.henge/token HTTP/1.1\r\nHost: 10.0.2.4\r\nConnection: close\r\n\r\n";
    send_all(fd, req, sizeof req - 1);
    char out[512];
    ssize_t n = recv(fd, out, sizeof out - 1, 0);
    out[n > 0 ? n : 0] = 0;
    check("with all connections idle, the next one is served once they time out", status_is(out, 200));
    char ch;
    check("an idle connection was closed", recv(idle[0], &ch, 1, 0) == 0);
    for (int i = 0; i < MAX_CONNS; i++) close(idle[i]);
    close(fd);
    unlink(path);
}

int main(void) {
    test_server();
    test_idle();
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
