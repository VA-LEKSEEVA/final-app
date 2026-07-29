package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	_ "github.com/lib/pq"
)

const (
	defaultMaxOpenConns    = 20
	defaultMaxIdleConns    = 5
	defaultConnMaxLifetime = 5 * time.Minute
	defaultConnMaxIdleTime = time.Minute
	defaultConnectTimeout  = 60 * time.Second
	retryInterval          = 2 * time.Second
	pingTimeout            = 3 * time.Second
)

// Connect opens a PostgreSQL connection pool and waits for the database to
// become available. It is kept for backwards compatibility; new callers
// should prefer ConnectContext so startup can be cancelled.
func Connect(dsn string) (*sql.DB, error) {
	ctx, cancel := context.WithTimeout(context.Background(), defaultConnectTimeout)
	defer cancel()

	return ConnectContext(ctx, dsn)
}

// ConnectContext opens and configures a PostgreSQL connection pool, retrying
// until the database responds or ctx is cancelled.
func ConnectContext(ctx context.Context, dsn string) (*sql.DB, error) {
	if ctx == nil {
		return nil, errors.New("database context is nil")
	}
	if strings.TrimSpace(dsn) == "" {
		return nil, errors.New("database DSN is empty")
	}

	database, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}

	database.SetMaxOpenConns(defaultMaxOpenConns)
	database.SetMaxIdleConns(defaultMaxIdleConns)
	database.SetConnMaxLifetime(defaultConnMaxLifetime)
	database.SetConnMaxIdleTime(defaultConnMaxIdleTime)

	var lastErr error
	for {
		attemptCtx, cancel := context.WithTimeout(ctx, pingTimeout)
		lastErr = database.PingContext(attemptCtx)
		cancel()
		if lastErr == nil {
			return database, nil
		}

		timer := time.NewTimer(retryInterval)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			_ = database.Close()
			return nil, fmt.Errorf("database not ready (last error: %v): %w", lastErr, ctx.Err())
		case <-timer.C:
		}
	}
}

// Migrate applies the database schema using a transaction.
func Migrate(database *sql.DB) error {
	return MigrateContext(context.Background(), database)
}

// MigrateContext applies the database schema using a transaction.
func MigrateContext(ctx context.Context, database *sql.DB) error {
	if database == nil {
		return errors.New("database is nil")
	}

	tx, err := database.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin migration: %w", err)
	}
	defer func() {
		_ = tx.Rollback()
	}()

	const schema = `
		CREATE TABLE IF NOT EXISTS messages (
			id SERIAL PRIMARY KEY,
			author TEXT NOT NULL,
			text TEXT NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
		CREATE INDEX IF NOT EXISTS idx_messages_created_at_id
			ON messages(created_at DESC, id DESC);
		DROP INDEX IF EXISTS idx_messages_created_at;
	`
	if _, err := tx.ExecContext(ctx, schema); err != nil {
		return fmt.Errorf("apply migration: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit migration: %w", err)
	}
	return nil
}
