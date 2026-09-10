// Package observability wires the Prometheus instrumentation used by the
// service. Every metric is registered on a private registry so the /metrics
// endpoint exposes exactly what this service owns plus the standard Go and
// process collectors.
package observability

import (
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Metrics holds every collector the service updates at runtime.
type Metrics struct {
	registry *prometheus.Registry

	RequestsTotal   *prometheus.CounterVec
	RequestDuration *prometheus.HistogramVec
	ResponseBytes   *prometheus.CounterVec
	SearchQueries   *prometheus.CounterVec
	AlertsReceived  *prometheus.CounterVec

	RequestsInFlight prometheus.Gauge
	CatalogueObjects prometheus.Gauge
	ActiveAlerts     prometheus.Gauge
	MaintenanceMode  prometheus.Gauge
	StartTime        prometheus.Gauge
	BuildInfo        *prometheus.GaugeVec
}

// New builds the registry and registers all collectors.
func New(namespace string) *Metrics {
	reg := prometheus.NewRegistry()
	reg.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)

	m := &Metrics{
		registry: reg,
		RequestsTotal: prometheus.NewCounterVec(prometheus.CounterOpts{
			Namespace: namespace,
			Name:      "http_requests_total",
			Help:      "Total number of HTTP requests handled, by route and status class.",
		}, []string{"method", "route", "status"}),
		RequestDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Namespace: namespace,
			Name:      "http_request_duration_seconds",
			Help:      "HTTP request latency in seconds.",
			// Tuned for a sub-millisecond in-memory API: the interesting
			// signal sits well below the Prometheus default buckets.
			Buckets: []float64{0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5},
		}, []string{"method", "route"}),
		ResponseBytes: prometheus.NewCounterVec(prometheus.CounterOpts{
			Namespace: namespace,
			Name:      "http_response_bytes_total",
			Help:      "Total response body bytes written, by route.",
		}, []string{"method", "route"}),
		SearchQueries: prometheus.NewCounterVec(prometheus.CounterOpts{
			Namespace: namespace,
			Name:      "search_queries_total",
			Help:      "Catalogue searches, split by whether they returned results.",
		}, []string{"outcome"}),
		AlertsReceived: prometheus.NewCounterVec(prometheus.CounterOpts{
			Namespace: namespace,
			Name:      "alerts_received_total",
			Help:      "Alertmanager notifications delivered to the service webhook.",
		}, []string{"severity", "status"}),
		// Concurrency, not a rate: the one golden signal the counters above
		// cannot reconstruct. A latency rise with flat in-flight is a slower
		// backend; a latency rise with in-flight climbing is a queue forming.
		RequestsInFlight: prometheus.NewGauge(prometheus.GaugeOpts{
			Namespace: namespace,
			Name:      "http_requests_in_flight",
			Help:      "Requests currently being served.",
		}),
		CatalogueObjects: prometheus.NewGauge(prometheus.GaugeOpts{
			Namespace: namespace,
			Name:      "catalogue_objects",
			Help:      "Number of objects loaded from the embedded catalogue.",
		}),
		ActiveAlerts: prometheus.NewGauge(prometheus.GaugeOpts{
			Namespace: namespace,
			Name:      "active_alerts",
			Help:      "Alerts currently reported as firing by Alertmanager.",
		}),
		MaintenanceMode: prometheus.NewGauge(prometheus.GaugeOpts{
			Namespace: namespace,
			Name:      "maintenance_mode",
			Help:      "1 when the instance has been drained through the admin API, 0 otherwise.",
		}),
		// Unix seconds, set once. Uptime is time() minus this, and a change in
		// it is what marks a deploy or a restart on a dashboard - neither of
		// which is derivable from a counter that resets to zero at the same
		// moment.
		StartTime: prometheus.NewGauge(prometheus.GaugeOpts{
			Namespace: namespace,
			Name:      "start_time_seconds",
			Help:      "Unix timestamp at which the process started serving.",
		}),
		BuildInfo: prometheus.NewGaugeVec(prometheus.GaugeOpts{
			Namespace: namespace,
			Name:      "build_info",
			Help:      "Build metadata of the running binary, always 1.",
		}, []string{"version", "revision", "go_version"}),
	}

	reg.MustRegister(
		m.RequestsTotal, m.RequestDuration, m.ResponseBytes, m.SearchQueries,
		m.AlertsReceived, m.RequestsInFlight, m.CatalogueObjects, m.ActiveAlerts,
		m.MaintenanceMode, m.StartTime, m.BuildInfo,
	)
	return m
}

// Handler returns the /metrics HTTP handler for the private registry.
func (m *Metrics) Handler() http.Handler {
	return promhttp.HandlerFor(m.registry, promhttp.HandlerOpts{})
}

// statusRecorder captures the response status code and body size for
// instrumentation.
type statusRecorder struct {
	http.ResponseWriter
	status  int
	written int64
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// Write counts what the handler actually wrote. Content-Length is not a
// substitute: it is absent on a chunked response and it is a promise rather
// than a measurement.
func (r *statusRecorder) Write(b []byte) (int, error) {
	n, err := r.ResponseWriter.Write(b)
	r.written += int64(n)
	return n, err
}

// Status reports the captured status code, defaulting to 200 when the handler
// never called WriteHeader explicitly.
func (r *statusRecorder) Status() int {
	if r.status == 0 {
		return http.StatusOK
	}
	return r.status
}

// Instrument records request count and latency for a named route. The route
// label is the registered pattern, never the raw path, so high-cardinality
// values such as object IDs cannot blow up the time series count.
func (m *Metrics) Instrument(route string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := &statusRecorder{ResponseWriter: w}
		start := time.Now()

		// Decremented in a defer so a handler that panics cannot leak the
		// gauge upwards for the lifetime of the process.
		m.RequestsInFlight.Inc()
		defer m.RequestsInFlight.Dec()

		next.ServeHTTP(rec, r)
		elapsed := time.Since(start).Seconds()

		m.RequestsTotal.WithLabelValues(r.Method, route, strconv.Itoa(rec.Status())).Inc()
		m.RequestDuration.WithLabelValues(r.Method, route).Observe(elapsed)
		m.ResponseBytes.WithLabelValues(r.Method, route).Add(float64(rec.written))
	})
}
