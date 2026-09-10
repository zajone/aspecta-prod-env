// Package httpapi contains the HTTP surface of the service. It is split into
// two routers on purpose: a public router carrying the customer-facing API and
// an operations router carrying health, metrics and the Alertmanager webhook.
// Only the public port is reachable through the Ingress, which lets the
// NetworkPolicies grant Prometheus and Alertmanager access to the operations
// port without also exposing it to the internet.
package httpapi

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/zajone/aspecta-prod-env/apps/backend/internal/catalogue"
	"github.com/zajone/aspecta-prod-env/apps/backend/internal/observability"
)

// Config carries the runtime settings sourced from the ConfigMap and Secret.
type Config struct {
	Banner          string
	DefaultPageSize int
	MaxPageSize     int
	SearchEnabled   bool
	AdminToken      string
	Version         string
	Revision        string
	AlertBuffer     int
}

// Server owns the request handlers and the mutable runtime state.
type Server struct {
	cfg     Config
	cat     *catalogue.Catalogue
	metrics *observability.Metrics
	log     *slog.Logger
	alerts  *AlertStore

	draining    atomic.Bool
	maintenance atomic.Bool
	startedAt   time.Time
}

// NewServer wires the handlers and publishes the metrics that are known at
// start-up.
func NewServer(cfg Config, cat *catalogue.Catalogue, m *observability.Metrics, log *slog.Logger) *Server {
	s := &Server{
		cfg:       cfg,
		cat:       cat,
		metrics:   m,
		log:       log,
		alerts:    NewAlertStore(cfg.AlertBuffer),
		startedAt: time.Now(),
	}
	m.CatalogueObjects.Set(float64(cat.Size()))
	m.MaintenanceMode.Set(0)
	m.StartTime.Set(float64(s.startedAt.Unix()))
	m.BuildInfo.WithLabelValues(cfg.Version, cfg.Revision, runtime.Version()).Set(1)
	return s
}

// PublicRouter serves the API consumed by the frontend.
func (s *Server) PublicRouter() http.Handler {
	mux := http.NewServeMux()
	s.route(mux, "GET /api/v1/objects", s.handleListObjects)
	s.route(mux, "GET /api/v1/objects/{id}", s.handleGetObject)
	s.route(mux, "GET /api/v1/stats", s.handleStats)
	s.route(mux, "GET /api/v1/alerts", s.handleListAlerts)
	mux.HandleFunc("/", s.handleNotFound)
	return withSecurityHeaders(withRequestLog(s.log, mux))
}

// OpsRouter serves probes, metrics and the Alertmanager webhook. It is never
// published through the Ingress.
func (s *Server) OpsRouter() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.handleHealthz)
	mux.HandleFunc("GET /readyz", s.handleReadyz)
	mux.Handle("GET /metrics", s.metrics.Handler())
	s.route(mux, "POST /internal/alerts", s.handleAlertWebhook)
	// Draining is a property of one replica, so it has to be addressed as one
	// replica. On the public router it went through the Service, and the first
	// thing a drain does is remove this pod from that Service's endpoints -
	// so the request that would undo it could never land on the pod that was
	// drained. Two drains of a two-replica Deployment left no way back in.
	//
	// Here it is reached per-pod with `kubectl port-forward`, which is also
	// where a mutating admin control belongs: off the public Ingress
	// entirely.
	s.route(mux, "POST /internal/maintenance", s.requireAdmin(s.handleMaintenance))
	return mux
}

// route registers a handler and instruments it with the pattern as the metric
// label, keeping request metrics free of unbounded path values.
func (s *Server) route(mux *http.ServeMux, pattern string, h http.HandlerFunc) {
	route := pattern
	if i := strings.IndexByte(pattern, ' '); i >= 0 {
		route = pattern[i+1:]
	}
	mux.Handle(pattern, s.metrics.Instrument(route, h))
}

// StartDraining flips readiness to false so the endpoint controller removes
// this pod before the server stops accepting connections.
func (s *Server) StartDraining() {
	s.draining.Store(true)
}

// Ready reports whether the instance should receive traffic.
func (s *Server) Ready() bool {
	return !s.draining.Load() && !s.maintenance.Load()
}

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok"})
}

func (s *Server) handleReadyz(w http.ResponseWriter, _ *http.Request) {
	if !s.Ready() {
		reason := "draining"
		if s.maintenance.Load() {
			reason = "maintenance"
		}
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"status": "unavailable", "reason": reason})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ready", "objects": s.cat.Size()})
}

func (s *Server) handleListObjects(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	term := q.Get("q")
	if term != "" && !s.cfg.SearchEnabled {
		writeError(w, http.StatusForbidden, "search_disabled", "Free-text search is disabled by configuration.")
		return
	}

	page := s.intParam(q.Get("page"), 1, 1, 1_000_000)
	size := s.intParam(q.Get("size"), s.cfg.DefaultPageSize, 1, s.cfg.MaxPageSize)

	results := s.cat.Find(catalogue.Query{
		Term:          term,
		Type:          q.Get("type"),
		Constellation: q.Get("constellation"),
	})

	if term != "" {
		outcome := "hit"
		if len(results) == 0 {
			outcome = "miss"
		}
		s.metrics.SearchQueries.WithLabelValues(outcome).Inc()
	}

	writeJSON(w, http.StatusOK, catalogue.Paginate(results, page, size))
}

func (s *Server) handleGetObject(w http.ResponseWriter, r *http.Request) {
	obj, err := s.cat.Get(r.PathValue("id"))
	if errors.Is(err, catalogue.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found", "No catalogue object with that identifier.")
		return
	}
	writeJSON(w, http.StatusOK, obj)
}

func (s *Server) handleStats(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"banner":         s.cfg.Banner,
		"version":        s.cfg.Version,
		"revision":       s.cfg.Revision,
		"catalogue":      map[string]any{"revision": s.cat.Revision, "source": s.cat.Source, "objects": s.cat.Size()},
		"countsByType":   s.cat.CountsByType(),
		"constellations": s.cat.Constellations(),
		"searchEnabled":  s.cfg.SearchEnabled,
		"maintenance":    s.maintenance.Load(),
		"uptimeSeconds":  int64(time.Since(s.startedAt).Seconds()),
		"activeAlerts":   s.alerts.ActiveCount(),
	})
}

func (s *Server) handleMaintenance(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Enabled *bool `json:"enabled"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", err.Error())
		return
	}
	if body.Enabled == nil {
		writeError(w, http.StatusBadRequest, "invalid_body", `field "enabled" is required`)
		return
	}

	s.maintenance.Store(*body.Enabled)
	if *body.Enabled {
		s.metrics.MaintenanceMode.Set(1)
	} else {
		s.metrics.MaintenanceMode.Set(0)
	}
	s.log.WarnContext(r.Context(), "maintenance mode changed", slog.Bool("enabled", *body.Enabled))
	writeJSON(w, http.StatusOK, map[string]any{"maintenance": *body.Enabled})
}

// requireAdmin gates privileged endpoints behind the token mounted from the
// Secret. With no token configured the endpoint stays closed rather than open.
func (s *Server) requireAdmin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.cfg.AdminToken == "" {
			writeError(w, http.StatusNotImplemented, "admin_disabled", "No admin token is configured for this instance.")
			return
		}
		presented := r.Header.Get("X-Aspecta-Token")
		if subtle.ConstantTimeCompare([]byte(presented), []byte(s.cfg.AdminToken)) != 1 {
			s.log.WarnContext(r.Context(), "rejected admin request", slog.String("path", r.URL.Path))
			writeError(w, http.StatusUnauthorized, "unauthorized", "A valid X-Aspecta-Token header is required.")
			return
		}
		next(w, r)
	}
}

func (s *Server) handleNotFound(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotFound, "not_found", "Unknown endpoint.")
}

func (s *Server) intParam(raw string, def, min, max int) int {
	if raw == "" {
		return def
	}
	v, err := strconv.Atoi(raw)
	if err != nil {
		return def
	}
	if v < min {
		return min
	}
	if v > max {
		return max
	}
	return v
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{"error": map[string]string{"code": code, "message": message}})
}

// decodeJSON reads a bounded request body and rejects unknown fields, so a
// typo in a client payload surfaces as an error instead of being ignored.
func decodeJSON(r *http.Request, dst any) error {
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, maxBodyBytes))
	dec.DisallowUnknownFields()
	return dec.Decode(dst)
}

// decodeJSONLenient is used for payloads owned by another system. Alertmanager
// is free to add fields to its webhook schema, and rejecting those would break
// the alert path on an upgrade.
func decodeJSONLenient(r *http.Request, dst any) error {
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, maxBodyBytes))
	return dec.Decode(dst)
}

// maxBodyBytes caps every request body the service will read.
const maxBodyBytes = 256 << 10
