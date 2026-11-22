package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func TestEmbeddedResumeValidates(t *testing.T) {
	if err := validate(nil); err != nil {
		t.Fatal(err)
	}
}

func TestExportWritesStaticSite(t *testing.T) {
	out := t.TempDir()
	err := export([]string{"-out", out, "-receipts", "internal/site/testdata/receipts.json"})
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"index.html", "style.css", "resume.json", "version.json", "receipts.json", ".nojekyll"} {
		if _, err := os.Stat(filepath.Join(out, f)); err != nil {
			t.Errorf("missing %s: %v", f, err)
		}
	}
	page, err := os.ReadFile(filepath.Join(out, "index.html"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(page), "This page has receipts") {
		t.Error("exported page has no receipts panel")
	}
	if !strings.Contains(string(page), `href="style.css"`) {
		t.Error("stylesheet must be linked relatively so GitHub Pages subpaths work")
	}
}

func TestHealthcheckRetriesUntilHealthy(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if calls.Add(1) < 3 {
			w.WriteHeader(http.StatusServiceUnavailable)
		}
	}))
	defer srv.Close()

	if err := healthcheck([]string{"-url", srv.URL, "-wait", "5s"}); err != nil {
		t.Fatalf("with -wait, healthcheck should ride out two failures: %v", err)
	}
	if got := calls.Load(); got != 3 {
		t.Errorf("calls = %d, want 3", got)
	}

	calls.Store(0)
	if err := healthcheck([]string{"-url", srv.URL}); err == nil {
		t.Fatal("without -wait, the first 503 must be final")
	}
}

func TestUnknownCommand(t *testing.T) {
	if err := run([]string{"frobnicate"}); err == nil {
		t.Fatal("expected error for unknown command")
	}
}

func TestEnvHelpers(t *testing.T) {
	t.Setenv("X_DUR", "1500ms")
	t.Setenv("X_FLOAT", "0.25")
	t.Setenv("X_BAD", "nope")
	if d := envDuration("X_DUR", 0); d.Milliseconds() != 1500 {
		t.Errorf("envDuration = %v", d)
	}
	if d := envDuration("X_BAD", 7); d != 7 {
		t.Errorf("envDuration fallback = %v", d)
	}
	if f := envFloat("X_FLOAT", 0); f != 0.25 {
		t.Errorf("envFloat = %v", f)
	}
	if v := env("X_UNSET_SURELY", "fb"); v != "fb" {
		t.Errorf("env fallback = %q", v)
	}
}
