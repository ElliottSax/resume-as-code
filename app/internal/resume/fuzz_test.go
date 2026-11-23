package resume

import (
	"os"
	"testing"
	"time"
)

// FuzzParse throws arbitrary bytes at the strict YAML parser. Whatever the
// input, Parse must either refuse it or return a resume the page can render
// safely: no panic, only https:// and mailto: links, and only dates the page
// can format. `go test` runs the seeds below on every CI run; `make fuzz`
// explores beyond them.
func FuzzParse(f *testing.F) {
	shipped, err := os.ReadFile("../../content/resume.yaml")
	if err != nil {
		f.Fatal(err)
	}
	f.Add(shipped)
	f.Add([]byte(minimal))
	f.Add([]byte("name: [unterminated"))
	f.Add([]byte(minimal + "links:\n  - label: x\n    url: javascript:alert(1)\n"))
	f.Add([]byte("name: &a Ada\nheadline: *a\n"))

	f.Fuzz(func(t *testing.T, data []byte) {
		r, err := Parse(data)
		if err != nil {
			return
		}
		for _, l := range r.Links {
			if !safeURL(l.URL) {
				t.Fatalf("accepted a link the page would render unsafely: %q", l.URL)
			}
		}
		for _, j := range r.Experience {
			for _, d := range []string{j.Start, j.End} {
				if d == Present {
					continue
				}
				if _, err := time.Parse("Jan 2006", FormatMonth(d)); err != nil {
					t.Fatalf("accepted date %q, which the page shows as %q", d, FormatMonth(d))
				}
			}
		}
	})
}
