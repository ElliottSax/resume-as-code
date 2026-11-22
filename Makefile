# Every CI job is one of these targets, so "it passed locally" and "it passed
# in CI" are the same statement. Run `make` for the list.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

CHART    := deploy/helm/resume
CLUSTER  ?= resume-drill
IMAGE    ?= resume:local
OUT      := out
COMMIT   := $(shell git rev-parse --verify -q HEAD 2>/dev/null || echo 0000000000000000000000000000000000000000)
VERSION  := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
CRDS     := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: tools
tools: ## Install every pinned, checksum-verified tool from tools.env
	scripts/install-tools.sh

## ---- static checks (what CI runs on every pull request) ----

.PHONY: check
check: test lint-go lint-chart test-policy test-alerts lint-shell lint-actions scan-config lint-terraform ## Run every static check

.PHONY: test
test: ## Go unit tests with the race detector and coverage
	@mkdir -p $(OUT)
	@# -json feeds the published receipts; jq turns it back into readable output.
	@status=0; cd app && CGO_ENABLED=1 go test -race -count=1 -coverprofile=../$(OUT)/coverage.out -json ./... > ../$(OUT)/test.json || status=$$?; \
	  jq -rj 'select(.Action == "output") | .Output' ../$(OUT)/test.json | grep -vE '^(=== (RUN|PAUSE|CONT|NAME)|    --- PASS|--- PASS|PASS$$)' || true; \
	  exit $$status
	@cd app && go tool cover -func=../$(OUT)/coverage.out | tail -1
	@echo "passed: $$(jq -s '[.[] | select(.Action == "pass" and .Test != null)] | length' $(OUT)/test.json) tests"

.PHONY: lint-go
lint-go: ## golangci-lint (gosec, errorlint, revive, ...)
	cd app && golangci-lint run ./...

.PHONY: lint-chart
lint-chart: ## Helm lint, kubeconform schema checks and Kyverno policies on the rendered chart
	@mkdir -p $(OUT)
	helm lint --strict $(CHART)
	helm lint --strict $(CHART) --set metrics.serviceMonitor.enabled=true,metrics.prometheusRule.enabled=true,metrics.grafanaDashboard.enabled=true,httpRoute.enabled=true
	helm template resume $(CHART) --namespace resume \
	  --api-versions monitoring.coreos.com/v1/ServiceMonitor \
	  --api-versions monitoring.coreos.com/v1/PrometheusRule \
	  --set image.digest=sha256:0000000000000000000000000000000000000000000000000000000000000000 \
	  --set metrics.serviceMonitor.enabled=true,metrics.prometheusRule.enabled=true,metrics.grafanaDashboard.enabled=true \
	  --set httpRoute.enabled=true,httpRoute.parentRefs[0].name=public > $(OUT)/rendered.yaml
	kubeconform -strict -summary -kubernetes-version $$(source tools.env; echo $$KUBECTL_VERSION) \
	  -schema-location default -schema-location '$(CRDS)' $(OUT)/rendered.yaml
	kyverno apply policy/workload-policies.yaml --resource $(OUT)/rendered.yaml

.PHONY: test-policy
test-policy: ## Prove each Kyverno policy passes good manifests and catches bad ones
	kyverno test policy/tests

.PHONY: test-alerts
test-alerts: ## Validate the SLO rules and replay the alert unit tests
	promtool check rules $(CHART)/files/slo-rules.yaml
	promtool test rules observability/tests/slo-rules.test.yaml

.PHONY: lint-shell
lint-shell: ## shellcheck every script
	shellcheck scripts/*.sh

.PHONY: lint-actions
lint-actions: ## actionlint the GitHub workflows (runs shellcheck on run: blocks too)
	actionlint

.PHONY: scan-config
scan-config: ## Trivy misconfiguration scan of the Dockerfile, Helm chart and Terraform
	@# The policy test fixture is insecure on purpose, and out/ holds the
	@# drill's deliberately privileged pod. Everything else must be clean.
	trivy config --quiet --exit-code 1 --severity HIGH,CRITICAL \
	  --skip-dirs $(OUT) --skip-files policy/tests/resources.yaml .

.PHONY: lint-terraform
lint-terraform: ## terraform fmt/validate and tflint for every module
	terraform fmt -check -recursive infra/terraform
	@for d in infra/terraform/*/; do \
	  echo "--- $$d"; \
	  terraform -chdir=$$d init -backend=false -input=false >/dev/null; \
	  terraform -chdir=$$d validate; \
	  (cd $$d && tflint --init >/dev/null && tflint); \
	done

## ---- containers ----

.PHONY: image
image: ## Build the container image
	docker build -t $(IMAGE) --build-arg VERSION=$(VERSION) --build-arg COMMIT=$(COMMIT) \
	  --build-arg BUILD_DATE=$$(date -u +%Y-%m-%dT%H:%M:%SZ) .

.PHONY: scan
scan: ## Trivy vulnerability scan of the image (fails on fixable HIGH/CRITICAL)
	trivy image --scanners vuln --ignore-unfixed --severity HIGH,CRITICAL --exit-code 1 $(IMAGE)

## ---- Kubernetes ----

.PHONY: drill
drill: image ## Build a throwaway cluster, deploy, attack it under load, judge the SLO
	IMAGE=$(IMAGE) CLUSTER_NAME=$(CLUSTER) scripts/drill.sh

.PHONY: up
up: image ## Leave a local cluster running with the app deployed (see the URL at the end)
	IMAGE=$(IMAGE) CLUSTER_NAME=$(CLUSTER) scripts/drill.sh --deploy-only

.PHONY: observe
observe: ## Add Prometheus + Grafana to the `up` cluster and wire in the SLO dashboard
	CLUSTER_NAME=$(CLUSTER) scripts/observe.sh

.PHONY: down
down: ## Delete the local cluster
	kind delete cluster --name $(CLUSTER)

## ---- site ----

.PHONY: preview
preview: ## Export the static site with sample receipts to out/site
	cd app && go run . export -out ../$(OUT)/site -receipts internal/site/testdata/receipts.json
	@echo "open $(OUT)/site/index.html"

.PHONY: clean
clean: ## Remove build output
	rm -rf $(OUT)
