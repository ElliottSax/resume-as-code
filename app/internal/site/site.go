// Package site renders the resume as a single static HTML page.
//
// The same renderer feeds two outputs: the live container (rendered once at
// startup, then served from memory) and the static export published to
// GitHub Pages. html/template escapes every value, so resume text can never
// inject markup.
package site

import (
	"bytes"
	"embed"
	"fmt"
	"html/template"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/ElliottSax/resume-as-code/app/internal/buildinfo"
	"github.com/ElliottSax/resume-as-code/app/internal/resume"
)

//go:embed templates/index.html.tmpl
var templateFS embed.FS

//go:embed templates/style.css
var css []byte

// CSS returns the stylesheet served at /style.css.
func CSS() []byte { return css }

// Runtime identifies the pod that rendered the page (Kubernetes Downward API).
type Runtime struct {
	Pod  string
	Node string
}

// Page is everything the template needs.
type Page struct {
	Resume   *resume.Resume
	Build    buildinfo.Info
	Receipts *Receipts
	Runtime  Runtime
	RepoURL  string
	Now      time.Time
}

var tmpl = template.Must(template.New("index.html.tmpl").Funcs(template.FuncMap{
	"month":    resume.FormatMonth,
	"short":    shortSHA,
	"thousand": thousands,
	"fixed":    fixed,
	"duration": humanDuration,
	"utc":      func(t time.Time) string { return t.UTC().Format("2 Jan 2006, 15:04 UTC") },
	"plural":   plural,
}).ParseFS(templateFS, "templates/index.html.tmpl"))

// Render produces the complete HTML document.
func Render(p Page) ([]byte, error) {
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, p); err != nil {
		return nil, fmt.Errorf("render page: %w", err)
	}
	return buf.Bytes(), nil
}

func shortSHA(s string) string {
	if len(s) > 7 {
		return s[:7]
	}
	return s
}

// thousands formats 18000 as "18,000".
func thousands(n int) string {
	s := strconv.Itoa(n)
	neg := strings.HasPrefix(s, "-")
	s = strings.TrimPrefix(s, "-")
	var b strings.Builder
	for i, r := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(r)
	}
	if neg {
		return "-" + b.String()
	}
	return b.String()
}

// fixed formats a float with the given number of decimals.
func fixed(decimals int, f float64) string {
	return strconv.FormatFloat(f, 'f', decimals, 64)
}

// humanDuration turns 183.4 seconds into "3 min 3 s".
func humanDuration(seconds float64) string {
	total := int(math.Round(seconds))
	if total < 60 {
		return fmt.Sprintf("%d s", total)
	}
	m, s := total/60, total%60
	if s == 0 {
		return fmt.Sprintf("%d min", m)
	}
	return fmt.Sprintf("%d min %d s", m, s)
}

// plural picks the singular or plural noun for n.
func plural(n int, one, many string) string {
	if n == 1 {
		return one
	}
	return many
}
