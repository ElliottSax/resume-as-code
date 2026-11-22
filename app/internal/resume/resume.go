// Package resume loads and validates the resume content in content/resume.yaml.
//
// The resume is treated like any other configuration a service depends on:
// it has a schema, unknown keys are rejected, and CI fails on bad data before
// it can ever reach a user.
package resume

import (
	"bytes"
	"errors"
	"fmt"
	"strings"
	"time"

	"go.yaml.in/yaml/v3"
)

// Resume is the whole document.
type Resume struct {
	Name        string        `yaml:"name" json:"name"`
	Headline    string        `yaml:"headline" json:"headline"`
	Location    string        `yaml:"location" json:"location"`
	Summary     string        `yaml:"summary" json:"summary"`
	Links       []Link        `yaml:"links" json:"links"`
	Translation []Translation `yaml:"translation" json:"translation"`
	Projects    []Project     `yaml:"projects" json:"projects"`
	Experience  []Job         `yaml:"experience" json:"experience"`
	Skills      []SkillGroup  `yaml:"skills" json:"skills"`
	Education   []School      `yaml:"education" json:"education"`
}

// Link is a contact or profile link.
type Link struct {
	Label string `yaml:"label" json:"label"`
	URL   string `yaml:"url" json:"url"`
}

// Translation maps one piece of operations experience to the DevOps practice
// it corresponds to, and to the place in this repository that proves it.
type Translation struct {
	Then     string `yaml:"then" json:"then"`
	Now      string `yaml:"now" json:"now"`
	Proof    string `yaml:"proof" json:"proof"`
	ProofURL string `yaml:"proof_url" json:"proof_url"`
}

// Project is a portfolio project.
type Project struct {
	Name       string   `yaml:"name" json:"name"`
	URL        string   `yaml:"url" json:"url,omitempty"`
	Summary    string   `yaml:"summary" json:"summary"`
	Highlights []string `yaml:"highlights" json:"highlights"`
	Stack      []string `yaml:"stack" json:"stack"`
}

// Job is one position. Start and End are "YYYY-MM"; End may be "present".
type Job struct {
	Company    string   `yaml:"company" json:"company"`
	Location   string   `yaml:"location" json:"location"`
	Title      string   `yaml:"title" json:"title"`
	Start      string   `yaml:"start" json:"start"`
	End        string   `yaml:"end" json:"end"`
	Highlights []string `yaml:"highlights" json:"highlights"`
}

// SkillGroup is a labelled list of skills.
type SkillGroup struct {
	Name  string   `yaml:"name" json:"name"`
	Items []string `yaml:"items" json:"items"`
}

// School is a degree or certificate.
type School struct {
	Institution string   `yaml:"institution" json:"institution"`
	Location    string   `yaml:"location" json:"location"`
	Credential  string   `yaml:"credential" json:"credential"`
	Date        string   `yaml:"date" json:"date"`
	Notes       []string `yaml:"notes" json:"notes,omitempty"`
}

const monthLayout = "2006-01"

// Present is the End value for a current position.
const Present = "present"

// Parse decodes YAML strictly (unknown keys are errors) and validates it.
func Parse(data []byte) (*Resume, error) {
	dec := yaml.NewDecoder(bytes.NewReader(data))
	dec.KnownFields(true)
	var r Resume
	if err := dec.Decode(&r); err != nil {
		return nil, fmt.Errorf("decode resume: %w", err)
	}
	if err := r.Validate(); err != nil {
		return nil, err
	}
	return &r, nil
}

// Validate reports every problem at once, so one CI run shows all of them.
func (r *Resume) Validate() error {
	var errs []error
	add := func(format string, a ...any) { errs = append(errs, fmt.Errorf(format, a...)) }

	if strings.TrimSpace(r.Name) == "" {
		add("name is required")
	}
	if strings.TrimSpace(r.Headline) == "" {
		add("headline is required")
	}
	if len(r.Experience) == 0 {
		add("at least one experience entry is required")
	}
	for i, l := range r.Links {
		if l.Label == "" {
			add("links[%d]: label is required", i)
		}
		if !safeURL(l.URL) {
			add("links[%d] (%s): url must start with https:// or mailto:", i, l.Label)
		}
	}
	for i, t := range r.Translation {
		if t.Then == "" || t.Now == "" || t.Proof == "" {
			add("translation[%d]: then, now and proof are all required", i)
		}
		if t.ProofURL != "" && !safeURL(t.ProofURL) {
			add("translation[%d]: proof_url must start with https://", i)
		}
	}
	for i, p := range r.Projects {
		if p.Name == "" || p.Summary == "" {
			add("projects[%d]: name and summary are required", i)
		}
		if p.URL != "" && !safeURL(p.URL) {
			add("projects[%d] (%s): url must start with https://", i, p.Name)
		}
	}
	for i, j := range r.Experience {
		where := fmt.Sprintf("experience[%d] (%s)", i, j.Company)
		if j.Company == "" || j.Title == "" {
			add("%s: company and title are required", where)
		}
		start, err := time.Parse(monthLayout, j.Start)
		if err != nil {
			add("%s: start %q must be YYYY-MM", where, j.Start)
			continue
		}
		if j.End == Present {
			continue
		}
		end, err := time.Parse(monthLayout, j.End)
		if err != nil {
			add("%s: end %q must be YYYY-MM or %q", where, j.End, Present)
			continue
		}
		if end.Before(start) {
			add("%s: end %s is before start %s", where, j.End, j.Start)
		}
	}
	for i, h := range r.allHighlights() {
		if strings.TrimSpace(h) == "" {
			add("highlight %d is empty", i)
		}
	}
	return errors.Join(errs...)
}

func (r *Resume) allHighlights() []string {
	var out []string
	for _, p := range r.Projects {
		out = append(out, p.Highlights...)
	}
	for _, j := range r.Experience {
		out = append(out, j.Highlights...)
	}
	return out
}

// safeURL allows only schemes that cannot execute script when rendered as a link.
func safeURL(u string) bool {
	return strings.HasPrefix(u, "https://") || strings.HasPrefix(u, "mailto:")
}

// FormatMonth turns "2018-08" into "Aug 2018" and "present" into "Present".
func FormatMonth(s string) string {
	if s == Present {
		return "Present"
	}
	t, err := time.Parse(monthLayout, s)
	if err != nil {
		return s
	}
	return t.Format("Jan 2006")
}
