// Command aspecta-backend serves the Aspecta deep-sky catalogue API.
//
// The dataset is compiled into the binary, so the service is fully stateless:
// it needs no database, no volume and no warm-up, which is what makes it safe
// to run several replicas behind a rolling update.
package main

import (
	"context"
	"embed"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/zajone/aspecta-prod-env/apps/backend/internal/catalogue"
	"github.com/zajone/aspecta-prod-env/apps/backend/internal/httpapi"
	"github.com/zajone/aspecta-prod-env/apps/backend/internal/observability"
)

//go:embed data/catalogue.json
var dataFS embed.FS

// Overridden at build time with -ldflags so the running image can be traced
// back to a commit without shelling into the pod.
var (
	version  = "dev"
	revision = "unknown"
)

const metricNamespace = "aspecta"

func main() {
	log := newLogger(env("LOG_LEVEL", "info"), env("LOG_FORMAT", "json"))
	slog.SetDefault(log)

	if err := run(log); err != nil {
		log.Error("fatal error", slog.Any("error", err))
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	raw, err := dataFS.ReadFile("data/catalogue.json")
	if err != nil {
		return err
	}
	cat, err := catalogue.Load(raw)
	if err != nil {
		return err
	}

	metrics := observability.New(metricNamespace)
	srv := httpapi.NewServer(httpapi.Config{
		Banner:          env("APP_BANNER", "Aspecta deep-sky catalogue"),
		DefaultPageSize: envInt("PAGE_SIZE_DEFAULT", 10),
		MaxPageSize:     envInt("PAGE_SIZE_MAX", 50),
		SearchEnabled:   envBool("FEATURE_SEARCH", true),
		AdminToken:      strings.TrimSpace(os.Getenv("ADMIN_TOKEN")),
		AlertBuffer:     envInt("ALERT_BUFFER_SIZE", 50),
		Version:         version,
		Revision:        revision,
	}, cat, metrics, log)

	public := newHTTPServer(":"+env("PORT", "8080"), srv.PublicRouter())
	ops := newHTTPServer(":"+env("OPS_PORT", "9090"), srv.OpsRouter())

	log.Info("starting aspecta backend",
		slog.String("version", version),
		slog.String("revision", revision),
		slog.String("api_addr", public.Addr),
		slog.String("ops_addr", ops.Addr),
		slog.Int("catalogue_objects", cat.Size()),
		slog.String("catalogue_revision", cat.Revision),
	)

	errc := make(chan error, 2)
	go serve(public, "api", log, errc)
	go serve(ops, "ops", log, errc)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}

	// Graceful shutdown: fail readiness first so the endpoint controller pulls
	// this pod out of the Service, wait for in-flight load balancer updates to
	// propagate, and only then stop accepting connections.
	log.Info("shutdown signal received, draining")
	srv.StartDraining()
	time.Sleep(envDuration("DRAIN_DELAY", 5*time.Second))

	shutdownCtx, cancel := context.WithTimeout(context.Background(), envDuration("SHUTDOWN_TIMEOUT", 15*time.Second))
	defer cancel()

	var shutdownErr error
	for name, s := range map[string]*http.Server{"api": public, "ops": ops} {
		if err := s.Shutdown(shutdownCtx); err != nil {
			log.Error("graceful shutdown failed", slog.String("server", name), slog.Any("error", err))
			shutdownErr = err
		}
	}
	log.Info("shutdown complete")
	return shutdownErr
}

func serve(s *http.Server, name string, log *slog.Logger, errc chan<- error) {
	if err := s.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Error("listener stopped", slog.String("server", name), slog.Any("error", err))
		errc <- err
	}
}

// newHTTPServer applies the timeouts that keep a public listener from being
// held open by slow or abandoned clients.
func newHTTPServer(addr string, h http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
}

func newLogger(level, format string) *slog.Logger {
	var lvl slog.Level
	if err := lvl.UnmarshalText([]byte(level)); err != nil {
		lvl = slog.LevelInfo
	}
	opts := &slog.HandlerOptions{Level: lvl}
	if strings.EqualFold(format, "text") {
		return slog.New(slog.NewTextHandler(os.Stdout, opts))
	}
	return slog.New(slog.NewJSONHandler(os.Stdout, opts))
}

func env(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	v, err := strconv.Atoi(env(key, ""))
	if err != nil || v <= 0 {
		return def
	}
	return v
}

func envBool(key string, def bool) bool {
	v, err := strconv.ParseBool(env(key, ""))
	if err != nil {
		return def
	}
	return v
}

func envDuration(key string, def time.Duration) time.Duration {
	v, err := time.ParseDuration(env(key, ""))
	if err != nil || v < 0 {
		return def
	}
	return v
}
