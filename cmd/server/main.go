package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/VA-LEKSEEVA/final-app/internal/db"
	"github.com/VA-LEKSEEVA/final-app/internal/handlers"
)

func main() {
	// Настройка JSON-логгера
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	// Читаем DATABASE_URL из окружения (обязательно)
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		log.Error("DATABASE_URL is required")
		os.Exit(1)
	}

	// Подключение к БД (с ретраями)
	database, err := db.Connect(dsn)
	if err != nil {
		log.Error("db connection failed", "err", err)
		os.Exit(1)
	}
	defer database.Close()

	// Миграция (создание таблицы, если её нет)
	if err := db.Migrate(database); err != nil {
		log.Error("migration failed", "err", err)
		os.Exit(1)
	}

	// HTTP-обработчик для статических файлов (из папки web/static)
	static := http.FileServer(http.Dir("web/static"))

	// Создаём сервер с зависимостями
	server := &handlers.Server{
		DB:     database,
		Log:    log,
		Static: static,
	}

	// Основной маршрутизатор
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler()) // метрики Prometheus
	mux.Handle("/", server.Routes())           // все остальные маршруты

	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	httpServer := &http.Server{
		Addr:    addr,
		Handler: mux,
	}

	// Запускаем сервер в горутине (чтобы не блокировать graceful shutdown)
	go func() {
		log.Info("server starting", "addr", addr)
		if err := httpServer.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
			log.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()

	// Ожидаем сигналы SIGINT (Ctrl+C) и SIGTERM (k8s)
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh

	log.Info("shutting down gracefully")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Даём 10 секунд на завершение текущих запросов
	httpServer.Shutdown(ctx)
	log.Info("bye")
}
