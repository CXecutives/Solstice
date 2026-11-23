#!/usr/bin/env bash
# Rewrite everything in the repository that is generated from something else. CI runs it and fails when the
# result differs from what is checked in, so generated files are never edited by hand.
set -euo pipefail
cd "$(dirname "$0")/.."
py=python3
command -v python3 > /dev/null 2>&1 || py="py -3"
$py tools/map.py # MAP.md: every source file with its purpose
