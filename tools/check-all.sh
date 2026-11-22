#!/usr/bin/env bash
# End of a block: every engine test, the iOS build with the SIMD gate, and the IPA into out/Solstice.ipa.
set -euo pipefail
SOLSTICE_IPA=true exec "$(dirname "$0")/check.sh" "$@"
