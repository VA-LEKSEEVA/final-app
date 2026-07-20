package handlers

import (
    "log/slog"
    "net/http"
    "strconv"
    "time"

    "github.com/VA-LEKSEEVA/final-app/internal/metrics"
)

// statusWriter — обёртка над ResponseWriter, чтобы запоминать HTTP-статус
type statusWriter struct {
    http.ResponseWriter
    status int
}

func (w *statusWriter) WriteHeader(code int) {
    w.status = code
    w.ResponseWriter.WriteHeader(code)
}

// LoggingMiddleware — логирует каждый запрос: метод, путь, статус, длительность
func LoggingMiddleware(log *slog.Logger, next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        sw := &statusWriter{ResponseWriter: w, status: 200}
        next.ServeHTTP(sw, r)
        log.Info("http",
            "method", r.Method,
            "path", r.URL.Path,
            "status", sw.status,
            "duration", time.Since(start),
        )
    })
}

// MetricsMiddleware — собирает Prometheus метрики для каждого запроса
func MetricsMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        sw := &statusWriter{ResponseWriter: w, status: 200}
        next.ServeHTTP(sw, r)

        metrics.HTTPRequestsTotal.WithLabelValues(
            r.Method,
            r.URL.Path,
            strconv.Itoa(sw.status),
        ).Inc()

        metrics.HTTPRequestDuration.WithLabelValues(
            r.Method,
            r.URL.Path,
        ).Observe(time.Since(start).Seconds())
    })
}
