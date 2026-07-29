package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/VA-LEKSEEVA/final-app/internal/db"
	"github.com/VA-LEKSEEVA/final-app/internal/handlers"
	"github.com/VA-LEKSEEVA/final-app/internal/metrics"
)

const (
	defaultListenAddr      = ":8080"
	defaultStartupTimeout  = 60 * time.Second
	defaultShutdownTimeout = 10 * time.Second
)

var (
	version   = "dev"
	commit    = "unknown"
	buildDate = "unknown"
)

func main() {
	os.Exit(run())
}

func run() int {
	log := newLogger()
	mode, err := parseMode(os.Args[1:])
	if err != nil {
		log.Error("invalid arguments", "err", err)
		return 2
	}
	if mode.ShowVersion {
		fmt.Printf("guestbook %s (commit %s, built %s)\n", version, commit, buildDate)
		return 0
	}
	if mode.Healthcheck {
		return runHealthcheck(log)
	}

	cfg, err := loadConfig()
	if err != nil {
		log.Error("invalid configuration", "err", err)
		return 1
	}

	appCtx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	startupCtx, cancelStartup := context.WithTimeout(appCtx, cfg.StartupTimeout)
	defer cancelStartup()
	database, err := db.ConnectContext(startupCtx, cfg.DatabaseURL)
	if err != nil {
		log.Error("db connection failed", "err", err)
		return 1
	}
	defer database.Close()

	if err := db.MigrateContext(startupCtx, database); err != nil {
		log.Error("migration failed", "err", err)
		return 1
	}
	if count, err := db.CountMessagesContext(startupCtx, database); err != nil {
		log.Warn("initial message count failed", "err", err)
	} else {
		metrics.MessagesTotal.Set(float64(count))
	}
	cancelStartup()

	static := http.FileServer(http.Dir("web/static"))
	server := &handlers.Server{
		DB:     database,
		Log:    log,
		Static: static,
	}
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	mux.Handle("/", server.Routes())

	httpServer := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           mux,
		ReadHeaderTimeout: cfg.ReadHeaderTimeout,
		ReadTimeout:       cfg.ReadTimeout,
		WriteTimeout:      cfg.WriteTimeout,
		IdleTimeout:       cfg.IdleTimeout,
		MaxHeaderBytes:    1 << 20,
		ErrorLog:          slog.NewLogLogger(log.Handler(), slog.LevelError),
	}

	serverErr := make(chan error, 1)
	go func() {
		log.Info("server starting", "addr", cfg.ListenAddr)
		serverErr <- httpServer.ListenAndServe()
	}()

	select {
	case err := <-serverErr:
		if !errors.Is(err, http.ErrServerClosed) {
			log.Error("server failed", "err", err)
			return 1
		}
		return 0
	case <-appCtx.Done():
	}

	log.Info("shutting down gracefully")
	shutdownCtx, cancelShutdown := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancelShutdown()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", "err", err)
		if closeErr := httpServer.Close(); closeErr != nil {
			log.Error("forced server close failed", "err", closeErr)
		}
		return 1
	}

	log.Info("bye")
	return 0
}

type config struct {
	DatabaseURL       string
	ListenAddr        string
	StartupTimeout    time.Duration
	ShutdownTimeout   time.Duration
	ReadHeaderTimeout time.Duration
	ReadTimeout       time.Duration
	WriteTimeout      time.Duration
	IdleTimeout       time.Duration
}

func loadConfig() (config, error) {
	databaseURL, err := databaseURLFromEnv()
	if err != nil {
		return config{}, err
	}

	cfg := config{
		DatabaseURL:       databaseURL,
		ListenAddr:        strings.TrimSpace(envOrDefault("LISTEN_ADDR", defaultListenAddr)),
		StartupTimeout:    defaultStartupTimeout,
		ShutdownTimeout:   defaultShutdownTimeout,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	if err := validateListenAddr(cfg.ListenAddr); err != nil {
		return config{}, err
	}

	if cfg.StartupTimeout, err = durationFromEnv("STARTUP_TIMEOUT", cfg.StartupTimeout); err != nil {
		return config{}, err
	}
	if cfg.ShutdownTimeout, err = durationFromEnv("SHUTDOWN_TIMEOUT", cfg.ShutdownTimeout); err != nil {
		return config{}, err
	}
	if cfg.ReadHeaderTimeout, err = durationFromEnv("HTTP_READ_HEADER_TIMEOUT", cfg.ReadHeaderTimeout); err != nil {
		return config{}, err
	}
	if cfg.ReadTimeout, err = durationFromEnv("HTTP_READ_TIMEOUT", cfg.ReadTimeout); err != nil {
		return config{}, err
	}
	if cfg.WriteTimeout, err = durationFromEnv("HTTP_WRITE_TIMEOUT", cfg.WriteTimeout); err != nil {
		return config{}, err
	}
	if cfg.IdleTimeout, err = durationFromEnv("HTTP_IDLE_TIMEOUT", cfg.IdleTimeout); err != nil {
		return config{}, err
	}
	return cfg, nil
}

func databaseURLFromEnv() (string, error) {
	if value := strings.TrimSpace(os.Getenv("DATABASE_URL")); value != "" {
		return value, nil
	}

	host := strings.TrimSpace(os.Getenv("DB_HOST"))
	if host == "" {
		return "", errors.New("DATABASE_URL or DB_HOST is required")
	}

	port := strings.TrimSpace(envOrDefault("DB_PORT", "5432"))
	if err := validatePort("DB_PORT", port); err != nil {
		return "", err
	}

	user := os.Getenv("DB_USER")
	name := strings.TrimSpace(os.Getenv("DB_NAME"))
	if strings.TrimSpace(user) == "" {
		return "", errors.New("DB_USER is required when DATABASE_URL is not set")
	}
	if name == "" {
		return "", errors.New("DB_NAME is required when DATABASE_URL is not set")
	}

	sslMode := strings.TrimSpace(envOrDefault("DB_SSLMODE", "disable"))
	if sslMode == "" {
		return "", errors.New("DB_SSLMODE must not be empty")
	}

	databaseURL := &url.URL{
		Scheme: "postgres",
		User:   url.UserPassword(user, os.Getenv("DB_PASSWORD")),
		Host:   net.JoinHostPort(host, port),
		Path:   "/" + name,
	}
	query := databaseURL.Query()
	query.Set("sslmode", sslMode)
	databaseURL.RawQuery = query.Encode()
	return databaseURL.String(), nil
}

func validateListenAddr(addr string) error {
	if addr == "" {
		return errors.New("LISTEN_ADDR must not be empty")
	}
	_, port, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("LISTEN_ADDR must be host:port: %w", err)
	}
	return validatePort("LISTEN_ADDR port", port)
}

func validatePort(name, value string) error {
	port, err := strconv.Atoi(value)
	if err != nil || port < 1 || port > 65535 {
		return fmt.Errorf("%s must be an integer from 1 to 65535", name)
	}
	return nil
}

func durationFromEnv(name string, fallback time.Duration) (time.Duration, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback, nil
	}
	duration, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("%s must be a Go duration: %w", name, err)
	}
	if duration <= 0 {
		return 0, fmt.Errorf("%s must be positive", name)
	}
	return duration, nil
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func newLogger() *slog.Logger {
	level := slog.LevelInfo
	if raw := os.Getenv("LOG_LEVEL"); raw != "" {
		if err := level.UnmarshalText([]byte(raw)); err != nil {
			if parsed, parseErr := strconv.Atoi(raw); parseErr == nil {
				level = slog.Level(parsed)
			} else {
				fmt.Fprintf(os.Stderr, "invalid LOG_LEVEL %q; using INFO\n", raw)
			}
		}
	}
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level}))
}

type mode struct {
	Healthcheck bool
	ShowVersion bool
}

func parseMode(args []string) (mode, error) {
	flags := flag.NewFlagSet("guestbook", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	var result mode
	flags.BoolVar(&result.Healthcheck, "healthcheck", false, "check the local HTTP readiness endpoint")
	flags.BoolVar(&result.ShowVersion, "version", false, "print build version")
	if err := flags.Parse(args); err != nil {
		return mode{}, err
	}
	if flags.NArg() != 0 {
		return mode{}, fmt.Errorf("unexpected arguments: %v", flags.Args())
	}
	return result, nil
}

func runHealthcheck(log *slog.Logger) int {
	addr := envOrDefault("LISTEN_ADDR", defaultListenAddr)
	url := healthcheckURL(addr)
	client := &http.Client{Timeout: 2 * time.Second}
	response, err := client.Get(url)
	if err != nil {
		log.Error("healthcheck request failed", "url", url, "err", err)
		return 1
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		log.Error("healthcheck failed", "url", url, "status", response.StatusCode)
		return 1
	}
	return 0
}

func healthcheckURL(addr string) string {
	if addr == "" {
		addr = defaultListenAddr
	}
	host := addr
	if hostName, port, err := net.SplitHostPort(addr); err == nil {
		if hostName == "" || hostName == "0.0.0.0" || hostName == "::" {
			hostName = "127.0.0.1"
		}
		host = net.JoinHostPort(hostName, port)
	} else if addr[0] == ':' {
		host = "127.0.0.1" + addr
	}
	return "http://" + host + "/readyz"
}
