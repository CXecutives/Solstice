#!/usr/bin/env python3
"""Fails when the old name "Henge" appears anywhere in the tracked sources, in any spelling, outside a short list.

Everything is called Solstice: what a person sees, and every symbol, file, key and label underneath. What may
still say Henge: the credit and licence texts, the notes that tell the project's history, and the list of old
names that Set Up removes from a Mac made by an earlier build (host/brand.h).
Only needs python3; run from anywhere: python3 tools/brand_gate.py

It also refuses a middle dot or a dash used as punctuation in any text of the app (the owner's rule for how
texts read), and checks that the places which cannot include host/brand.h (the Makefile, ios/project.yml) name
the helper like brand.h does.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

CODE = {".swift", ".c", ".h", ".m", ".S"}
PLIST = {".plist"}

# Files that may spell the old name: where the project comes from, its history, the old names to remove, this script.
WHOLE_FILE = {"NOTICE", "README.md", "LICENSE", "HANDOFF.md", "PLAN.md", "CLAUDE.md", "host/brand.h",
              "tools/brand_gate.py"}
# Elsewhere, a line with the old name is fine only when it matches one of these.
ALLOWED = [
    (r"Based on Henge by Leviidev", "the credit line"),
    (r'contains\("Henge"\)', "a test that the old name is gone"),
]
ALLOWED = [(re.compile(rx), why) for rx, why in ALLOWED]

# Texts are written plainly: no middle dot between words, no dash as punctuation.
MARKS = ("·", "—", "–")
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
PLIST_STRING = re.compile(r"<string>([^<]*)</string>")


def tracked():
    out = subprocess.check_output(["git", "ls-files"], cwd=ROOT, text=True)
    return [p for p in out.splitlines() if p]


def without_interpolations(line):
    """Swift's \\( ... ) inside a literal is code, not text: cut it out (parentheses balanced)."""
    out, i = [], 0
    while i < len(line):
        if line.startswith("\\(", i):
            depth, i = 1, i + 2
            while i < len(line) and depth:
                depth += (line[i] == "(") - (line[i] == ")")
                i += 1
        else:
            out.append(line[i])
            i += 1
    return "".join(out)


def texts(path, line):
    """The string literals of a line of code, or the strings of a plist line."""
    suffix = pathlib.Path(path).suffix
    if suffix in CODE:
        if line.lstrip().startswith(("//", "/*", "*")):
            return []
        return LITERAL.findall(without_interpolations(line) if suffix == ".swift" else line)
    if suffix in PLIST:
        return PLIST_STRING.findall(line)
    return []


def agent_names():
    """The helper's binary name from brand.h, and where the build scripts have to repeat it."""
    brand = (ROOT / "host/brand.h").read_text(encoding="utf-8")
    m = re.search(r'#define SOLSTICE_AGENT_BINARY "([^"]+)"', brand)
    if not m:
        return ["host/brand.h: SOLSTICE_AGENT_BINARY is missing"]
    name = m.group(1)
    problems = []
    for f in ("Makefile", "ios/project.yml"):
        if name + ".gz" not in (ROOT / f).read_text(encoding="utf-8"):
            problems.append(f"{f}: does not build/copy {name}.gz (SOLSTICE_AGENT_BINARY in host/brand.h)")
    return problems


def main():
    names, marks = [], []
    for path in tracked():
        if "henge" in path.lower():
            names.append(f"{path}: the path itself")
        if path in WHOLE_FILE:
            continue
        try:
            lines = (ROOT / path).read_text(encoding="utf-8").splitlines()
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue
        for n, line in enumerate(lines, 1):
            if any(mark in line for mark in MARKS) and not path.startswith("tests/"):
                for text in texts(path, line):
                    if any(mark in text for mark in MARKS):
                        marks.append(f"{path}:{n}: {text[:100]!r}")
            if "henge" in line.lower() and not any(rx.search(line) for rx, _ in ALLOWED):
                names.append(f"{path}:{n}: {line.strip()[:100]}")
    names += agent_names()
    if names:
        print('brand gate: the old name "Henge" (everything is called Solstice; names live in host/brand.h):')
        for p in names:
            print("  " + p)
    if marks:
        print("brand gate: a middle dot or a dash as punctuation in a text (write a comma, a colon or two sentences):")
        for p in marks:
            print("  " + p)
    if names or marks:
        return 1
    print("brand gate: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
