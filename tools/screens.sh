#!/usr/bin/env bash
# Screenshots of every app screen (iPhone and iPad, light and dark, sample data) from CI into out/screens/, with
# out/screens/index.html to see them all at once. Pushes the current branch first; the exit code is the run's.
set -euo pipefail
cd "$(dirname "$0")/.."
SOLSTICE_SCREENS=true SOLSTICE_IPA=false SOLSTICE_SAN=false exec tools/check.sh none
