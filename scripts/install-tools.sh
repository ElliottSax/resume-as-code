#!/usr/bin/env bash
# Install the exact tool versions pinned in tools.env.
#
# Every download is checked against the SHA-256 published with its release
# (or pinned in tools.env when the project publishes none). A mismatch aborts.
# CI uses this same script instead of third-party "setup-x" actions, which
# keeps the pipeline's supply chain small and identical to a laptop's.
#
#   scripts/install-tools.sh              # everything
#   scripts/install-tools.sh kind helm    # just these
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../tools.env
source "$ROOT/tools.env"

BIN="${BIN_DIR:-/usr/local/bin}"
if [[ ! -w "$BIN" ]]; then BIN="$HOME/.local/bin"; fi
mkdir -p "$BIN"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

GH=https://github.com
log() { printf '\033[1;34m==>\033[0m %-14s %s\n' "$1" "$2"; }
fetch() { curl -fsSL --retry 3 -o "$(basename "$1")" "$1"; }

# verify FILE SUMS_FILE : SUMS_FILE holds "<sha256>  <filename>" lines.
verify() {
  local want
  want=$(awk -v f="$1" '{n=$2; sub(/^\*/, "", n)} n==f {print $1; exit}' "$2")
  if [[ -z "$want" ]]; then echo "no checksum for $1 in $2" >&2; exit 1; fi
  echo "$want  $1" | sha256sum -c --quiet -
}

# verify_hash FILE SHA256 : for hashes pinned in tools.env.
verify_hash() { echo "$2  $1" | sha256sum -c --quiet -; }

install_go() {
  local f="go${GO_VERSION}.linux-amd64.tar.gz"
  fetch "https://go.dev/dl/$f"
  verify_hash "$f" "$GO_SHA256"
  local dest="${GO_ROOT_DIR:-$(dirname "$BIN")/go}"
  rm -rf "$dest" && mkdir -p "$dest"
  tar -xzf "$f" -C "$dest" --strip-components=1
  ln -sf "$dest/bin/go" "$BIN/go"
  ln -sf "$dest/bin/gofmt" "$BIN/gofmt"
}

install_kind() {
  local f=kind-linux-amd64
  fetch "$GH/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/$f"
  fetch "$GH/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/$f.sha256sum"
  verify "$f" "$f.sha256sum"
  install -m 0755 "$f" "$BIN/kind"
}

install_kubectl() {
  local base="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64"
  fetch "$base/kubectl"
  fetch "$base/kubectl.sha256"
  verify_hash kubectl "$(cat kubectl.sha256)"
  install -m 0755 kubectl "$BIN/kubectl"
}

install_helm() {
  local f="helm-v${HELM_VERSION}-linux-amd64.tar.gz"
  fetch "https://get.helm.sh/$f"
  fetch "https://get.helm.sh/$f.sha256sum"
  verify "$f" "$f.sha256sum"
  tar -xzf "$f" linux-amd64/helm
  install -m 0755 linux-amd64/helm "$BIN/helm"
}

install_kubeconform() {
  local f=kubeconform-linux-amd64.tar.gz
  local rel="$GH/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}"
  fetch "$rel/$f"
  fetch "$rel/CHECKSUMS"
  verify "$f" CHECKSUMS
  tar -xzf "$f" kubeconform
  install -m 0755 kubeconform "$BIN/kubeconform"
}

install_kyverno() {
  local f="kyverno-cli_v${KYVERNO_VERSION}_linux_x86_64.tar.gz"
  local rel="$GH/kyverno/kyverno/releases/download/v${KYVERNO_VERSION}"
  fetch "$rel/$f"
  fetch "$rel/checksums.txt"
  verify "$f" checksums.txt
  tar -xzf "$f" kyverno
  install -m 0755 kyverno "$BIN/kyverno"
}

install_promtool() {
  local d="prometheus-${PROMETHEUS_VERSION}.linux-amd64"
  local rel="$GH/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}"
  fetch "$rel/$d.tar.gz"
  fetch "$rel/sha256sums.txt"
  verify "$d.tar.gz" sha256sums.txt
  tar -xzf "$d.tar.gz" "$d/promtool"
  install -m 0755 "$d/promtool" "$BIN/promtool"
}

install_terraform() {
  local f="terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
  local rel="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}"
  fetch "$rel/$f"
  fetch "$rel/terraform_${TERRAFORM_VERSION}_SHA256SUMS"
  verify "$f" "terraform_${TERRAFORM_VERSION}_SHA256SUMS"
  unzip -oq "$f" terraform
  install -m 0755 terraform "$BIN/terraform"
}

install_tflint() {
  local f=tflint_linux_amd64.zip
  local rel="$GH/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}"
  fetch "$rel/$f"
  fetch "$rel/checksums.txt"
  verify "$f" checksums.txt
  unzip -oq "$f" tflint
  install -m 0755 tflint "$BIN/tflint"
}

install_trivy() {
  local f="trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
  local rel="$GH/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}"
  fetch "$rel/$f"
  fetch "$rel/trivy_${TRIVY_VERSION}_checksums.txt"
  verify "$f" "trivy_${TRIVY_VERSION}_checksums.txt"
  tar -xzf "$f" trivy
  install -m 0755 trivy "$BIN/trivy"
}

install_actionlint() {
  local f="actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"
  local rel="$GH/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}"
  fetch "$rel/$f"
  fetch "$rel/actionlint_${ACTIONLINT_VERSION}_checksums.txt"
  verify "$f" "actionlint_${ACTIONLINT_VERSION}_checksums.txt"
  tar -xzf "$f" actionlint
  install -m 0755 actionlint "$BIN/actionlint"
}

install_shellcheck() {
  local d="shellcheck-v${SHELLCHECK_VERSION}"
  local f="$d.linux.x86_64.tar.gz"
  fetch "$GH/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/$f"
  verify_hash "$f" "$SHELLCHECK_SHA256"
  tar -xzf "$f" "$d/shellcheck"
  install -m 0755 "$d/shellcheck" "$BIN/shellcheck"
}

install_golangci-lint() {
  local d="golangci-lint-${GOLANGCI_LINT_VERSION}-linux-amd64"
  local rel="$GH/golangci/golangci-lint/releases/download/v${GOLANGCI_LINT_VERSION}"
  fetch "$rel/$d.tar.gz"
  fetch "$rel/golangci-lint-${GOLANGCI_LINT_VERSION}-checksums.txt"
  verify "$d.tar.gz" "golangci-lint-${GOLANGCI_LINT_VERSION}-checksums.txt"
  tar -xzf "$d.tar.gz" "$d/golangci-lint"
  install -m 0755 "$d/golangci-lint" "$BIN/golangci-lint"
}

ALL=(go kind kubectl helm kubeconform kyverno promtool terraform tflint trivy actionlint shellcheck golangci-lint)
TOOLS=("$@")
if [[ ${#TOOLS[@]} -eq 0 ]]; then TOOLS=("${ALL[@]}"); fi

for t in "${TOOLS[@]}"; do
  if ! declare -F "install_$t" >/dev/null; then
    echo "unknown tool: $t (known: ${ALL[*]})" >&2
    exit 2
  fi
  "install_$t"
  log "$t" "installed to $BIN"
done

if [[ ":$PATH:" != *":$BIN:"* ]]; then
  echo "note: add $BIN to your PATH" >&2
fi
