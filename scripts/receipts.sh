#!/usr/bin/env bash
# Assemble receipts.json from raw tool output, for the published page.
#
#   scripts/receipts.sh out > out/receipts.json
#
# Inputs (all produced earlier in the delivery pipeline):
#   test.json, coverage.out   go test -json and its coverage profile
#   image.json                scripts/image-facts.sh
#   scan.json                 trivy image --format json
#   drill.json                scripts/drill.sh
#
# Nothing here is typed by hand: every number is computed from those files.
set -euo pipefail

dir=$(cd "${1:-out}" && pwd)
repo=${GITHUB_REPOSITORY:-ElliottSax/resume-as-code}
commit=${GITHUB_SHA:-$(git rev-parse HEAD)}
run_url="${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/${GITHUB_RUN_ID:-0}"

for f in test.json coverage.out image.json scan.json drill.json; do
  if [[ ! -s "$dir/$f" ]]; then
    echo "receipts: missing $dir/$f" >&2
    exit 1
  fi
done

passed=$(jq -s '[.[] | select(.Action == "pass" and .Test != null)] | length' "$dir/test.json")
coverage=$(cd "$(dirname "$0")/../app" && go tool cover -func="$dir/coverage.out" | awk 'END { sub("%", "", $3); print $3 }')

jq -n \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg repo "$repo" \
  --arg commit "$commit" \
  --arg run_url "$run_url" \
  --argjson passed "$passed" \
  --argjson coverage "$coverage" \
  --slurpfile image "$dir/image.json" \
  --slurpfile scan "$dir/scan.json" \
  --slurpfile drill "$dir/drill.json" '
  ([$scan[0].Results[]?.Vulnerabilities[]?.Severity]) as $sev
  | {
      generated_at: $generated_at,
      repo: $repo,
      commit: $commit,
      run_url: $run_url,
      image: $image[0],
      scan: {
        tool: "Trivy",
        critical: ($sev | map(select(. == "CRITICAL")) | length),
        high: ($sev | map(select(. == "HIGH")) | length),
        medium: ($sev | map(select(. == "MEDIUM")) | length),
        low: ($sev | map(select(. == "LOW")) | length)
      },
      tests: { passed: $passed, coverage_pct: $coverage },
      drill: $drill[0]
    }'
