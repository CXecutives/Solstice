#!/usr/bin/env python3
"""Print the engine settings the app ships with (EngineTuning.swift: upstream's table, then Solstice's over it) as
KEY=VALUE lines, so CI runs the engine tests with exactly them: `env $(python3 tools/shipped_env.py) make core-test`.
Names come from the settings table (core/knobs.def): a name or value it does not take fails here."""
import pathlib
import re
import sys

sys.dont_write_bytecode = True  # no __pycache__ in tools/
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import knobs  # noqa: E402

SRC = pathlib.Path(__file__).resolve().parent.parent / "ios" / "Solstice" / "EngineTuning.swift"


def table(text: str, name: str, by_case: dict) -> dict:
    m = re.search(r"static let " + name + r": \[EngineKnob: String\] = \[(.*?)\n\s*\]", text, re.S)
    if not m:
        sys.exit(f"shipped_env: table '{name}' not found in {SRC}")
    pairs = re.findall(r'^\s*\.(\w+):\s*"([^"]*)"', m.group(1), re.M)
    if not pairs:
        sys.exit(f"shipped_env: table '{name}' has no entries")
    env = {}
    for case, value in pairs:
        k = by_case.get(case)
        if not k:
            sys.exit(f"shipped_env: .{case} in '{name}' is not in core/knobs.def")
        why = k.check(value)
        if why:
            sys.exit(f"shipped_env: {k.name}={value} in '{name}' is {why}")
        env[k.name] = value
    return env


def main() -> None:
    by_case = {k.swift: k for k in knobs.table()}
    text = SRC.read_text(encoding="utf-8")
    env = table(text, "upstream", by_case)
    env.update(table(text, "solstice", by_case))
    for key in sorted(env):
        print(f"{key}={env[key]}")


if __name__ == "__main__":
    main()
