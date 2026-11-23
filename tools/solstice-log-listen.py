#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Listen for Solstice's log stream and write it to a file.

Solstice sends every line it logs over TCP to a computer on the same network
(Settings > Log stream). Run this on that computer first:

    python3 tools/solstice-log-listen.py

It prints the addresses to type into Solstice, then prints each line as it arrives
and appends it to solstice-stream.log. Performance marks (the flag in the session's
controls) are highlighted, and the lines after one say what the engine and the
GPU did over that window.

Ctrl-C stops it. Nothing is sent back, and the file is plain text in the same
format as Documents/solstice.log on the device. --allow takes only the phone's
address; control characters (a peer's terminal escapes) are taken out of each
line, and lines are cut at --max-line characters.
"""

from __future__ import annotations

import argparse
import datetime as dt
import re
import socket
import sys
import threading
import time

RESET = "\033[0m"
DIM = "\033[2m"
BOLD = "\033[1m"
MARK = "\033[1;36m"      # a performance mark's own lines
ENGINE = "\033[0;33m"    # the engine's detailed stats lines
BAD = "\033[1;31m"
# Everything a terminal could act on: C0 controls (ESC among them) but tab, DEL, and the C1 controls.
CONTROL = re.compile("[\x00-\x08\x0b-\x1f\x7f-\x9f]")


def clean(line: str, limit: int) -> str:
    # A peer's line as it may be printed and stored: no control characters, at most limit characters.
    line = CONTROL.sub("", line)
    return line if len(line) <= limit else line[:limit] + f" [... {len(line) - limit} more characters cut]"


def local_addresses() -> list[str]:
    """The addresses this computer can be reached on, best guess first."""
    found: list[str] = []
    try:
        # No packet is sent: this only asks the routing table which address would be used.
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            probe.connect(("192.0.2.1", 9))
            found.append(probe.getsockname()[0])
        finally:
            probe.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            found.append(info[4][0])
    except OSError:
        pass
    unique = []
    for address in found:
        if address and not address.startswith("127.") and address not in unique:
            unique.append(address)
    return unique


def stamp() -> str:
    now = dt.datetime.now()
    return now.strftime("%H:%M:%S.") + f"{now.microsecond // 1000:03d}"


def colour_for(line: str) -> str:
    if "[mark]" in line:
        return MARK
    if line.startswith("stats ") or line.startswith("  "):
        return ENGINE
    if "FATAL SIGNAL" in line or "[crash]" in line:
        return BAD
    return ""


def serve_connection(conn: socket.socket, peer: str, out, args, lock: threading.Lock) -> None:
    with conn:
        conn.settimeout(None)
        reader = conn.makefile("rb")
        with lock:
            note = f"---- connected: {peer} at {dt.datetime.now().isoformat(timespec='seconds')} ----"
            out.write(note + "\n")
            out.flush()
            if not args.quiet:
                print(f"{DIM}{note}{RESET}", flush=True)
        try:
            while True:
                # At most a little over one line's worth at a time: a peer sending no newline cannot fill memory.
                raw = reader.readline(args.max_line * 4 + 2)
                if not raw:
                    break
                while not raw.endswith(b"\n") and len(raw) >= args.max_line * 4 + 2:
                    rest = reader.readline(args.max_line * 4 + 2)  # the rest of an over-long line is dropped
                    if not rest or rest.endswith(b"\n"):
                        break
                line = clean(raw.decode("utf-8", "replace").rstrip("\r\n"), args.max_line)
                with lock:
                    out.write(line + "\n")
                    out.flush()
                if args.quiet:
                    continue
                colour = colour_for(line)
                prefix = f"{DIM}{stamp()}{RESET} " if args.stamp_console else ""
                print(f"{prefix}{colour}{line}{RESET}" if colour else f"{prefix}{line}", flush=True)
        except (ConnectionError, OSError) as error:
            with lock:
                note = f"---- {peer} went away: {error} ----"
                out.write(note + "\n")
                out.flush()
                if not args.quiet:
                    print(f"{DIM}{note}{RESET}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Receive Solstice's log over the network and write it to a file.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--port", type=int, default=7777, help="TCP port to listen on")
    parser.add_argument("--bind", default="0.0.0.0", help="address to listen on")
    parser.add_argument("--allow", action="append", default=[], metavar="ADDRESS",
                        help="take connections only from this address (the phone's; repeat for more); default: anyone")
    parser.add_argument("--max-line", type=int, default=4096, help="characters kept of one line")
    parser.add_argument("--out", default="solstice-stream.log", help="file to append the log to")
    parser.add_argument("--quiet", action="store_true", help="write the file only, print nothing")
    parser.add_argument("--no-stamp", dest="stamp_console", action="store_false",
                        help="print lines without a local time in front (a time is shown by default)")
    args = parser.parse_args()

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        listener.bind((args.bind, args.port))
    except OSError as error:
        print(f"cannot listen on {args.bind}:{args.port}: {error}", file=sys.stderr)
        return 1
    listener.listen(4)

    out = open(args.out, "a", encoding="utf-8")
    lock = threading.Lock()

    if not args.quiet:
        print(f"{BOLD}Solstice log stream{RESET} on port {args.port}, appending to {args.out}")
        addresses = local_addresses()
        if addresses:
            print("Type one of these into Solstice, Settings > Log stream:")
            for address in addresses:
                print(f"  {BOLD}{address}{RESET}   port {args.port}")
        else:
            print("Could not work out this computer's address; use its IP from System Settings.")
        print(f"{DIM}Ctrl-C stops it.{RESET}", flush=True)

    try:
        while True:
            conn, peer = listener.accept()
            peer_name = f"{peer[0]}:{peer[1]}"
            if args.allow and peer[0] not in args.allow:
                conn.close()
                if not args.quiet:
                    print(f"{DIM}---- refused {peer_name}: not in --allow ----{RESET}", flush=True)
                continue
            threading.Thread(target=serve_connection, args=(conn, peer_name, out, args, lock),
                             daemon=True).start()
    except KeyboardInterrupt:
        if not args.quiet:
            print("\nstopped")
    finally:
        listener.close()
        out.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
