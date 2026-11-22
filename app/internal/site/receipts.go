package site

import (
	"encoding/json"
	"fmt"
	"os"
	"time"
)

// Receipts are facts measured by the delivery pipeline and baked into the
// published page: which commit, which image, what the scanners found and how
// the platform behaved under the chaos drill. Nothing in here is hand-typed;
// scripts/receipts.sh assembles it from tool output.
type Receipts struct {
	GeneratedAt time.Time `json:"generated_at"`
	Repo        string    `json:"repo"`
	Commit      string    `json:"commit"`
	RunURL      string    `json:"run_url"`
	Image       Image     `json:"image"`
	Scan        Scan      `json:"scan"`
	Tests       Tests     `json:"tests"`
	Drill       *Drill    `json:"drill,omitempty"`
}

// Image describes the container that served the drill.
type Image struct {
	Ref     string  `json:"ref"`
	Digest  string  `json:"digest"`
	SizeMB  float64 `json:"size_mb"`
	Signed  bool    `json:"signed"`
	SBOMURL string  `json:"sbom_url"`
}

// Scan is the vulnerability count by severity (fixable or not).
type Scan struct {
	Tool     string `json:"tool"`
	Critical int    `json:"critical"`
	High     int    `json:"high"`
	Medium   int    `json:"medium"`
	Low      int    `json:"low"`
}

// Tests summarises the unit test run.
type Tests struct {
	Passed      int     `json:"passed"`
	CoveragePct float64 `json:"coverage_pct"`
}

// Drill is the output of scripts/drill.sh: a throwaway Kubernetes cluster is
// built, the service is deployed and load-tested, and failures are injected
// while traffic flows.
type Drill struct {
	RanAt                time.Time `json:"ran_at"`
	Kubernetes           string    `json:"kubernetes"`
	Nodes                int       `json:"nodes"`
	ClusterCreateSeconds float64   `json:"cluster_create_seconds"`
	DeploySeconds        float64   `json:"deploy_seconds"`
	DurationSeconds      float64   `json:"duration_seconds"`
	Requests             int       `json:"requests"`
	Failed               int       `json:"failed"`
	SuccessPct           float64   `json:"success_pct"`
	P95Ms                float64   `json:"p95_ms"`
	P99Ms                float64   `json:"p99_ms"`
	PodsKilled           int       `json:"pods_killed"`
	Rollouts             int       `json:"rollouts"`
	NodeDrains           int       `json:"node_drains"`
	MaxReplicas          int       `json:"max_replicas"`
	PodSecurityRejected  bool      `json:"pod_security_rejected"`
	NetworkPolicyBlocked bool      `json:"network_policy_blocked"`
	SLO                  SLO       `json:"slo"`
}

// SLO is the objective the drill was judged against: AvailabilityPct of
// requests succeed, and LatencyPct of requests finish within LatencyMs.
// These match the production SLOs in docs/slo.md.
type SLO struct {
	AvailabilityPct float64 `json:"availability_pct"`
	LatencyPct      float64 `json:"latency_pct"`
	LatencyMs       float64 `json:"latency_ms"`
	Met             bool    `json:"met"`
}

// LoadReceipts reads a receipts.json file. An empty path means "no receipts".
func LoadReceipts(path string) (*Receipts, error) {
	if path == "" {
		return nil, nil
	}
	data, err := os.ReadFile(path) //nolint:gosec // G304: the path is an operator-supplied flag, not request input
	if err != nil {
		return nil, fmt.Errorf("read receipts: %w", err)
	}
	var r Receipts
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("parse receipts %s: %w", path, err)
	}
	return &r, nil
}
