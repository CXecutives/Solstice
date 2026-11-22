#!/usr/bin/env python3
"""SIMD gate: the engine paths that run from translated code with the guest's q0-q31 still live.

host/enter.S's helper thunks save only x0-x17 and NZCV before calling hv_tlb_refill and
hv_ijc_resolve. Anything those reach must not touch SIMD/FP registers, and must not call into
libc (memset, memcpy, calloc ... use SIMD). This walks the call graph of the built iOS objects
from those roots and fails on any external call not in tools/simd_gate.allow, or on any SIMD
register in a reached function. Run after `make ios-lib`:  python3 tools/simd_gate.py build/ios
"""
import re, subprocess, sys
from pathlib import Path

ROOTS = ["_hv_tlb_refill", "_hv_ijc_resolve"]
CALL = re.compile(r"^\s*(?:[0-9a-f]+\s+)?(?:bl|b)\s+(_[A-Za-z0-9_$.]+)\s*$")
SIMD = re.compile(r"\b[vqdsbh](?:[0-9]|[12][0-9]|3[01])\b(?:\.[0-9]*[bhsd])?")
LABEL = re.compile(r"^(_[A-Za-z0-9_$.]+):\s*$")


def disassemble(objs):
    out = subprocess.run(["otool", "-tV", *map(str, objs)], capture_output=True, text=True, check=True).stdout
    funcs, cur = {}, None
    for line in out.splitlines():
        m = LABEL.match(line)
        if m:
            cur = m.group(1)
            funcs.setdefault(cur, [])
            continue
        if cur is not None and line.strip():
            funcs[cur].append(line)
    return funcs


def main(build_dir):
    objs = sorted(Path(build_dir).glob("core/*.o")) + sorted(Path(build_dir).glob("host/*.o"))
    if not objs:
        sys.exit(f"simd_gate: no objects under {build_dir}; run `make ios-lib` first")
    funcs = disassemble(objs)
    allow_file = Path(__file__).with_name("simd_gate.allow")
    allow = {l.split("#")[0].strip() for l in allow_file.read_text().splitlines()} - {""}

    seen, todo, externals, simd = set(), list(ROOTS), set(), []
    while todo:
        f = todo.pop()
        if f in seen:
            continue
        seen.add(f)
        if f not in funcs:
            externals.add(f)
            continue
        for line in funcs[f]:
            m = CALL.match(line)
            if m:
                todo.append(m.group(1))
            elif SIMD.search(line.split(";")[0].split("\t", 2)[-1]):
                simd.append(f"{f}: {line.strip()}")

    bad = sorted(externals - allow)
    print(f"simd_gate: {len(seen - externals)} engine functions reached from {', '.join(ROOTS)}")
    print("simd_gate: external calls reached: " + (", ".join(sorted(externals)) or "none"))
    if simd:
        print("simd_gate: SIMD registers in reached functions:\n  " + "\n  ".join(simd[:20]))
    if bad:
        print("simd_gate: NOT ALLOWED (would clobber the guest's q0-q31): " + ", ".join(bad))
    sys.exit(1 if bad or simd else 0)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/ios")
