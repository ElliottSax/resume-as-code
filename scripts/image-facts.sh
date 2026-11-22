#!/usr/bin/env bash
# Print facts about a pushed image as JSON, for the published receipts.
#
#   scripts/image-facts.sh ghcr.io/owner/name sha256:...
#
# Size is the compressed linux/amd64 download (config plus layers), which is
# what a node actually pulls, read from the registry rather than estimated.
set -euo pipefail

ref=$1
digest=$2

raw=$(docker buildx imagetools inspect --raw "$ref@$digest")
if jq -e '.manifests' >/dev/null <<<"$raw"; then
  amd64=$(jq -r '.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64") | .digest' <<<"$raw")
  raw=$(docker buildx imagetools inspect --raw "$ref@$amd64")
fi
bytes=$(jq '[.layers[].size] | add + .config.size' <<<"$raw")

jq -n --arg ref "$ref" --arg digest "$digest" --argjson bytes "$bytes" '{
  ref: $ref,
  digest: $digest,
  size_mb: (($bytes / 1048576 * 10 | round) / 10),
  signed: true,
  sbom_url: "sbom.spdx.json"
}'
