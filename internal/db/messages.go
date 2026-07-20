package db

import (
    "database/sql"
    "time"
)

// Message — модель сообщения (соответствует таблице messages)
type Message struct {
    ID        int       `json:"id"`
    Author    string    `json:"author"`
    Text      string    `json:"text"`
    CreatedAt time.Time `json:"created_at"`
}

// ListMessages возвращает последние 100 сообщений (по убыванию даты)
func ListMessages(db *sql.DB) ([]Message, error) {
    rows, err := db.Query(`
        SELECT id, author, text, created_at
        FROM messages
        ORDER BY created_at DESC
        LIMIT 100
    `)
    if err != nil {
        return nil, err
    }
    defer rows.Close() // обязательно закрываем, чтобы освободить соединение

    var messages []Message
    for rows.Next() {
        var m Message
        if err := rows.Scan(&m.ID, &m.Author, &m.Text, &m.CreatedAt); err != nil {
            return nil, err
        }
        messages = append(messages, m)
    }
    return messages, nil
}

// CreateMessage добавляет новое сообщение и возвращает его с заполненными полями (id, created_at)
func CreateMessage(db *sql.DB, author, text string) (*Message, error) {
    var m Message
    err := db.QueryRow(`
        INSERT INTO messages (author, text)
        VALUES ($1, $2)
        RETURNING id, author, text, created_at
    `, author, text).Scan(&m.ID, &m.Author, &m.Text, &m.CreatedAt)
    if err != nil {
        return nil, err
    }
    return &m, nil
}
