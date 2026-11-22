#!/usr/bin/env bash
# Rehearse delivery.yml's release path against a throwaway registry.
#
# The real release only runs after a merge to main, so a bug in it would
# surface too late, once the change had already passed review. This walks
# the same steps on every pull request (and on a laptop):
#
#   build amd64 + arm64 and push    ->  read the image facts back
#   SBOM, scan record, arm64 gate   ->  pull by digest, export for kind
#   assemble receipts.json          ->  render the site
#
# Signing and attestation are left out: they need GitHub's OIDC identity,
# and the real pipeline refuses to deploy anything whose signature fails.
#
#   scripts/release-dry-run.sh                          # starts its own registry
#   REGISTRY=localhost:5000 scripts/release-dry-run.sh  # use a running one (CI)
#
# Inputs are the ones the publish job downloads: out/test.json and
# out/coverage.out (make test) and out/drill.json (make drill).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=../tools.env
source tools.env

OUT="$ROOT/out/release-dry-run"
step() { printf '\n==> %s\n' "$*"; }

for f in test.json coverage.out drill.json; do
  if [[ ! -s "out/$f" ]]; then
    echo "release-dry-run: out/$f is missing; run 'make test' and 'make drill' first" >&2
    exit 1
  fi
done

if [[ -z "${REGISTRY:-}" ]]; then
  REGISTRY=localhost:5055
  docker run -d --rm --name resume-dry-run-registry -p 127.0.0.1:5055:5000 "$REGISTRY_IMAGE" >/dev/null
  trap 'docker rm -f resume-dry-run-registry >/dev/null 2>&1 || true' EXIT
fi
for _ in $(seq 1 30); do
  curl -fsS "http://$REGISTRY/v2/" >/dev/null 2>&1 && break
  sleep 0.5
done
NAME="$REGISTRY/resume-as-code"
COMMIT=$(git rev-parse --verify -q HEAD 2>/dev/null || echo 0000000000000000000000000000000000000000)
rm -rf "$OUT" && mkdir -p "$OUT"

step "Building amd64 + arm64 and pushing to $REGISTRY"
docker buildx build --quiet --push --platform linux/amd64,linux/arm64 \
  --provenance=false --sbom=false --metadata-file "$OUT/build.json" \
  --build-arg VERSION=dry-run --build-arg COMMIT="$COMMIT" \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --tag "$NAME:dry-run" . >/dev/null
DIGEST=$(jq -r '."containerimage.digest"' "$OUT/build.json")
echo "$NAME@$DIGEST"

step "Reading the image facts back from the registry"
scripts/image-facts.sh "$NAME" "$DIGEST" | tee "$OUT/image.json"

step "Recording the SBOM and vulnerabilities, and gating the arm64 variant"
trivy image --quiet --format spdx-json --output "$OUT/sbom.spdx.json" "$NAME@$DIGEST"
trivy image --quiet --scanners vuln --format json --output "$OUT/scan.json" "$NAME@$DIGEST"
trivy image --quiet --platform linux/arm64 --scanners vuln --ignore-unfixed \
  --severity HIGH,CRITICAL --exit-code 1 "$NAME@$DIGEST"
echo "SBOM: $(jq '.packages | length' "$OUT/sbom.spdx.json") packages; arm64: no fixable HIGH or CRITICAL"

step "Pulling by digest and exporting for kind, as the drill job does"
docker pull --quiet "$NAME@$DIGEST" >/dev/null
docker tag "$NAME@$DIGEST" resume:dry-run
platform="linux/$(docker version --format '{{.Server.Arch}}')"
docker save --platform "$platform" -o "$OUT/image.tar" resume:dry-run 2>/dev/null \
  || docker save -o "$OUT/image.tar" resume:dry-run
echo "exported $(du -h "$OUT/image.tar" | cut -f1) for $platform"
rm -f "$OUT/image.tar"
docker image rm resume:dry-run >/dev/null

step "Assembling the receipts and rendering the site, as the publish job does"
cp out/test.json out/coverage.out out/drill.json "$OUT/"
scripts/receipts.sh "$OUT" > "$OUT/receipts.json"
(cd app && go run . export -out "$OUT/site" -receipts "$OUT/receipts.json")
cp "$OUT/sbom.spdx.json" "$OUT/site/"
grep -q 'This page has receipts' "$OUT/site/index.html"

step "Release dry run passed: out/release-dry-run/site/index.html"
