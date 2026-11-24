#!/usr/bin/env bash
# Screenshots of every app screen (iPhone and iPad, light and dark, sample data) from CI into out/screens/, with
# out/screens/index.html to see them all at once. Pushes the current branch first; the exit code is the run's.
set -euo pipefail
cd "$(dirname "$0")/.."
# Arguments narrow it down: screen names and/or a device, e.g. tools/screens.sh iphone session-error home.
SOLSTICE_SCREENS=true SOLSTICE_SCREENS_ONLY="$*" SOLSTICE_IPA=false SOLSTICE_SAN=false exec tools/check.sh none
