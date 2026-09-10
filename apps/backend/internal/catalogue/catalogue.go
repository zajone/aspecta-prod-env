// Package catalogue holds the in-memory deep-sky object catalogue that ships
// with the binary. The dataset is small, immutable and read-only, so the whole
// service stays stateless: any replica can answer any request and pods can be
// rescheduled without data migration.
package catalogue

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
)

// Object is a single catalogue entry.
type Object struct {
	ID            string  `json:"id"`
	Messier       string  `json:"messier"`
	NGC           string  `json:"ngc"`
	Name          string  `json:"name"`
	Type          string  `json:"type"`
	Constellation string  `json:"constellation"`
	Magnitude     float64 `json:"magnitude"`
	DistanceLy    int64   `json:"distanceLy"`
	DiscoveredBy  string  `json:"discoveredBy"`
	Year          int     `json:"year"`
	Description   string  `json:"description"`
}

// Catalogue is an immutable, indexed view over the embedded dataset.
type Catalogue struct {
	Revision string
	Source   string

	objects []Object
	byID    map[string]Object
}

// ErrNotFound is returned when an object ID is not present in the catalogue.
var ErrNotFound = errors.New("object not found")

type rawCatalogue struct {
	Revision string   `json:"revision"`
	Source   string   `json:"source"`
	Objects  []Object `json:"objects"`
}

// Load parses the dataset and builds the lookup index. It fails loudly on an
// empty or malformed dataset so a broken image never reaches a ready state.
func Load(raw []byte) (*Catalogue, error) {
	var parsed rawCatalogue
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return nil, fmt.Errorf("parse catalogue: %w", err)
	}
	if len(parsed.Objects) == 0 {
		return nil, errors.New("catalogue contains no objects")
	}

	c := &Catalogue{
		Revision: parsed.Revision,
		Source:   parsed.Source,
		objects:  parsed.Objects,
		byID:     make(map[string]Object, len(parsed.Objects)),
	}
	for _, o := range parsed.Objects {
		if o.ID == "" {
			return nil, errors.New("catalogue contains an object without an id")
		}
		// Indexed by the same key Get looks up with. Storing the raw id here
		// while Get lowercased meant an entry written "M110" listed correctly
		// and then 404ed on /api/v1/objects/M110, and the duplicate check
		// below would not have caught "m110" alongside it either.
		key := strings.ToLower(strings.TrimSpace(o.ID))
		if _, dup := c.byID[key]; dup {
			return nil, fmt.Errorf("duplicate object id %q", o.ID)
		}
		c.byID[key] = o
	}
	sort.Slice(c.objects, func(i, j int) bool { return c.objects[i].Magnitude < c.objects[j].Magnitude })
	return c, nil
}

// Size reports the number of objects in the catalogue.
func (c *Catalogue) Size() int { return len(c.objects) }

// Get returns a single object by its ID.
func (c *Catalogue) Get(id string) (Object, error) {
	o, ok := c.byID[strings.ToLower(strings.TrimSpace(id))]
	if !ok {
		return Object{}, ErrNotFound
	}
	return o, nil
}

// Query narrows the catalogue by free-text term, type and constellation.
type Query struct {
	Term          string
	Type          string
	Constellation string
}

// Find returns every object matching the query, brightest first.
func (c *Catalogue) Find(q Query) []Object {
	term := strings.ToLower(strings.TrimSpace(q.Term))
	typ := strings.ToLower(strings.TrimSpace(q.Type))
	con := strings.ToLower(strings.TrimSpace(q.Constellation))

	out := make([]Object, 0, len(c.objects))
	for _, o := range c.objects {
		if typ != "" && strings.ToLower(o.Type) != typ {
			continue
		}
		if con != "" && strings.ToLower(o.Constellation) != con {
			continue
		}
		if term != "" && !matches(o, term) {
			continue
		}
		out = append(out, o)
	}
	return out
}

func matches(o Object, term string) bool {
	for _, field := range []string{o.ID, o.Messier, o.NGC, o.Name, o.Type, o.Constellation, o.DiscoveredBy} {
		if strings.Contains(strings.ToLower(field), term) {
			return true
		}
	}
	return false
}

// CountsByType returns how many objects of each type the catalogue holds.
func (c *Catalogue) CountsByType() map[string]int {
	counts := make(map[string]int)
	for _, o := range c.objects {
		counts[o.Type]++
	}
	return counts
}

// Constellations returns the sorted set of constellations present.
func (c *Catalogue) Constellations() []string {
	seen := make(map[string]struct{})
	for _, o := range c.objects {
		seen[o.Constellation] = struct{}{}
	}
	out := make([]string, 0, len(seen))
	for k := range seen {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// Page is one slice of a result set together with its pagination metadata.
type Page struct {
	Items    []Object `json:"items"`
	Total    int      `json:"total"`
	Page     int      `json:"page"`
	PageSize int      `json:"pageSize"`
	Pages    int      `json:"pages"`
}

// Paginate slices results using 1-based page numbers. Out-of-range pages return
// an empty item list rather than an error, which keeps clients simple.
func Paginate(items []Object, page, pageSize int) Page {
	if page < 1 {
		page = 1
	}
	if pageSize < 1 {
		pageSize = 1
	}
	total := len(items)
	pages := (total + pageSize - 1) / pageSize

	start := (page - 1) * pageSize
	if start > total {
		start = total
	}
	end := start + pageSize
	if end > total {
		end = total
	}
	return Page{
		Items:    items[start:end],
		Total:    total,
		Page:     page,
		PageSize: pageSize,
		Pages:    pages,
	}
}
