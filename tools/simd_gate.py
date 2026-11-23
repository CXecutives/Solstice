#!/usr/bin/env python3
"""SIMD gate: the engine paths that run from translated code with the guest's q0-q31 still live.

host/enter.S's helper thunks save only x0-x17 and NZCV before calling hv_tlb_refill,
hv_ijc_resolve and hv_light (SVC, ERET, WFE). Anything those reach must not touch SIMD/FP registers, and must not call into
libc (memset, memcpy, calloc ... use SIMD). This walks the call graph of the built iOS objects
from those roots (calls by name, and by address to static functions in the same object) and
fails on any external call not in tools/simd_gate.allow, or on any SIMD register in a reached
function. Run after `make ios-lib`:  python3 tools/simd_gate.py build/ios
"""
import re, subprocess, sys
from bisect import bisect_right
from pathlib import Path

ROOTS = ["_hv_tlb_refill", "_hv_ijc_resolve", "_hv_light"]
LINE = re.compile(r"^([0-9a-f]{8,16})\s+(\S+)\s*(.*)$")
LABEL = re.compile(r"^(_?[A-Za-z0-9_$.]+):\s*$")
SIMD = re.compile(r"(?<![\w.])[vqdsbh](?:[0-9]|[12][0-9]|3[01])(?![\w])")
CALLS = {"bl", "b"}
# otool -rv: "address pcrel length extern type scattered symbolnum/value". A call to another function is a BR26
# relocation naming it (the bl itself reads "bl 0x<its own address>" until it is linked, so otool -tV alone missed it).
RELOC = re.compile(r"^([0-9a-f]{8})\s+(?:True|False)\s+\S+\s+(True|False)\s+(\S+)\s+\S+\s+(\S+)")


def is_bitcode(obj):
    """An LTO object (LLVM bitcode, the app's link makes its code): nothing to read here. What the roots reach must
    be in plain objects, so a call into one of these counts as an external call and fails the gate."""
    head = Path(obj).read_bytes()[:4]
    return head in (bytes.fromhex("4243c0de"), bytes.fromhex("dec0170b"))  # raw bitcode, bitcode wrapper


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


def calls_by_relocation(obj):
    """[(address, symbol)] for every branch relocation in __TEXT,__text."""
    out = subprocess.run(["otool", "-rv", str(obj)], capture_output=True, text=True, check=True).stdout
    text, calls = False, []
    for line in out.splitlines():
        if line.startswith("Relocation information"):
            text = "(__TEXT,__text)" in line
            continue
        m = RELOC.match(line)
        if text and m and m.group(3) == "BR26" and m.group(2) == "True":
            calls.append((int(m.group(1), 16), m.group(4)))
    return calls


def main(build_dir):
    objs = sorted(Path(build_dir).glob("core/*.o")) + sorted(Path(build_dir).glob("host/*.o"))
    if not objs:
        sys.exit(f"simd_gate: no objects under {build_dir}; run `make ios-lib` first")
    graph, simd, insns_of, indirect = {}, {}, {}, {}
    nreloc = 0
    lto = [o.name for o in objs if is_bitcode(o)]
    objs = [o for o in objs if o.name not in lto]
    if lto:
        print(f"simd_gate: {len(lto)} LTO objects not read (their code is made at link time)")
    for obj in objs:
        funcs, at = disassemble(obj)
        starts = sorted(at)
        by_reloc = {}
        relocs = calls_by_relocation(obj)
        nreloc += len(relocs)
        for addr, sym in relocs:
            i = bisect_right(starts, addr) - 1
            if i >= 0:
                by_reloc.setdefault(at[starts[i]], []).append(sym)
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
                if mn in ("blr", "br", "blraa", "blrab", "braa", "brab"):
                    indirect.setdefault(key, []).append(f"{mn} {ops}")
            callees += [c for c in by_reloc.get(f, []) if c != f and c not in callees]
            if key in graph:  # same global name in two objects: keep both edge sets
                graph[key] += callees
            else:
                graph[key] = callees
    if nreloc == 0:  # every engine object calls something: none found means otool's format was not parsed
        sys.exit("simd_gate: no call relocations found in any object: the relocations were not parsed")
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
    calls = sum(len(graph.get(r, [])) for r in ROOTS)
    print(f"simd_gate: calls out of the roots: {calls}")
    jumps = [f"{f}: {i}" for f in reached for i in indirect.get(f, [])[:2]]
    if jumps:  # function pointers: not followed; each must be one of the engine's own (checked by reading)
        print("simd_gate: indirect calls in reached functions (not followed):\n  " + "\n  ".join(jumps[:20]))
    if hits:
        print("simd_gate: SIMD registers in reached functions:\n  " + "\n  ".join(hits[:30]))
    if bad:
        print("simd_gate: NOT ALLOWED (would clobber the guest's q0-q31): " + ", ".join(bad))
    sys.exit(1 if bad or hits else 0)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/ios")
