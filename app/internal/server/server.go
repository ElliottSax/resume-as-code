// Package server is the HTTP layer: routes, middleware, metrics and readiness.
package server

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log/slog"
	mathrand "math/rand/v2"
	"net/http"
	"regexp"
	"runtime/debug"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/ElliottSax/resume-as-code/app/internal/buildinfo"
)

// Content is the pre-rendered output the server hands out. Rendering happens
// once at startup, so a request costs a map lookup and a memory copy.
type Content struct {
	Page        []byte
	CSS         []byte
	ResumeJSON  []byte
	VersionJSON []byte
}

// Config tunes behaviour that differs between environments.
type Config struct {
	Logger *slog.Logger

	// FaultErrorRatio makes this fraction of page requests fail with 503, and
	// FaultDelay adds latency to them. Both default to zero. They exist so the
	// burn-rate alerts can be demonstrated firing on demand (see
	// docs/runbooks/high-error-rate.md), never for production use.
	FaultErrorRatio float64
	FaultDelay      time.Duration
}

// Server serves the resume and exposes its own health.
type Server struct {
	cfg      Config
	content  Content
	etag     string
	ready    atomic.Bool
	registry *prometheus.Registry
	m        *metrics
	chance   func() float64
}

// New builds a Server. It starts not-ready; call SetReady once listening.
func New(cfg Config, content Content) *Server {
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	sum := sha256.Sum256(content.Page)
	s := &Server{
		cfg:      cfg,
		content:  content,
		etag:     `"` + hex.EncodeToString(sum[:8]) + `"`,
		registry: prometheus.NewRegistry(),
		chance:   mathrand.Float64,
	}
	s.m = newMetrics(s.registry, &s.ready)
	return s
}

// SetReady flips the readiness probe. Kubernetes stops routing traffic to a
// pod whose readiness fails, so this is how a pod asks to be taken out of
// rotation before it shuts down.
func (s *Server) SetReady(ready bool) { s.ready.Store(ready) }

// Handler returns the public routes wrapped in middleware.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /{$}", named("index", http.HandlerFunc(s.index)))
	mux.Handle("GET /style.css", named("style", static("text/css; charset=utf-8", s.content.CSS)))
	mux.Handle("GET /resume.json", named("resume_json", static("application/json", s.content.ResumeJSON)))
	mux.Handle("GET /version", named("version", static("application/json", s.content.VersionJSON)))
	mux.Handle("GET /healthz", named("healthz", http.HandlerFunc(healthz)))
	mux.Handle("GET /readyz", named("readyz", http.HandlerFunc(s.readyz)))
	return securityHeaders(s.instrument(s.recoverer(mux)))
}

// MetricsHandler serves Prometheus metrics. It listens on its own port so a
// NetworkPolicy can let the monitoring namespace in and keep everyone else out.
func (s *Server) MetricsHandler() http.Handler {
	return promhttp.HandlerFor(s.registry, promhttp.HandlerOpts{Registry: s.registry})
}

// ---- handlers ----

func (s *Server) index(w http.ResponseWriter, r *http.Request) {
	if s.cfg.FaultDelay > 0 {
		select {
		case <-time.After(s.cfg.FaultDelay):
		case <-r.Context().Done():
			return
		}
	}
	if s.cfg.FaultErrorRatio > 0 && s.chance() < s.cfg.FaultErrorRatio {
		http.Error(w, "injected fault", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("ETag", s.etag)
	w.Header().Set("Cache-Control", "no-cache")
	if r.Header.Get("If-None-Match") == s.etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(s.content.Page)
}

func healthz(w http.ResponseWriter, _ *http.Request) {
	// Liveness only answers "is the process able to serve at all". It must not
	// check dependencies, or a downstream blip would make Kubernetes restart
	// every healthy pod at once.
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte("ok\n"))
}

func (s *Server) readyz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	if !s.ready.Load() {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte("not ready\n"))
		return
	}
	_, _ = w.Write([]byte("ready\n"))
}

func static(contentType string, body []byte) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", contentType)
		_, _ = w.Write(body)
	})
}

// ---- middleware ----

type ctxKey struct{}

// reqInfo travels down the chain in the request context so inner handlers can
// report facts (like the route name) back up to the instrumentation layer.
type reqInfo struct {
	route string
	id    string
}

// named records a fixed route name for metrics. Labelling by the raw URL path
// would let anyone create unlimited time series by requesting random paths,
// a classic way to knock over Prometheus. Route names keep cardinality fixed.
func named(route string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if info, ok := r.Context().Value(ctxKey{}).(*reqInfo); ok {
			info.route = route
		}
		next.ServeHTTP(w, r)
	})
}

var validRequestID = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)

// instrument assigns a request ID, records RED metrics (rate, errors,
// duration) and writes one structured access-log line per request.
func (s *Server) instrument(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		info := &reqInfo{route: "unmatched", id: r.Header.Get("X-Request-ID")}
		if !validRequestID.MatchString(info.id) {
			info.id = newRequestID()
		}
		w.Header().Set("X-Request-ID", info.id)
		rec := &recorder{ResponseWriter: w, status: http.StatusOK}

		s.m.inflight.Inc()
		defer s.m.inflight.Dec()

		next.ServeHTTP(rec, r.WithContext(context.WithValue(r.Context(), ctxKey{}, info)))

		elapsed := time.Since(start)
		code := fmt.Sprint(rec.status)
		s.m.requests.WithLabelValues(info.route, r.Method, code).Inc()
		s.m.duration.WithLabelValues(info.route, r.Method).Observe(elapsed.Seconds())

		level := slog.LevelInfo
		if info.route == "healthz" || info.route == "readyz" {
			level = slog.LevelDebug // probes fire every few seconds; keep them out of the default log
		}
		s.cfg.Logger.LogAttrs(r.Context(), level, "request",
			slog.String("request_id", info.id),
			slog.String("method", r.Method),
			slog.String("path", r.URL.Path),
			slog.String("route", info.route),
			slog.Int("status", rec.status),
			slog.Int("bytes", rec.bytes),
			slog.Float64("duration_ms", float64(elapsed.Microseconds())/1000),
		)
	})
}

// recoverer turns a panic into a 500 and a log line instead of a dead process.
func (s *Server) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			v := recover()
			if v == nil {
				return
			}
			if v == http.ErrAbortHandler { //nolint:errorlint // sentinel compared by identity, as net/http does
				panic(v)
			}
			s.m.panics.Inc()
			s.cfg.Logger.Error("panic", slog.Any("panic", v), slog.String("stack", string(debug.Stack())))
			http.Error(w, "internal server error", http.StatusInternalServerError)
		}()
		next.ServeHTTP(w, r)
	})
}

// csp mirrors the <meta> tag in the page: no scripts, no frames, no plugins.
const csp = "default-src 'none'; style-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", csp)
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "strict-origin-when-cross-origin")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		h.Set("Strict-Transport-Security", "max-age=63072000; includeSubDomains")
		next.ServeHTTP(w, r)
	})
}

func newRequestID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b) // crypto/rand.Read never returns an error on supported platforms
	return hex.EncodeToString(b)
}

// recorder captures the status code and size for metrics and logs.
type recorder struct {
	http.ResponseWriter
	status      int
	bytes       int
	wroteHeader bool
}

func (r *recorder) WriteHeader(code int) {
	if !r.wroteHeader {
		r.status, r.wroteHeader = code, true
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *recorder) Write(b []byte) (int, error) {
	r.wroteHeader = true
	n, err := r.ResponseWriter.Write(b)
	r.bytes += n
	return n, err
}

// Unwrap lets http.ResponseController reach the underlying writer.
func (r *recorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

// ---- metrics ----

type metrics struct {
	requests *prometheus.CounterVec
	duration *prometheus.HistogramVec
	inflight prometheus.Gauge
	panics   prometheus.Counter
}

func newMetrics(reg *prometheus.Registry, ready *atomic.Bool) *metrics {
	m := &metrics{
		requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "HTTP requests by route, method and status code.",
		}, []string{"route", "method", "code"}),
		// The default buckets include 0.25 s, which is exactly the latency SLO
		// threshold, so "fraction of requests under 250 ms" is an exact query.
		duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request latency by route and method.",
			Buckets: prometheus.DefBuckets,
		}, []string{"route", "method"}),
		inflight: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "http_requests_in_flight",
			Help: "Requests currently being served.",
		}),
		panics: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "http_handler_panics_total",
			Help: "Handler panics recovered by middleware.",
		}),
	}
	bi := buildinfo.Get()
	reg.MustRegister(
		m.requests, m.duration, m.inflight, m.panics,
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
		prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Name: "resume_ready",
			Help: "1 when this instance is accepting traffic, 0 while starting or draining.",
		}, func() float64 {
			if ready.Load() {
				return 1
			}
			return 0
		}),
		prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Name:        "resume_build_info",
			Help:        "Build metadata; always 1. Join on it to see which commit is serving.",
			ConstLabels: prometheus.Labels{"version": bi.Version, "commit": bi.Commit, "go_version": bi.GoVersion},
		}, func() float64 { return 1 }),
	)
	return m
}
