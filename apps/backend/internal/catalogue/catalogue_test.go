package catalogue

import "testing"

const sample = `{
  "revision": "test",
  "source": "unit test",
  "objects": [
    {"id":"m1","messier":"M1","name":"Crab Nebula","type":"supernova-remnant","constellation":"Taurus","magnitude":8.4},
    {"id":"m31","messier":"M31","name":"Andromeda Galaxy","type":"galaxy","constellation":"Andromeda","magnitude":3.4},
    {"id":"m42","messier":"M42","name":"Orion Nebula","type":"emission-nebula","constellation":"Orion","magnitude":4.0}
  ]
}`

func mustLoad(t *testing.T) *Catalogue {
	t.Helper()
	c, err := Load([]byte(sample))
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	return c
}

func TestLoadRejectsBadInput(t *testing.T) {
	cases := map[string]string{
		"malformed json":    `{`,
		"no objects":        `{"objects":[]}`,
		"object without id": `{"objects":[{"name":"nameless"}]}`,
		"duplicate id":      `{"objects":[{"id":"m1"},{"id":"m1"}]}`,
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := Load([]byte(raw)); err == nil {
				t.Fatal("expected an error, got nil")
			}
		})
	}
}

func TestLoadSortsByMagnitude(t *testing.T) {
	c := mustLoad(t)
	got := c.Find(Query{})
	if len(got) != 3 {
		t.Fatalf("Find() returned %d objects, want 3", len(got))
	}
	if got[0].ID != "m31" {
		t.Errorf("brightest object = %q, want m31", got[0].ID)
	}
}

func TestGet(t *testing.T) {
	c := mustLoad(t)
	if _, err := c.Get("M42"); err != nil {
		t.Errorf("Get() should be case-insensitive, got %v", err)
	}
	if _, err := c.Get("m999"); err != ErrNotFound {
		t.Errorf("Get() error = %v, want ErrNotFound", err)
	}
}

func TestFindFilters(t *testing.T) {
	c := mustLoad(t)
	tests := []struct {
		name  string
		query Query
		want  int
	}{
		{"no filter", Query{}, 3},
		{"term on name", Query{Term: "nebula"}, 2},
		{"term on messier id", Query{Term: "m31"}, 1},
		{"type", Query{Type: "galaxy"}, 1},
		{"constellation is case-insensitive", Query{Constellation: "orion"}, 1},
		{"type and term combined", Query{Type: "galaxy", Term: "crab"}, 0},
		{"unknown term", Query{Term: "quasar"}, 0},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := len(c.Find(tc.query)); got != tc.want {
				t.Errorf("Find(%+v) returned %d, want %d", tc.query, got, tc.want)
			}
		})
	}
}

func TestPaginate(t *testing.T) {
	items := mustLoad(t).Find(Query{})

	first := Paginate(items, 1, 2)
	if len(first.Items) != 2 || first.Pages != 2 || first.Total != 3 {
		t.Errorf("page 1 = %+v, want 2 items across 2 pages of 3 total", first)
	}

	last := Paginate(items, 2, 2)
	if len(last.Items) != 1 {
		t.Errorf("page 2 returned %d items, want 1", len(last.Items))
	}

	beyond := Paginate(items, 99, 2)
	if len(beyond.Items) != 0 {
		t.Errorf("page beyond the end returned %d items, want 0", len(beyond.Items))
	}

	clamped := Paginate(items, 0, 0)
	if clamped.Page != 1 || clamped.PageSize != 1 {
		t.Errorf("Paginate() did not clamp invalid input: %+v", clamped)
	}
}

func TestCountsByType(t *testing.T) {
	counts := mustLoad(t).CountsByType()
	if counts["galaxy"] != 1 || len(counts) != 3 {
		t.Errorf("CountsByType() = %v", counts)
	}
}

func TestGetIsCaseInsensitiveWhateverTheDataUses(t *testing.T) {
	// An id written in upper case used to index under "M110" while Get looked
	// up "m110", so the object listed fine and then 404ed. Both spellings must
	// resolve, whichever case the data file happens to use.
	const mixedCase = `{
  "revision": "test",
  "source": "unit test",
  "objects": [
    {"id":"M110","messier":"M110","name":"Edward Young Star","type":"galaxy","constellation":"Andromeda","magnitude":8.5}
  ]
}`
	c, err := Load([]byte(mixedCase))
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	for _, spelling := range []string{"M110", "m110", "  M110  "} {
		if _, err := c.Get(spelling); err != nil {
			t.Errorf("Get(%q) = %v, want the object", spelling, err)
		}
	}
}

func TestLoadRejectsDuplicateIDsDifferingOnlyInCase(t *testing.T) {
	const dupes = `{
  "revision": "test",
  "source": "unit test",
  "objects": [
    {"id":"M31","name":"a","type":"galaxy","constellation":"Andromeda","magnitude":3.4},
    {"id":"m31","name":"b","type":"galaxy","constellation":"Andromeda","magnitude":3.4}
  ]
}`
	if _, err := Load([]byte(dupes)); err == nil {
		t.Error("Load() accepted two ids that resolve to the same lookup key")
	}
}
