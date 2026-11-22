package server

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

func newTestServer(cfg Config) *Server {
	cfg.Logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	return New(cfg, Content{
		Page:        []byte("<!doctype html><title>resume</title>"),
		CSS:         []byte("body{}"),
		ResumeJSON:  []byte(`{"name":"Ada"}`),
		VersionJSON: []byte(`{"commit":"abc"}`),
	})
}

func do(h http.Handler, method, target string, headers ...string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, target, nil)
	for i := 0; i+1 < len(headers); i += 2 {
		req.Header.Set(headers[i], headers[i+1])
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestRoutes(t *testing.T) {
	s := newTestServer(Config{})
	s.SetReady(true)
	h := s.Handler()

	cases := []struct {
		method, path string
		code         int
		contentType  string
	}{
		{"GET", "/", 200, "text/html; charset=utf-8"},
		{"HEAD", "/", 200, "text/html; charset=utf-8"},
		{"GET", "/style.css", 200, "text/css; charset=utf-8"},
		{"GET", "/resume.json", 200, "application/json"},
		{"GET", "/version", 200, "application/json"},
		{"GET", "/healthz", 200, "text/plain; charset=utf-8"},
		{"GET", "/readyz", 200, "text/plain; charset=utf-8"},
		{"GET", "/does-not-exist", 404, ""},
		{"POST", "/", 405, ""},
	}
	for _, c := range cases {
		rec := do(h, c.method, c.path)
		if rec.Code != c.code {
			t.Errorf("%s %s: code %d, want %d", c.method, c.path, rec.Code, c.code)
		}
		if c.contentType != "" && rec.Header().Get("Content-Type") != c.contentType {
			t.Errorf("%s %s: content-type %q, want %q", c.method, c.path, rec.Header().Get("Content-Type"), c.contentType)
		}
	}
}

func TestReadinessFollowsState(t *testing.T) {
	s := newTestServer(Config{})
	h := s.Handler()

	if rec := do(h, "GET", "/readyz"); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("before SetReady: %d, want 503", rec.Code)
	}
	s.SetReady(true)
	if rec := do(h, "GET", "/readyz"); rec.Code != http.StatusOK {
		t.Fatalf("after SetReady(true): %d, want 200", rec.Code)
	}
	// Draining: readiness fails but liveness must keep passing, or Kubernetes
	// would kill the pod mid-drain and drop in-flight requests.
	s.SetReady(false)
	if rec := do(h, "GET", "/readyz"); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("draining readyz: %d, want 503", rec.Code)
	}
	if rec := do(h, "GET", "/healthz"); rec.Code != http.StatusOK {
		t.Fatalf("draining healthz: %d, want 200", rec.Code)
	}
}

func TestSecurityHeaders(t *testing.T) {
	h := newTestServer(Config{}).Handler()
	rec := do(h, "GET", "/")
	want := map[string]string{
		"X-Content-Type-Options": "nosniff",
		"X-Frame-Options":        "DENY",
		"Referrer-Policy":        "strict-origin-when-cross-origin",
	}
	for k, v := range want {
		if got := rec.Header().Get(k); got != v {
			t.Errorf("%s = %q, want %q", k, got, v)
		}
	}
	if csp := rec.Header().Get("Content-Security-Policy"); !strings.Contains(csp, "default-src 'none'") {
		t.Errorf("CSP too weak: %q", csp)
	}
	// Headers apply to error responses too.
	if rec := do(h, "GET", "/nope"); rec.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Error("security headers missing on 404")
	}
}

func TestETagRevalidation(t *testing.T) {
	h := newTestServer(Config{}).Handler()
	first := do(h, "GET", "/")
	etag := first.Header().Get("ETag")
	if etag == "" {
		t.Fatal("no ETag on page")
	}
	second := do(h, "GET", "/", "If-None-Match", etag)
	if second.Code != http.StatusNotModified || second.Body.Len() != 0 {
		t.Fatalf("revalidation: code %d, %d bytes; want 304 with empty body", second.Code, second.Body.Len())
	}
}

func TestRequestID(t *testing.T) {
	h := newTestServer(Config{}).Handler()

	if got := do(h, "GET", "/", "X-Request-ID", "abc-123").Header().Get("X-Request-ID"); got != "abc-123" {
		t.Errorf("valid incoming ID not echoed: %q", got)
	}
	// An ID carrying newlines or markup could forge log lines, so it is replaced.
	got := do(h, "GET", "/", "X-Request-ID", "evil\"}\n{\"admin\":true").Header().Get("X-Request-ID")
	if got == "" || strings.ContainsAny(got, "\"{}\n") {
		t.Errorf("unsafe ID not replaced: %q", got)
	}
	if got := do(h, "GET", "/").Header().Get("X-Request-ID"); len(got) != 16 {
		t.Errorf("generated ID %q, want 16 hex chars", got)
	}
}

func TestMetricsUseBoundedRouteLabels(t *testing.T) {
	s := newTestServer(Config{})
	h := s.Handler()
	for _, p := range []string{"/a", "/b", "/wp-admin", "/random/deep/path?x=1", "/"} {
		do(h, "GET", p)
	}
	if got := testutil.ToFloat64(s.m.requests.WithLabelValues("unmatched", "GET", "404")); got != 4 {
		t.Errorf("unmatched 404s = %v, want 4", got)
	}
	if got := testutil.ToFloat64(s.m.requests.WithLabelValues("index", "GET", "200")); got != 1 {
		t.Errorf("index 200s = %v, want 1", got)
	}
	// Four random paths must not have created four series.
	if n := testutil.CollectAndCount(s.m.requests); n != 2 {
		t.Errorf("request series = %d, want 2 (index, unmatched)", n)
	}
}

func TestMetricsEndpoint(t *testing.T) {
	s := newTestServer(Config{})
	s.SetReady(true)
	do(s.Handler(), "GET", "/")
	body := do(s.MetricsHandler(), "GET", "/metrics").Body.String()
	for _, want := range []string{
		`http_requests_total{code="200",method="GET",route="index"} 1`,
		"http_request_duration_seconds_bucket",
		`le="0.25"`,
		"resume_ready 1",
		"resume_build_info{",
		"go_goroutines",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("metrics output missing %q", want)
		}
	}
}

func TestFaultInjection(t *testing.T) {
	s := newTestServer(Config{FaultErrorRatio: 0.5})
	h := s.Handler()

	s.chance = func() float64 { return 0.1 } // below the ratio: inject
	if rec := do(h, "GET", "/"); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected injected 503, got %d", rec.Code)
	}
	s.chance = func() float64 { return 0.9 } // above the ratio: serve
	if rec := do(h, "GET", "/"); rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	// Probes are never faulted, or the demo would restart pods instead of
	// burning error budget.
	s.chance = func() float64 { return 0 }
	if rec := do(h, "GET", "/healthz"); rec.Code != http.StatusOK {
		t.Fatalf("healthz faulted: %d", rec.Code)
	}
}

func TestPanicIsRecovered(t *testing.T) {
	s := newTestServer(Config{})
	h := s.instrument(s.recoverer(named("boom", http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic("boom")
	}))))
	rec := do(h, "GET", "/boom")
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("code %d, want 500", rec.Code)
	}
	if got := testutil.ToFloat64(s.m.panics); got != 1 {
		t.Errorf("panics counter = %v, want 1", got)
	}
	if got := testutil.ToFloat64(s.m.requests.WithLabelValues("boom", "GET", "500")); got != 1 {
		t.Errorf("500 not recorded against route: %v", got)
	}
}
