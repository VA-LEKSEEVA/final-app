package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

const messagesLimit = 100

// Message is a guestbook entry.
type Message struct {
	ID        int       `json:"id"`
	Author    string    `json:"author"`
	Text      string    `json:"text"`
	CreatedAt time.Time `json:"created_at"`
}

// ListMessages returns the newest 100 messages.
func ListMessages(database *sql.DB) ([]Message, error) {
	return ListMessagesContext(context.Background(), database)
}

// ListMessagesContext returns the newest 100 messages. ID is used as a
// deterministic tie-breaker for entries created at the same instant.
func ListMessagesContext(ctx context.Context, database *sql.DB) ([]Message, error) {
	if database == nil {
		return nil, errors.New("database is nil")
	}

	rows, err := database.QueryContext(ctx, `
		SELECT id, author, text, created_at
		FROM messages
		ORDER BY created_at DESC, id DESC
		LIMIT $1
	`, messagesLimit)
	if err != nil {
		return nil, fmt.Errorf("query messages: %w", err)
	}
	defer rows.Close()

	messages := make([]Message, 0)
	for rows.Next() {
		var m Message
		if err := rows.Scan(&m.ID, &m.Author, &m.Text, &m.CreatedAt); err != nil {
			return nil, fmt.Errorf("scan message: %w", err)
		}
		messages = append(messages, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate messages: %w", err)
	}
	return messages, nil
}

// CreateMessage inserts a message and returns the persisted record.
func CreateMessage(database *sql.DB, author, text string) (*Message, error) {
	return CreateMessageContext(context.Background(), database, author, text)
}

// CreateMessageContext inserts a message and returns the persisted record.
func CreateMessageContext(ctx context.Context, database *sql.DB, author, text string) (*Message, error) {
	if database == nil {
		return nil, errors.New("database is nil")
	}

	var m Message
	err := database.QueryRowContext(ctx, `
		INSERT INTO messages (author, text)
		VALUES ($1, $2)
		RETURNING id, author, text, created_at
	`, author, text).Scan(&m.ID, &m.Author, &m.Text, &m.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("insert message: %w", err)
	}
	return &m, nil
}

// CountMessagesContext returns the total number of persisted messages.
func CountMessagesContext(ctx context.Context, database *sql.DB) (int64, error) {
	if database == nil {
		return 0, errors.New("database is nil")
	}

	var count int64
	if err := database.QueryRowContext(ctx, `SELECT COUNT(*) FROM messages`).Scan(&count); err != nil {
		return 0, fmt.Errorf("count messages: %w", err)
	}
	return count, nil
}
