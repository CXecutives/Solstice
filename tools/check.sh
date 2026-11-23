#!/usr/bin/env bash
# Run engine tests in CI for what a change touched: tools/check.sh test_jit test_mem
# (no names = all engine tests). Pushes the current branch first; CI is the only Mac we have.
# Exit code = the run's result.
set -euo pipefail
cd "$(dirname "$0")/.."
export GH_REPO=CXecutives/Solstice # never the upstream remote
tests="${*:-all}"
ipa="${SOLSTICE_IPA:-false}"
san="${SOLSTICE_SAN:-false}" # SOLSTICE_SAN=true: the tests again with undefined-behaviour traps
branch="$(git rev-parse --abbrev-ref HEAD)"
git push -q origin "$branch"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
out="$(gh workflow run build-henge.yml --ref "$branch" -f tests="$tests" -f ipa="$ipa" -f san="$san" 2>&1)"
echo "$out"
# gh prints the new run's URL; older versions do not, and then the run is looked up (it takes a while to be listed).
run="$(printf '%s\n' "$out" | sed -n 's#.*/actions/runs/\([0-9][0-9]*\).*#\1#p' | head -1)"
for _ in $(seq 1 36); do
  [ -n "$run" ] && break
  sleep 5
  run="$(gh run list --workflow build-henge.yml --branch "$branch" --event workflow_dispatch --limit 1 \
         --json databaseId,createdAt -q '.[0] | select(.createdAt > "'"$started"'") | .databaseId')"
  [ -n "$run" ] && break
done
[ -n "$run" ] || { echo "the run did not show up" >&2; exit 1; }
echo "run $run: tests=$tests ipa=$ipa san=$san"
gh run watch "$run" --exit-status --interval 30 > /dev/null || {
  gh run view "$run" --log-failed | tail -60
  exit 1
}
if [ "$ipa" = true ]; then
  # Only the new IPA replaces the old one; anything else in out/ stays.
  tmp=$(mktemp -d)
  gh run download "$run" -n Solstice-ipa -D "$tmp"
  mkdir -p out && mv -f "$tmp"/*.ipa out/ && rm -rf "$tmp"
  ls -la out
fi
echo "run $run: ok"
