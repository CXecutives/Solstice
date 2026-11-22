#!/usr/bin/env python3
"""SIMD gate: the engine paths that run from translated code with the guest's q0-q31 still live.

host/enter.S's helper thunks save only x0-x17 and NZCV before calling hv_tlb_refill and
hv_ijc_resolve. Anything those reach must not touch SIMD/FP registers, and must not call into
libc (memset, memcpy, calloc ... use SIMD). This walks the call graph of the built iOS objects
from those roots (calls by name, and by address to static functions in the same object) and
fails on any external call not in tools/simd_gate.allow, or on any SIMD register in a reached
function. Run after `make ios-lib`:  python3 tools/simd_gate.py build/ios
"""
import re, subprocess, sys
from pathlib import Path

ROOTS = ["_hv_tlb_refill", "_hv_ijc_resolve"]
LINE = re.compile(r"^([0-9a-f]{8,16})\s+(\S+)\s*(.*)$")
LABEL = re.compile(r"^(_?[A-Za-z0-9_$.]+):\s*$")
SIMD = re.compile(r"(?<![\w.])[vqdsbh](?:[0-9]|[12][0-9]|3[01])(?![\w])")
CALLS = {"bl", "b"}


def disassemble(obj):
    """{function: [(mnemonic, operands)]} and {address: function} for one object."""
    out = subprocess.run(["otool", "-tV", str(obj)], capture_output=True, text=True, check=True).stdout
    funcs, at, cur, pending = {}, {}, None, None
    for line in out.splitlines():
        m = LABEL.match(line)
        if m and not line.startswith(str(obj)) and "(__TEXT" not in line:
            cur = m.group(1)
            funcs.setdefault(cur, [])
            pending = cur
            continue
        m = LINE.match(line)
        if m and cur is not None:
            addr = int(m.group(1), 16)
            if pending:
                at[addr] = pending
                pending = None
            funcs[cur].append((m.group(2), m.group(3).split(";")[0].strip()))
    return funcs, at


def main(build_dir):
    objs = sorted(Path(build_dir).glob("core/*.o")) + sorted(Path(build_dir).glob("host/*.o"))
    if not objs:
        sys.exit(f"simd_gate: no objects under {build_dir}; run `make ios-lib` first")
    graph, simd, insns_of = {}, {}, {}
    for obj in objs:
        funcs, at = disassemble(obj)
        for f, insns in funcs.items():
            key = f if f.startswith("_") else f"{obj.name}:{f}"
            insns_of[key] = insns
            callees = []
            for mn, ops in insns:
                if mn in CALLS:
                    tgt = ops.split()[0] if ops else ""
                    if tgt.startswith("_"):
                        callees.append(tgt)
                    elif tgt.startswith("0x"):
                        name = at.get(int(tgt, 16))
                        if name and name != f:
                            callees.append(name if name.startswith("_") else f"{obj.name}:{name}")
                elif SIMD.search(ops) and not mn.startswith(("prfm", "hint")):
                    simd.setdefault(key, []).append(f"{mn} {ops}")
            if key in graph:  # same global name in two objects: keep both edge sets
                graph[key] += callees
            else:
                graph[key] = callees
    allow_file = Path(__file__).with_name("simd_gate.allow")
    allow = {l.split("#")[0].strip() for l in allow_file.read_text().splitlines()} - {""}

    seen, todo, externals = set(), list(ROOTS), set()
    while todo:
        f = todo.pop()
        if f in seen:
            continue
        seen.add(f)
        if f not in graph:
            externals.add(f)
            continue
        todo += graph[f]

    reached = sorted(seen - externals)
    # All inlined is fine; an empty or missing root means the parse went wrong, not that all is well.
    sizes = {r: len(insns_of.get(r, [])) for r in ROOTS}
    print("simd_gate: instructions checked: " + ", ".join(f"{r} {n}" for r, n in sizes.items()))
    if any(n == 0 for n in sizes.values()):
        sys.exit("simd_gate: a root has no instructions: the disassembly was not parsed")
    bad = sorted(externals - allow)
    hits = [f"{f}: {i}" for f in reached for i in simd.get(f, [])[:3]]
    print(f"simd_gate: {len(reached)} engine functions reached from {', '.join(ROOTS)}: {', '.join(reached)}")
    print("simd_gate: external calls reached: " + (", ".join(sorted(externals)) or "none"))
    if hits:
        print("simd_gate: SIMD registers in reached functions:\n  " + "\n  ".join(hits[:30]))
    if bad:
        print("simd_gate: NOT ALLOWED (would clobber the guest's q0-q31): " + ", ".join(bad))
    sys.exit(1 if bad or hits else 0)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/ios")
