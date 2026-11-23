#!/usr/bin/env python3
"""Print the engine settings the app ships with (EngineTuning.swift: upstream's table, then Solstice's over it) as
KEY=VALUE lines, so CI runs the engine tests with exactly them: `env $(python3 tools/shipped_env.py) make core-test`."""
import pathlib
import re
import sys

SRC = pathlib.Path(__file__).resolve().parent.parent / "ios" / "Henge" / "EngineTuning.swift"


def table(text: str, name: str) -> dict:
    m = re.search(r"static let " + name + r": \[String: String\] = \[(.*?)\n\s*\]", text, re.S)
    if not m:
        sys.exit(f"shipped_env: table '{name}' not found in {SRC}")
    pairs = re.findall(r'^\s*"(HV_[A-Z0-9_]+)":\s*"([^"]*)"', m.group(1), re.M)
    if not pairs:
        sys.exit(f"shipped_env: table '{name}' has no HV_ entries")
    return dict(pairs)


def main() -> None:
    text = SRC.read_text(encoding="utf-8")
    env = table(text, "upstream")
    env.update(table(text, "solstice"))
    for key in sorted(env):
        print(f"{key}={env[key]}")


if __name__ == "__main__":
    main()
