package httpapi

import (
	"log/slog"
	"net/http"
	"sort"
	"sync"
	"time"
)

// webhookPayload mirrors the Alertmanager webhook contract (schema version 4).
// Only the fields the service actually renders are declared.
type webhookPayload struct {
	Version  string            `json:"version"`
	Status   string            `json:"status"`
	Receiver string            `json:"receiver"`
	Alerts   []webhookAlert    `json:"alerts"`
	Common   map[string]string `json:"commonLabels"`
}

type webhookAlert struct {
	Status      string            `json:"status"`
	Labels      map[string]string `json:"labels"`
	Annotations map[string]string `json:"annotations"`
	StartsAt    time.Time         `json:"startsAt"`
	EndsAt      time.Time         `json:"endsAt"`
	Fingerprint string            `json:"fingerprint"`
}

// Alert is the flattened view the frontend consumes.
type Alert struct {
	Fingerprint string    `json:"fingerprint"`
	Name        string    `json:"name"`
	Severity    string    `json:"severity"`
	Status      string    `json:"status"`
	Summary     string    `json:"summary"`
	Description string    `json:"description"`
	Namespace   string    `json:"namespace"`
	StartsAt    time.Time `json:"startsAt"`
	ReceivedAt  time.Time `json:"receivedAt"`
}

// AlertStore keeps the most recent Alertmanager notifications in memory.
//
// This is deliberately ephemeral: Alertmanager remains the source of truth and
// re-sends firing alerts on every group interval, so a restarted pod repopulates
// itself within a minute. It exists so the environment can demonstrate a
// complete alert path - rule fires, Alertmanager routes, receiver acknowledges -
// without depending on an external chat or paging provider.
type AlertStore struct {
	mu       sync.RWMutex
	capacity int
	byPrint  map[string]Alert
}

// NewAlertStore returns a store bounded to the given number of alerts.
func NewAlertStore(capacity int) *AlertStore {
	if capacity < 1 {
		capacity = 50
	}
	return &AlertStore{capacity: capacity, byPrint: make(map[string]Alert, capacity)}
}

// Upsert records an alert, replacing any earlier state for the same fingerprint.
func (s *AlertStore) Upsert(a Alert) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.byPrint[a.Fingerprint] = a
	if len(s.byPrint) <= s.capacity {
		return
	}
	// Over capacity: drop the oldest resolved alert, falling back to the
	// oldest alert overall so the map can never grow without bound.
	var oldestResolved, oldest string
	for k, v := range s.byPrint {
		if v.Status == "resolved" && (oldestResolved == "" || v.ReceivedAt.Before(s.byPrint[oldestResolved].ReceivedAt)) {
			oldestResolved = k
		}
		if oldest == "" || v.ReceivedAt.Before(s.byPrint[oldest].ReceivedAt) {
			oldest = k
		}
	}
	victim := oldestResolved
	if victim == "" {
		victim = oldest
	}
	delete(s.byPrint, victim)
}

// List returns every stored alert, firing first and newest first within a group.
func (s *AlertStore) List() []Alert {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]Alert, 0, len(s.byPrint))
	for _, v := range s.byPrint {
		out = append(out, v)
	}
	sort.Slice(out, func(i, j int) bool {
		if (out[i].Status == "firing") != (out[j].Status == "firing") {
			return out[i].Status == "firing"
		}
		return out[i].ReceivedAt.After(out[j].ReceivedAt)
	})
	return out
}

// ActiveCount reports how many stored alerts are currently firing.
func (s *AlertStore) ActiveCount() int {
	s.mu.RLock()
	defer s.mu.RUnlock()

	n := 0
	for _, v := range s.byPrint {
		if v.Status == "firing" {
			n++
		}
	}
	return n
}

func (s *Server) handleAlertWebhook(w http.ResponseWriter, r *http.Request) {
	var payload webhookPayload
	if err := decodeJSONLenient(r, &payload); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", err.Error())
		return
	}

	now := time.Now().UTC()
	for _, a := range payload.Alerts {
		alert := Alert{
			Fingerprint: a.Fingerprint,
			Name:        a.Labels["alertname"],
			Severity:    a.Labels["severity"],
			Status:      a.Status,
			Summary:     a.Annotations["summary"],
			Description: a.Annotations["description"],
			Namespace:   a.Labels["namespace"],
			StartsAt:    a.StartsAt,
			ReceivedAt:  now,
		}
		if alert.Fingerprint == "" {
			alert.Fingerprint = alert.Name + "/" + alert.Namespace
		}
		if alert.Status == "" {
			alert.Status = payload.Status
		}
		s.alerts.Upsert(alert)
		s.metrics.AlertsReceived.WithLabelValues(orUnknown(alert.Severity), orUnknown(alert.Status)).Inc()
		s.log.Warn("alert notification received",
			slog.String("alert", alert.Name),
			slog.String("severity", alert.Severity),
			slog.String("status", alert.Status),
		)
	}

	s.metrics.ActiveAlerts.Set(float64(s.alerts.ActiveCount()))
	writeJSON(w, http.StatusAccepted, map[string]any{"accepted": len(payload.Alerts)})
}

func (s *Server) handleListAlerts(w http.ResponseWriter, _ *http.Request) {
	alerts := s.alerts.List()
	writeJSON(w, http.StatusOK, map[string]any{
		"items":  alerts,
		"firing": s.alerts.ActiveCount(),
		"total":  len(alerts),
	})
}

func orUnknown(s string) string {
	if s == "" {
		return "unknown"
	}
	return s
}
