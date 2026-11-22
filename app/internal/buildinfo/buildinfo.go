// Package buildinfo holds facts stamped into the binary at build time.
//
// The Dockerfile sets these with -ldflags "-X ...". Exposing them on /version
// and as a Prometheus metric means anyone can ask a running pod exactly which
// commit it is serving, instead of trusting that the pipeline went green.
package buildinfo

import "runtime"

var (
	// Version is a human-readable release name (git describe output in CI).
	Version = "dev"
	// Commit is the full git SHA the binary was built from.
	Commit = "unknown"
	// Date is the build time in RFC 3339, UTC.
	Date = "unknown"
)

// Info is the JSON shape served on /version.
type Info struct {
	Version   string `json:"version"`
	Commit    string `json:"commit"`
	BuildDate string `json:"build_date"`
	GoVersion string `json:"go_version"`
}

// Get returns the stamped build facts plus the Go toolchain version.
func Get() Info {
	return Info{Version: Version, Commit: Commit, BuildDate: Date, GoVersion: runtime.Version()}
}

// ShortCommit returns the first 7 characters of the commit, git-style.
func ShortCommit() string {
	if len(Commit) > 7 {
		return Commit[:7]
	}
	return Commit
}
