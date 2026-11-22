package resume

import (
	"os"
	"strings"
	"testing"
)

func TestShippedContentIsValid(t *testing.T) {
	data, err := os.ReadFile("../../content/resume.yaml")
	if err != nil {
		t.Fatal(err)
	}
	r, err := Parse(data)
	if err != nil {
		t.Fatalf("content/resume.yaml is invalid:\n%v", err)
	}
	if len(r.Experience) == 0 || len(r.Translation) == 0 {
		t.Fatal("expected experience and translation entries")
	}
}

const minimal = `
name: Ada
headline: Engineer
experience:
  - company: Acme
    title: Operator
    start: "2020-01"
    end: present
`

func TestParseMinimal(t *testing.T) {
	r, err := Parse([]byte(minimal))
	if err != nil {
		t.Fatal(err)
	}
	if r.Name != "Ada" || r.Experience[0].End != Present {
		t.Fatalf("unexpected parse result: %+v", r)
	}
}

func TestParseRejectsUnknownKeys(t *testing.T) {
	// A typo like "headlien" should fail loudly instead of silently vanishing.
	_, err := Parse([]byte(minimal + "headlien: oops\n"))
	if err == nil || !strings.Contains(err.Error(), "headlien") {
		t.Fatalf("want unknown-field error mentioning headlien, got %v", err)
	}
}

func TestValidateReportsEveryProblem(t *testing.T) {
	r := &Resume{
		Links: []Link{{Label: "x", URL: "javascript:alert(1)"}},
		Experience: []Job{
			{Company: "A", Title: "T", Start: "2020-05", End: "2019-01"},
			{Company: "B", Title: "T", Start: "May 2020", End: Present},
			{Company: "C", Title: "T", Start: "2020-01", End: "soon"},
		},
	}
	err := r.Validate()
	if err == nil {
		t.Fatal("expected errors")
	}
	for _, want := range []string{
		"name is required",
		"headline is required",
		"url must start with https:// or mailto:",
		"end 2019-01 is before start 2020-05",
		`start "May 2020" must be YYYY-MM`,
		`end "soon" must be YYYY-MM`,
	} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("missing %q in:\n%v", want, err)
		}
	}
}

func TestValidateRequiresExperience(t *testing.T) {
	r := &Resume{Name: "A", Headline: "B"}
	if err := r.Validate(); err == nil || !strings.Contains(err.Error(), "experience") {
		t.Fatalf("want experience error, got %v", err)
	}
}

func TestValidateRejectsEmptyHighlight(t *testing.T) {
	r, err := Parse([]byte(minimal))
	if err != nil {
		t.Fatal(err)
	}
	r.Experience[0].Highlights = []string{"real", "  "}
	if err := r.Validate(); err == nil || !strings.Contains(err.Error(), "empty") {
		t.Fatalf("want empty-highlight error, got %v", err)
	}
}

func TestFormatMonth(t *testing.T) {
	cases := map[string]string{
		"2018-08": "Aug 2018",
		"present": "Present",
		"garbage": "garbage",
	}
	for in, want := range cases {
		if got := FormatMonth(in); got != want {
			t.Errorf("FormatMonth(%q) = %q, want %q", in, got, want)
		}
	}
}
