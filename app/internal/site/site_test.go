package site

import (
	"strings"
	"testing"
	"time"

	"github.com/ElliottSax/resume-as-code/app/internal/buildinfo"
	"github.com/ElliottSax/resume-as-code/app/internal/resume"
)

func sampleResume() *resume.Resume {
	return &resume.Resume{
		Name:     "Ada Lovelace",
		Headline: "Engineer",
		Summary:  "Summary with <script>alert('x')</script> inside.",
		Experience: []resume.Job{
			{Company: "Acme", Title: "Operator", Start: "2020-01", End: resume.Present, Highlights: []string{"Did things"}},
		},
		Translation: []resume.Translation{{Then: "SOPs", Now: "Runbooks", Proof: "docs", ProofURL: "https://example.com/docs"}},
	}
}

func sampleReceipts() *Receipts {
	return &Receipts{
		GeneratedAt: time.Date(2026, 11, 22, 14, 3, 0, 0, time.UTC),
		Repo:        "ElliottSax/resume-as-code",
		Commit:      "0123456789abcdef0123456789abcdef01234567",
		RunURL:      "https://github.com/ElliottSax/resume-as-code/actions/runs/1",
		Image:       Image{Ref: "ghcr.io/elliottsax/resume-as-code", Digest: "sha256:abc", SizeMB: 9.84, Signed: true, SBOMURL: "sbom.spdx.json"},
		Scan:        Scan{Tool: "Trivy", Critical: 0, High: 0, Medium: 1},
		Tests:       Tests{Passed: 31, CoveragePct: 84.26},
		Drill: &Drill{
			Kubernetes: "v1.37.0", Nodes: 3, DeploySeconds: 21, DurationSeconds: 180,
			Requests: 18000, Failed: 0, SuccessPct: 100, P95Ms: 4.2, P99Ms: 9.7,
			PodsKilled: 6, Rollouts: 1, NodeDrains: 1,
			PodSecurityRejected: true, NetworkPolicyBlocked: true,
			SLO: SLO{AvailabilityPct: 99.9, LatencyPct: 99, LatencyMs: 250, Met: true},
		},
	}
}

func render(t *testing.T, p Page) string {
	t.Helper()
	out, err := Render(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

func TestRenderWithReceipts(t *testing.T) {
	html := render(t, Page{Resume: sampleResume(), Build: buildinfo.Get(), Receipts: sampleReceipts(), RepoURL: "https://github.com/x/y"})
	for _, want := range []string{
		"This page has receipts",
		"<code>0123456</code>",
		"18,000 requests",
		"3 min",
		"killing 6 pods",
		"draining 1 node ",
		"100.000% of requests succeeded",
		"<strong>met</strong>",
		"9.8 MB compressed, distroless",
		"cosign verify ghcr.io/elliottsax/resume-as-code@sha256:abc",
		"gh attestation verify",
		`href="https://example.com/docs"`,
	} {
		if !strings.Contains(html, want) {
			t.Errorf("rendered page missing %q", want)
		}
	}
}

func TestRenderEscapesContent(t *testing.T) {
	html := render(t, Page{Resume: sampleResume(), Build: buildinfo.Get()})
	if strings.Contains(html, "<script>") {
		t.Fatal("resume text was rendered as raw HTML")
	}
	if !strings.Contains(html, "&lt;script&gt;") {
		t.Fatal("expected escaped script tag")
	}
}

func TestRenderLiveModeShowsPod(t *testing.T) {
	html := render(t, Page{Resume: sampleResume(), Build: buildinfo.Get(), Runtime: Runtime{Pod: "resume-abc", Node: "worker-2"}})
	if !strings.Contains(html, "resume-abc") || !strings.Contains(html, "worker-2") {
		t.Fatal("live mode should name the serving pod and node")
	}
	if strings.Contains(html, "This page has receipts") {
		t.Fatal("receipts panel must not render without receipts")
	}
}

func TestRenderMissedSLOIsVisible(t *testing.T) {
	rc := sampleReceipts()
	rc.Drill.SLO.Met = false
	html := render(t, Page{Resume: sampleResume(), Build: buildinfo.Get(), Receipts: rc})
	if !strings.Contains(html, "<strong>missed</strong>") || !strings.Contains(html, `dot fail`) {
		t.Fatal("a missed SLO must be shown, not hidden")
	}
}

func TestLoadReceipts(t *testing.T) {
	if r, err := LoadReceipts(""); r != nil || err != nil {
		t.Fatalf("empty path should mean no receipts, got %v %v", r, err)
	}
	if _, err := LoadReceipts("testdata/does-not-exist.json"); err == nil {
		t.Fatal("expected error for missing file")
	}
	r, err := LoadReceipts("testdata/receipts.json")
	if err != nil {
		t.Fatal(err)
	}
	if r.Drill == nil || !r.Drill.SLO.Met {
		t.Fatalf("unexpected receipts: %+v", r)
	}
}

func TestHelpers(t *testing.T) {
	if got := thousands(1234567); got != "1,234,567" {
		t.Errorf("thousands = %q", got)
	}
	if got := thousands(-1000); got != "-1,000" {
		t.Errorf("thousands negative = %q", got)
	}
	if got := thousands(999); got != "999" {
		t.Errorf("thousands small = %q", got)
	}
	cases := map[float64]string{42: "42 s", 60: "1 min", 183.4: "3 min 3 s"}
	for in, want := range cases {
		if got := humanDuration(in); got != want {
			t.Errorf("humanDuration(%v) = %q, want %q", in, got, want)
		}
	}
	if plural(1, "pod", "pods") != "pod" || plural(2, "pod", "pods") != "pods" {
		t.Error("plural")
	}
}
