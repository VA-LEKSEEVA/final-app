package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestLoadConfig(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://example")
	t.Setenv("STARTUP_TIMEOUT", "5s")
	t.Setenv("HTTP_IDLE_TIMEOUT", "2m")

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig() error = %v", err)
	}
	if cfg.DatabaseURL != "postgres://example" {
		t.Fatalf("DatabaseURL = %q", cfg.DatabaseURL)
	}
	if cfg.StartupTimeout != 5*time.Second {
		t.Fatalf("StartupTimeout = %v", cfg.StartupTimeout)
	}
	if cfg.IdleTimeout != 2*time.Minute {
		t.Fatalf("IdleTimeout = %v", cfg.IdleTimeout)
	}
}

func TestLoadConfigRequiresDatabaseURL(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	t.Setenv("DB_HOST", "")
	if _, err := loadConfig(); err == nil {
		t.Fatal("loadConfig() error = nil, want error")
	}
}

func TestLoadConfigFromDBEnvironment(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	t.Setenv("DB_HOST", "db")
	t.Setenv("DB_PORT", "5433")
	t.Setenv("DB_USER", "user@example")
	t.Setenv("DB_PASSWORD", "p@ss:/word")
	t.Setenv("DB_NAME", "guest book")
	t.Setenv("DB_SSLMODE", "require")

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig() error = %v", err)
	}
	for _, part := range []string{
		"postgres://user%40example:p%40ss%3A%2Fword@db:5433/guest%20book",
		"sslmode=require",
	} {
		if !strings.Contains(cfg.DatabaseURL, part) {
			t.Fatalf("DatabaseURL = %q, want part %q", cfg.DatabaseURL, part)
		}
	}
}

func TestLoadConfigRejectsInvalidAddresses(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://example")
	t.Setenv("LISTEN_ADDR", "localhost")
	if _, err := loadConfig(); err == nil {
		t.Fatal("loadConfig() accepted LISTEN_ADDR without a port")
	}

	t.Setenv("LISTEN_ADDR", ":8080")
	t.Setenv("DATABASE_URL", "")
	t.Setenv("DB_HOST", "db")
	t.Setenv("DB_PORT", "70000")
	t.Setenv("DB_USER", "app")
	t.Setenv("DB_NAME", "guestbook")
	if _, err := loadConfig(); err == nil {
		t.Fatal("loadConfig() accepted invalid DB_PORT")
	}
}

func TestDurationFromEnv(t *testing.T) {
	t.Setenv("TEST_DURATION", "invalid")
	if _, err := durationFromEnv("TEST_DURATION", time.Second); err == nil {
		t.Fatal("durationFromEnv() error = nil, want error")
	}

	t.Setenv("TEST_DURATION", "0s")
	if _, err := durationFromEnv("TEST_DURATION", time.Second); err == nil {
		t.Fatal("durationFromEnv() accepted zero duration")
	}
}

func TestParseMode(t *testing.T) {
	got, err := parseMode([]string{"-healthcheck"})
	if err != nil {
		t.Fatalf("parseMode() error = %v", err)
	}
	if !got.Healthcheck {
		t.Fatal("Healthcheck = false")
	}

	if _, err := parseMode([]string{"unexpected"}); err == nil {
		t.Fatal("parseMode() error = nil for positional argument")
	}
}

func TestHealthcheckURL(t *testing.T) {
	tests := map[string]string{
		":8080":          "http://127.0.0.1:8080/readyz",
		"0.0.0.0:9000":   "http://127.0.0.1:9000/readyz",
		"127.0.0.1:7000": "http://127.0.0.1:7000/readyz",
		"[::]:8000":      "http://127.0.0.1:8000/readyz",
		"[::1]:8000":     "http://[::1]:8000/readyz",
	}
	for input, want := range tests {
		if got := healthcheckURL(input); got != want {
			t.Errorf("healthcheckURL(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestMainVersionModeDoesNotRequireDatabase(t *testing.T) {
	oldArgs := os.Args
	os.Args = []string{"guestbook", "-version"}
	defer func() { os.Args = oldArgs }()

	if code := run(); code != 0 {
		t.Fatalf("run() = %d, want 0", code)
	}
}
