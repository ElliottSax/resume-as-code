//go:build unix

package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"syscall"
	"testing"
	"time"
)

func freeAddr(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().String()
}

// TestServeShutsDownGracefully runs the real server, waits until it reports
// ready, sends it SIGTERM exactly as the kubelet would, and checks that it
// exits cleanly. The chaos drill depends on this path behaving.
func TestServeShutsDownGracefully(t *testing.T) {
	addr, metricsAddr := freeAddr(t), freeAddr(t)
	t.Setenv("POD_NAME", "test-pod")

	done := make(chan error, 1)
	go func() {
		done <- serve([]string{"-addr", addr, "-metrics-addr", metricsAddr, "-log-level", "error", "-shutdown-timeout", "5s"})
	}()

	client := http.Client{Timeout: time.Second}
	waitFor(t, func() bool {
		resp, err := client.Get("http://" + addr + "/readyz")
		if err != nil {
			return false
		}
		resp.Body.Close()
		return resp.StatusCode == http.StatusOK
	})

	page := get(t, client, "http://"+addr+"/")
	if !strings.Contains(page, "test-pod") {
		t.Error("live page should name the serving pod")
	}
	if metrics := get(t, client, "http://"+metricsAddr+"/metrics"); !strings.Contains(metrics, "resume_ready 1") {
		t.Error("metrics port should report ready")
	}
	if err := healthcheck([]string{"-url", "http://" + addr + "/healthz"}); err != nil {
		t.Errorf("healthcheck subcommand: %v", err)
	}

	if err := syscall.Kill(syscall.Getpid(), syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("serve returned %v, want clean shutdown", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("server did not shut down within 10s of SIGTERM")
	}
	if err := healthcheck([]string{"-url", "http://" + addr + "/healthz"}); err == nil {
		t.Error("server still answering after shutdown")
	}
}

func waitFor(t *testing.T, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("condition not met within 5s")
}

func get(t *testing.T, c http.Client, url string) string {
	t.Helper()
	resp, err := c.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatal(fmt.Errorf("GET %s: %s", url, resp.Status))
	}
	return string(b)
}
