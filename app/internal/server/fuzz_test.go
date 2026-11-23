package server

import (
	"strings"
	"testing"
)

// FuzzRequestID: clients control the X-Request-ID header, and the ID lands in
// every access-log line and in the response. Whatever arrives, the server must
// answer with an ID matching the safe pattern, so nobody can forge log lines
// or inject headers through it. A safe ID must pass through unchanged, so one
// request can be traced across services.
func FuzzRequestID(f *testing.F) {
	for _, seed := range []string{
		"", "abc-123", "a.b_c", "has space", "line\nbreak",
		"x\r\nSet-Cookie: a=b", strings.Repeat("a", 64), strings.Repeat("a", 65), "ünïcode",
	} {
		f.Add(seed)
	}
	h := newTestServer(Config{}).Handler()

	f.Fuzz(func(t *testing.T, id string) {
		got := do(h, "GET", "/healthz", "X-Request-ID", id).Header().Get("X-Request-ID")
		if !validRequestID.MatchString(got) {
			t.Fatalf("X-Request-ID %q came back as unsafe %q", id, got)
		}
		if validRequestID.MatchString(id) && got != id {
			t.Fatalf("safe X-Request-ID %q was replaced with %q", id, got)
		}
	})
}
