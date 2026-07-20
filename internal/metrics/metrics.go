package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	// HTTPRequestsTotal — счётчик запросов (method, path, status)
	HTTPRequestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total HTTP requests",
		},
		[]string{"method", "path", "status"},
	)

	// HTTPRequestDuration — гистограмма длительности запросов
	HTTPRequestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request duration in seconds",
			Buckets: prometheus.DefBuckets, // стандартные бакеты [0.005, 0.01, 0.025, ...]
		},
		[]string{"method", "path"},
	)

	// MessagesTotal — текущее количество сообщений в БД (gauge)
	MessagesTotal = promauto.NewGauge(
		prometheus.GaugeOpts{
			Name: "guestbook_messages_total",
			Help: "Total messages in DB",
		},
	)
)
