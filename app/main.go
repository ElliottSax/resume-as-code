// Command resume serves (or exports) a resume as a production-grade web service.
//
//	resume serve        run the HTTP server (default)
//	resume export       write the static site for GitHub Pages
//	resume validate     check content/resume.yaml and exit
//	resume healthcheck  probe a running server (for Docker HEALTHCHECK)
package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/ElliottSax/resume-as-code/app/internal/buildinfo"
	"github.com/ElliottSax/resume-as-code/app/internal/resume"
	"github.com/ElliottSax/resume-as-code/app/internal/server"
	"github.com/ElliottSax/resume-as-code/app/internal/site"
)

//go:embed content/resume.yaml
var embeddedResume []byte

const defaultRepoURL = "https://github.com/ElliottSax/resume-as-code"

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	cmd := "serve"
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd, args = args[0], args[1:]
	}
	switch cmd {
	case "serve":
		return serve(args)
	case "export":
		return export(args)
	case "validate":
		return validate(args)
	case "healthcheck":
		return healthcheck(args)
	case "version":
		return json.NewEncoder(os.Stdout).Encode(buildinfo.Get())
	default:
		return fmt.Errorf("unknown command %q (want serve, export, validate, healthcheck or version)", cmd)
	}
}

// ---- serve ----

func serve(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	addr := fs.String("addr", env("ADDR", ":8080"), "public listen address")
	metricsAddr := fs.String("metrics-addr", env("METRICS_ADDR", ":9090"), "metrics listen address")
	resumePath := fs.String("resume", env("RESUME_FILE", ""), "resume YAML (default: embedded)")
	receiptsPath := fs.String("receipts", env("RECEIPTS_FILE", ""), "receipts JSON from the pipeline (optional)")
	repoURL := fs.String("repo-url", env("REPO_URL", defaultRepoURL), "source repository URL")
	drainDelay := fs.Duration("drain-delay", envDuration("DRAIN_DELAY", 0), "wait after SIGTERM before closing listeners")
	shutdownTimeout := fs.Duration("shutdown-timeout", envDuration("SHUTDOWN_TIMEOUT", 20*time.Second), "max time to finish in-flight requests")
	faultRatio := fs.Float64("fault-error-ratio", envFloat("FAULT_ERROR_RATIO", 0), "fraction of page requests to fail (demo only)")
	faultDelay := fs.Duration("fault-delay", envDuration("FAULT_DELAY", 0), "latency to add to page requests (demo only)")
	logLevel := fs.String("log-level", env("LOG_LEVEL", "info"), "debug, info, warn or error")
	if err := fs.Parse(args); err != nil {
		return err
	}

	logger, err := newLogger(*logLevel)
	if err != nil {
		return err
	}
	slog.SetDefault(logger)

	runtime := site.Runtime{Pod: os.Getenv("POD_NAME"), Node: os.Getenv("NODE_NAME")}
	content, err := buildContent(*resumePath, *receiptsPath, *repoURL, runtime)
	if err != nil {
		return err
	}

	srv := server.New(server.Config{
		Logger:          logger,
		FaultErrorRatio: *faultRatio,
		FaultDelay:      *faultDelay,
	}, content)

	public := newHTTPServer(srv.Handler())
	metrics := newHTTPServer(srv.MetricsHandler())

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Bind both ports before declaring readiness, so "ready" is never a lie.
	var lc net.ListenConfig
	publicLn, err := lc.Listen(ctx, "tcp", *addr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", *addr, err)
	}
	metricsLn, err := lc.Listen(ctx, "tcp", *metricsAddr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", *metricsAddr, err)
	}

	errc := make(chan error, 2)
	go func() { errc <- public.Serve(publicLn) }()
	go func() { errc <- metrics.Serve(metricsLn) }()

	srv.SetReady(true)
	bi := buildinfo.Get()
	logger.Info("serving",
		slog.String("addr", publicLn.Addr().String()),
		slog.String("metrics_addr", metricsLn.Addr().String()),
		slog.String("version", bi.Version),
		slog.String("commit", bi.Commit),
		slog.String("pod", runtime.Pod),
		slog.Bool("fault_injection", *faultRatio > 0 || *faultDelay > 0),
	)

	select {
	case err := <-errc:
		return fmt.Errorf("server stopped unexpectedly: %w", err)
	case <-ctx.Done():
	}

	// Graceful shutdown, in the order Kubernetes needs:
	//  1. fail readiness so no new traffic is routed here;
	//  2. optionally wait while load balancers notice (in Kubernetes the
	//     preStop hook does this wait instead, see deploy/helm);
	//  3. stop accepting connections and let in-flight requests finish.
	logger.Info("shutdown requested; draining")
	srv.SetReady(false)
	time.Sleep(*drainDelay)

	shutdownCtx, cancel := context.WithTimeout(context.Background(), *shutdownTimeout)
	defer cancel()
	err = errors.Join(public.Shutdown(shutdownCtx), metrics.Shutdown(shutdownCtx))
	if err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	logger.Info("shutdown complete")
	return nil
}

func newHTTPServer(h http.Handler) *http.Server {
	return &http.Server{
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second, // closes the slow-loris hole
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
}

// buildContent renders everything once, at startup.
func buildContent(resumePath, receiptsPath, repoURL string, rt site.Runtime) (server.Content, error) {
	r, err := loadResume(resumePath)
	if err != nil {
		return server.Content{}, err
	}
	receipts, err := site.LoadReceipts(receiptsPath)
	if err != nil {
		return server.Content{}, err
	}
	bi := buildinfo.Get()
	page, err := site.Render(site.Page{Resume: r, Build: bi, Receipts: receipts, Runtime: rt, RepoURL: repoURL, Now: time.Now()})
	if err != nil {
		return server.Content{}, err
	}
	resumeJSON, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return server.Content{}, err
	}
	versionJSON, err := json.MarshalIndent(struct {
		buildinfo.Info
		Pod  string `json:"pod,omitempty"`
		Node string `json:"node,omitempty"`
	}{bi, rt.Pod, rt.Node}, "", "  ")
	if err != nil {
		return server.Content{}, err
	}
	return server.Content{Page: page, CSS: site.CSS(), ResumeJSON: resumeJSON, VersionJSON: versionJSON}, nil
}

func loadResume(path string) (*resume.Resume, error) {
	data := embeddedResume
	if path != "" {
		var err error
		if data, err = os.ReadFile(path); err != nil { //nolint:gosec // G304: the path is an operator-supplied flag, not request input
			return nil, fmt.Errorf("read resume: %w", err)
		}
	}
	return resume.Parse(data)
}

// ---- export ----

func export(args []string) error {
	fs := flag.NewFlagSet("export", flag.ContinueOnError)
	out := fs.String("out", "dist", "output directory")
	resumePath := fs.String("resume", "", "resume YAML (default: embedded)")
	receiptsPath := fs.String("receipts", "", "receipts JSON from the pipeline (optional)")
	repoURL := fs.String("repo-url", defaultRepoURL, "source repository URL")
	if err := fs.Parse(args); err != nil {
		return err
	}
	content, err := buildContent(*resumePath, *receiptsPath, *repoURL, site.Runtime{})
	if err != nil {
		return err
	}
	// The export is a public website, so world-readable permissions are intended.
	if err := os.MkdirAll(*out, 0o755); err != nil { //nolint:gosec // G301: see above
		return err
	}
	files := map[string][]byte{
		"index.html":   content.Page,
		"style.css":    content.CSS,
		"resume.json":  content.ResumeJSON,
		"version.json": content.VersionJSON,
		".nojekyll":    nil, // serve files as-is on GitHub Pages
	}
	if *receiptsPath != "" {
		raw, err := os.ReadFile(*receiptsPath) //nolint:gosec // G304: operator-supplied flag
		if err != nil {
			return err
		}
		files["receipts.json"] = raw
	}
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(*out, name), data, 0o644); err != nil { //nolint:gosec // G306: public site
			return err
		}
	}
	fmt.Printf("exported %d files to %s\n", len(files), *out)
	return nil
}

// ---- validate ----

func validate(args []string) error {
	path := ""
	if len(args) > 0 {
		path = args[0]
	}
	r, err := loadResume(path)
	if err != nil {
		return err
	}
	fmt.Printf("ok: %s, %d jobs, %d projects, %d translations\n", r.Name, len(r.Experience), len(r.Projects), len(r.Translation))
	return nil
}

// ---- healthcheck ----

// healthcheck exists because the runtime image is distroless: there is no
// shell, curl or wget to run a HEALTHCHECK with, so the binary checks itself.
func healthcheck(args []string) error {
	fs := flag.NewFlagSet("healthcheck", flag.ContinueOnError)
	url := fs.String("url", "http://127.0.0.1:8080/healthz", "URL to probe")
	wait := fs.Duration("wait", 0, "keep retrying for this long before giving up (0 = one attempt)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	deadline := time.Now().Add(*wait)
	for {
		err := probe(*url)
		if err == nil || !time.Now().Before(deadline) {
			return err
		}
		time.Sleep(500 * time.Millisecond)
	}
}

func probe(url string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req) //nolint:gosec // G107: the URL is an operator-supplied flag
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s returned %s", url, resp.Status)
	}
	return nil
}

// ---- helpers ----

func newLogger(level string) (*slog.Logger, error) {
	var l slog.Level
	if err := l.UnmarshalText([]byte(level)); err != nil {
		return nil, fmt.Errorf("log level: %w", err)
	}
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: l})), nil
}

func env(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
}

func envDuration(key string, fallback time.Duration) time.Duration {
	if d, err := time.ParseDuration(os.Getenv(key)); err == nil {
		return d
	}
	return fallback
}

func envFloat(key string, fallback float64) float64 {
	if f, err := strconv.ParseFloat(os.Getenv(key), 64); err == nil {
		return f
	}
	return fallback
}
