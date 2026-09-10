package httpapi

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/zajone/aspecta-prod-env/apps/backend/internal/catalogue"
	"github.com/zajone/aspecta-prod-env/apps/backend/internal/observability"
)

const sample = `{
  "revision": "test",
  "objects": [
    {"id":"m1","messier":"M1","name":"Crab Nebula","type":"supernova-remnant","constellation":"Taurus","magnitude":8.4},
    {"id":"m31","messier":"M31","name":"Andromeda Galaxy","type":"galaxy","constellation":"Andromeda","magnitude":3.4}
  ]
}`

func newTestServer(t *testing.T, cfg Config) *Server {
	t.Helper()
	cat, err := catalogue.Load([]byte(sample))
	if err != nil {
		t.Fatalf("load catalogue: %v", err)
	}
	if cfg.DefaultPageSize == 0 {
		cfg.DefaultPageSize = 10
	}
	if cfg.MaxPageSize == 0 {
		cfg.MaxPageSize = 50
	}
	log := slog.New(slog.NewJSONHandler(io.Discard, nil))
	return NewServer(cfg, cat, observability.New("aspecta"), log)
}

func do(h http.Handler, method, target, body string, headers map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, target, strings.NewReader(body))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestListObjects(t *testing.T) {
	h := newTestServer(t, Config{SearchEnabled: true}).PublicRouter()

	rec := do(h, http.MethodGet, "/api/v1/objects", "", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var page catalogue.Page
	if err := json.Unmarshal(rec.Body.Bytes(), &page); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if page.Total != 2 {
		t.Errorf("total = %d, want 2", page.Total)
	}

	if rec.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Error("security headers are missing from the response")
	}
	if rec.Header().Get("X-Request-Id") == "" {
		t.Error("response is missing a request id")
	}
}

func TestListObjectsClampsPageSize(t *testing.T) {
	h := newTestServer(t, Config{SearchEnabled: true, MaxPageSize: 1}).PublicRouter()
	rec := do(h, http.MethodGet, "/api/v1/objects?size=500", "", nil)

	var page catalogue.Page
	_ = json.Unmarshal(rec.Body.Bytes(), &page)
	if page.PageSize != 1 {
		t.Errorf("pageSize = %d, want it clamped to 1", page.PageSize)
	}
}

func TestSearchCanBeDisabled(t *testing.T) {
	h := newTestServer(t, Config{SearchEnabled: false}).PublicRouter()
	if rec := do(h, http.MethodGet, "/api/v1/objects?q=crab", "", nil); rec.Code != http.StatusForbidden {
		t.Errorf("status = %d, want 403 when the search feature flag is off", rec.Code)
	}
	if rec := do(h, http.MethodGet, "/api/v1/objects", "", nil); rec.Code != http.StatusOK {
		t.Errorf("plain listing status = %d, want 200 even with search disabled", rec.Code)
	}
}

func TestGetObject(t *testing.T) {
	h := newTestServer(t, Config{}).PublicRouter()

	if rec := do(h, http.MethodGet, "/api/v1/objects/m31", "", nil); rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", rec.Code)
	}
	if rec := do(h, http.MethodGet, "/api/v1/objects/m999", "", nil); rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", rec.Code)
	}
	if rec := do(h, http.MethodGet, "/nope", "", nil); rec.Code != http.StatusNotFound {
		t.Errorf("unknown path status = %d, want 404", rec.Code)
	}
}

// The drain control must not be reachable from the Ingress at all. Asserted
// explicitly, because moving it back to the public router would be a one-line
// change that nothing else would catch.
func TestMaintenanceIsNotOnThePublicRouter(t *testing.T) {
	h := newTestServer(t, Config{AdminToken: "s3cret"}).PublicRouter()
	tok := map[string]string{"X-Aspecta-Token": "s3cret"}
	for _, path := range []string{"/api/v1/admin/maintenance", "/internal/maintenance"} {
		if rec := do(h, http.MethodPost, path, `{"enabled":true}`, tok); rec.Code != http.StatusNotFound {
			t.Errorf("public router answered %s with %d, want 404", path, rec.Code)
		}
	}
}

func TestAdminEndpointIsClosedByDefault(t *testing.T) {
	h := newTestServer(t, Config{}).OpsRouter()
	rec := do(h, http.MethodPost, "/internal/maintenance", `{"enabled":true}`, nil)
	if rec.Code != http.StatusNotImplemented {
		t.Errorf("status = %d, want 501 when no admin token is configured", rec.Code)
	}
}

func TestAdminEndpointRequiresToken(t *testing.T) {
	s := newTestServer(t, Config{AdminToken: "s3cret"})
	h := s.OpsRouter()

	if rec := do(h, http.MethodPost, "/internal/maintenance", `{"enabled":true}`, nil); rec.Code != http.StatusUnauthorized {
		t.Errorf("status without token = %d, want 401", rec.Code)
	}
	if rec := do(h, http.MethodPost, "/internal/maintenance", `{"enabled":true}`, map[string]string{"X-Aspecta-Token": "wrong"}); rec.Code != http.StatusUnauthorized {
		t.Errorf("status with wrong token = %d, want 401", rec.Code)
	}

	ok := map[string]string{"X-Aspecta-Token": "s3cret"}
	if rec := do(h, http.MethodPost, "/internal/maintenance", `{"enabled":true}`, ok); rec.Code != http.StatusOK {
		t.Fatalf("status with valid token = %d, want 200", rec.Code)
	}
	if s.Ready() {
		t.Error("instance should not be ready while in maintenance mode")
	}
	// And back out again on the same router - the failure that made this move
	// necessary was that undoing a drain was impossible.
	if rec := do(h, http.MethodPost, "/internal/maintenance", `{"enabled":false}`, ok); rec.Code != http.StatusOK {
		t.Fatalf("status turning maintenance off = %d, want 200", rec.Code)
	}
	if !s.Ready() {
		t.Error("instance should be ready again once maintenance is turned off")
	}
	if rec := do(h, http.MethodPost, "/internal/maintenance", `{"unexpected":1}`, ok); rec.Code != http.StatusBadRequest {
		t.Errorf("status for unknown field = %d, want 400", rec.Code)
	}
}

func TestReadinessReflectsDraining(t *testing.T) {
	s := newTestServer(t, Config{})
	ops := s.OpsRouter()

	if rec := do(ops, http.MethodGet, "/readyz", "", nil); rec.Code != http.StatusOK {
		t.Fatalf("readyz = %d, want 200", rec.Code)
	}
	s.StartDraining()
	if rec := do(ops, http.MethodGet, "/readyz", "", nil); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("readyz while draining = %d, want 503", rec.Code)
	}
	if rec := do(ops, http.MethodGet, "/healthz", "", nil); rec.Code != http.StatusOK {
		t.Error("liveness must stay healthy while the pod drains")
	}
}

func TestMetricsEndpointExposesCatalogueSize(t *testing.T) {
	s := newTestServer(t, Config{})
	// Serve one API request first: counter vectors only appear in the
	// exposition output once a labelled child has been observed.
	do(s.PublicRouter(), http.MethodGet, "/api/v1/objects", "", nil)

	rec := do(s.OpsRouter(), http.MethodGet, "/metrics", "", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("metrics status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	for _, want := range []string{
		"aspecta_catalogue_objects 2",
		"aspecta_build_info",
		`aspecta_http_requests_total{method="GET",route="/api/v1/objects",status="200"} 1`,
		"aspecta_http_request_duration_seconds_bucket",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("metrics output is missing %q", want)
		}
	}
}

func TestMetricsExposeTheSaturationSignals(t *testing.T) {
	s := newTestServer(t, Config{})
	do(s.PublicRouter(), http.MethodGet, "/api/v1/objects", "", nil)

	body := do(s.OpsRouter(), http.MethodGet, "/metrics", "", nil).Body.String()

	// In-flight must be back at zero once the request has been served. A
	// non-zero value here would mean Instrument leaks the gauge, which shows up
	// on a dashboard as a queue that grows forever and never drains.
	if !strings.Contains(body, "aspecta_http_requests_in_flight 0") {
		t.Error("aspecta_http_requests_in_flight is not 0 after the request completed")
	}
	// The body was non-empty, so the byte counter must have moved off zero -
	// asserting only that the metric exists would pass with a broken Write.
	written := metricValue(t, body, `aspecta_http_response_bytes_total{method="GET",route="/api/v1/objects"}`)
	if written <= 0 {
		t.Errorf("aspecta_http_response_bytes_total = %v, want > 0", written)
	}
	if got := metricValue(t, body, "aspecta_start_time_seconds"); got <= 0 {
		t.Errorf("aspecta_start_time_seconds = %v, want a unix timestamp", got)
	}
}

// metricValue pulls the value of one exposition line out of a /metrics body.
func metricValue(t *testing.T, body, series string) float64 {
	t.Helper()
	for _, line := range strings.Split(body, "\n") {
		if !strings.HasPrefix(line, series+" ") {
			continue
		}
		v, err := strconv.ParseFloat(strings.TrimSpace(strings.TrimPrefix(line, series)), 64)
		if err != nil {
			t.Fatalf("parsing %q: %v", line, err)
		}
		return v
	}
	t.Fatalf("metrics output has no series %q", series)
	return 0
}

func TestAlertWebhook(t *testing.T) {
	s := newTestServer(t, Config{AlertBuffer: 5})
	ops := s.OpsRouter()

	payload := `{"version":"4","status":"firing","receiver":"aspecta","futureField":"ignored","alerts":[
	  {"status":"firing","fingerprint":"abc","labels":{"alertname":"AspectaBackendDown","severity":"critical","namespace":"aspecta"},
	   "annotations":{"summary":"backend is down"},"startsAt":"2026-03-01T10:00:00Z"}]}`

	if rec := do(ops, http.MethodPost, "/internal/alerts", payload, nil); rec.Code != http.StatusAccepted {
		t.Fatalf("webhook status = %d, want 202: %s", rec.Code, rec.Body.String())
	}
	if got := s.alerts.ActiveCount(); got != 1 {
		t.Fatalf("active alerts = %d, want 1", got)
	}

	rec := do(s.PublicRouter(), http.MethodGet, "/api/v1/alerts", "", nil)
	var out struct {
		Items  []Alert `json:"items"`
		Firing int     `json:"firing"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode alerts: %v", err)
	}
	if len(out.Items) != 1 || out.Items[0].Name != "AspectaBackendDown" || out.Firing != 1 {
		t.Errorf("alerts response = %+v", out)
	}

	resolved := strings.Replace(payload, `"status":"firing","fingerprint":"abc"`, `"status":"resolved","fingerprint":"abc"`, 1)
	if rec := do(ops, http.MethodPost, "/internal/alerts", resolved, nil); rec.Code != http.StatusAccepted {
		t.Fatalf("resolve status = %d, want 202", rec.Code)
	}
	if got := s.alerts.ActiveCount(); got != 0 {
		t.Errorf("active alerts after resolve = %d, want 0", got)
	}
}

func TestAlertStoreRespectsCapacity(t *testing.T) {
	store := NewAlertStore(2)
	for _, fp := range []string{"a", "b", "c", "d"} {
		store.Upsert(Alert{Fingerprint: fp, Status: "firing"})
	}
	if got := len(store.List()); got != 2 {
		t.Errorf("store holds %d alerts, want it bounded to 2", got)
	}
}
