#!/usr/bin/env python3
"""Fails when a string literal with "Henge" or "henge" appears in the sources, outside a short, explicit allowlist.

Everything a person can see says Solstice (names live in host/brand.h). What stays "henge" is internal: the
settings keys, queue labels, the log prefix of the engine, identifiers that happen to sit inside a string.
Only needs python3; run from anywhere: python3 tools/brand_gate.py

It also refuses a middle dot or a dash used as punctuation in any text of the app (the owner's rule for how
texts read).

Also checks that the places which cannot include host/brand.h (the Makefile, ios/project.yml) name the
helper like brand.h does.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

CODE = {".swift", ".c", ".h", ".m", ".S"}
PLIST = {".plist"}
YAML = {".yml", ".yaml"}

# Files that may spell the old names: the list of what to remove, and this script.
WHOLE_FILE = {"host/brand.h", "tools/brand_gate.py"}

# A literal (its text without the quotes) that mentions henge is fine when it matches one of these.
ALLOWED = [
    (r"^henge\.", "UserDefaults keys, notification ids, queue labels (henge.*)"),
    (r"^com\.henge\.", "bundle identifier and queue labels (com.henge.*)"),
    (r"^henge$", "the os_log category"),
    (r"^\\?n?hengevm(-ref|-mac-test)[: ]", "the Mac test tools' names in their own messages (hengevm-ref, hengevm-mac-test)"),
    (r"^hengevm\.", "queue labels (hengevm.*)"),
    (r"^usage: hengevm", "usage text of the Mac test tool"),
    (r"^HENGEVM_", "an engine environment variable"),
    (r"^HENGESN1$", "the snapshot file's magic"),
    (r"^Henge/Pipelines$", "the saved pipelines' folder in the app's own storage"),
    (r"^henge-jit(-request|-response)?$", "the JIT script's resource name and the helper's message keys"),
    (r"^Henge[A-Z]\w*(\.appex)?$", "internal identifiers in strings (HengeBuildCommit, HengeJITHelper.appex, ...)"),
    (r"^henge_\w+", "C symbol names in strings"),
    (r"Based on Henge by Leviidev", "the credit line"),
    (r"-henge$", "version strings of third-party libraries built here"),
    (r"^ios/Henge/", "a path inside the repository"),
    (r"^Henge/", "a path inside the repository"),
    (r"^henge-ios-jit\.h$|^henge-vm\.h$|^Native/henge-", "an internal header name"),
]
# A test may assert that the old name is gone.
ALLOWED_IN_TESTS = r'contains\("Henge"\)'
ALLOWED = [(re.compile(rx), why) for rx, why in ALLOWED]

# Texts are written plainly: no middle dot between words, no dash as punctuation.
MARKS = ("·", "—", "–")

LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
PLIST_STRING = re.compile(r"<string>([^<]*)</string>")
# yml: only the keys that name what a person sees.
YAML_VISIBLE = re.compile(r"(CFBundleDisplayName|DISPLAY_NAME|INFOPLIST_KEY_\w*)\s*:\s*(.*)", re.I)


def tracked():
    out = subprocess.check_output(["git", "ls-files"], cwd=ROOT, text=True)
    return [p for p in out.splitlines() if p]


def allowed(text):
    return any(rx.search(text) for rx, _ in ALLOWED)


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


def candidates(path, line):
    suffix = pathlib.Path(path).suffix
    if suffix in CODE:
        if line.lstrip().startswith(("//", "/*", "*")):
            return []
        return LITERAL.findall(without_interpolations(line) if suffix == ".swift" else line)
    if suffix in PLIST:
        return PLIST_STRING.findall(line)
    if suffix in YAML:
        m = YAML_VISIBLE.search(line)
        return [m.group(2)] if m else []
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
    problems, marks = [], []
    for path in tracked():
        if path in WHOLE_FILE or pathlib.Path(path).suffix not in CODE | PLIST | YAML:
            continue
        try:
            lines = (ROOT / path).read_text(encoding="utf-8").splitlines()
        except (UnicodeDecodeError, FileNotFoundError):
            continue
        for n, line in enumerate(lines, 1):
            if any(mark in line for mark in MARKS) and not path.startswith("tests/"):
                for text in candidates(path, line):
                    if any(mark in text for mark in MARKS):
                        marks.append(f"{path}:{n}: {text[:100]!r}")
            if "henge" not in line.lower():
                continue
            if path.startswith("tests/") and re.search(ALLOWED_IN_TESTS, line):
                continue
            for text in candidates(path, line):
                if "henge" in text.lower() and not allowed(text):
                    problems.append(f"{path}:{n}: {text[:100]!r}")
    problems += agent_names()
    if problems:
        print("brand gate: visible or unlisted \"Henge\" in string literals (names belong in host/brand.h):")
        for p in problems:
            print("  " + p)
        return 1
    if marks:
        print("brand gate: a middle dot or a dash as punctuation in a text (write a comma, a colon or two sentences):")
        for p in marks:
            print("  " + p)
        return 1
    print("brand gate: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
