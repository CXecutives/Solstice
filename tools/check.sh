#!/usr/bin/env bash
# Run engine tests in CI for what a change touched: tools/check.sh test_jit test_mem
# (no names = all engine tests). Pushes the current branch first; CI is the only Mac we have.
# Exit code = the run's result.
set -euo pipefail
cd "$(dirname "$0")/.."
tests="${*:-all}"
ipa="${SOLSTICE_IPA:-false}"
branch="$(git rev-parse --abbrev-ref HEAD)"
git push -q origin "$branch"
gh workflow run build-henge.yml --ref "$branch" -f tests="$tests" -f ipa="$ipa"
sleep 5
run="$(gh run list --workflow build-henge.yml --branch "$branch" --limit 1 --json databaseId -q '.[0].databaseId')"
echo "run $run: tests=$tests ipa=$ipa"
gh run watch "$run" --exit-status --interval 30 > /dev/null || {
  gh run view "$run" --log-failed | tail -60
  exit 1
}
if [ "$ipa" = true ]; then
  rm -rf out && mkdir -p out
  gh run download "$run" -n Solstice-ipa -D out
  ls -la out
fi
echo "run $run: ok"
