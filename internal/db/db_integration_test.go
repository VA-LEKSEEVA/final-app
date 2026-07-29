package db

import (
	"context"
	"database/sql"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	_ "github.com/lib/pq"
)

func TestPostgresMessageLifecycle(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL is not set")
	}

	database, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	t.Cleanup(func() { _ = database.Close() })
	database.SetMaxOpenConns(1)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := database.PingContext(ctx); err != nil {
		t.Fatalf("ping database: %v", err)
	}

	schema := "test_" + strconv.FormatInt(time.Now().UnixNano(), 10)
	if _, err := database.ExecContext(ctx, `CREATE SCHEMA `+schema); err != nil {
		t.Fatalf("create schema: %v", err)
	}
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cleanupCancel()
		_, _ = database.ExecContext(cleanupCtx, `DROP SCHEMA `+schema+` CASCADE`)
	})
	if _, err := database.ExecContext(ctx, `SET search_path TO `+schema); err != nil {
		t.Fatalf("set search path: %v", err)
	}

	if err := MigrateContext(ctx, database); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	// Migrations must be safe to run more than once.
	if err := MigrateContext(ctx, database); err != nil {
		t.Fatalf("repeat migration: %v", err)
	}

	if count, err := CountMessagesContext(ctx, database); err != nil || count != 0 {
		t.Fatalf("initial count = %d, err = %v; want 0", count, err)
	}

	first, err := CreateMessageContext(ctx, database, "Анна", "Первое")
	if err != nil {
		t.Fatalf("create first message: %v", err)
	}
	second, err := CreateMessageContext(ctx, database, "Борис", "Второе")
	if err != nil {
		t.Fatalf("create second message: %v", err)
	}
	if first.ID == 0 || second.ID <= first.ID {
		t.Fatalf("unexpected IDs: first=%d second=%d", first.ID, second.ID)
	}
	if first.CreatedAt.IsZero() || second.CreatedAt.IsZero() {
		t.Fatal("created_at was not populated")
	}

	messages, err := ListMessagesContext(ctx, database)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	if len(messages) != 2 {
		t.Fatalf("message count = %d, want 2", len(messages))
	}
	if messages[0].ID != second.ID || messages[1].ID != first.ID {
		t.Fatalf("messages are not newest-first: IDs=%v", []int{messages[0].ID, messages[1].ID})
	}
	if count, err := CountMessagesContext(ctx, database); err != nil || count != 2 {
		t.Fatalf("count = %d, err = %v; want 2", count, err)
	}
}

func TestPostgresListLimitAndDeterministicOrder(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL is not set")
	}

	database, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	t.Cleanup(func() { _ = database.Close() })
	database.SetMaxOpenConns(1)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	schema := "test_" + strconv.FormatInt(time.Now().UnixNano(), 10)
	if _, err := database.ExecContext(ctx, `CREATE SCHEMA `+schema); err != nil {
		t.Fatalf("create schema: %v", err)
	}
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cleanupCancel()
		_, _ = database.ExecContext(cleanupCtx, `DROP SCHEMA `+schema+` CASCADE`)
	})
	if _, err := database.ExecContext(ctx, `SET search_path TO `+schema); err != nil {
		t.Fatalf("set search path: %v", err)
	}
	if err := MigrateContext(ctx, database); err != nil {
		t.Fatalf("migrate database: %v", err)
	}

	const total = messagesLimit + 5
	values := make([]string, 0, total)
	args := make([]any, 0, total*2)
	for i := 0; i < total; i++ {
		position := i*2 + 1
		values = append(values, `($`+strconv.Itoa(position)+`, $`+strconv.Itoa(position+1)+`, TIMESTAMPTZ '2026-01-01T00:00:00Z')`)
		args = append(args, "author", "message")
	}
	query := `INSERT INTO messages (author, text, created_at) VALUES ` + strings.Join(values, ",")
	if _, err := database.ExecContext(ctx, query, args...); err != nil {
		t.Fatalf("seed messages: %v", err)
	}

	messages, err := ListMessagesContext(ctx, database)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	if len(messages) != messagesLimit {
		t.Fatalf("message count = %d, want %d", len(messages), messagesLimit)
	}
	for i := 1; i < len(messages); i++ {
		if messages[i-1].ID <= messages[i].ID {
			t.Fatalf("IDs not descending at %d: %d <= %d", i, messages[i-1].ID, messages[i].ID)
		}
	}
}
