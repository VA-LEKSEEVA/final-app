package db

import (
    "database/sql"
    "fmt"
    "time"
    
    _ "github.com/lib/pq" // драйвер PostgreSQL (инициализируется автоматически)
)

// Connect устанавливает соединение с БД и выполняет ретраи
func Connect(dsn string) (*sql.DB, error) {
    db, err := sql.Open("postgres", dsn)
    if err != nil {
        return nil, err
    }

    // Настройка пула соединений (важно для производительности)
    db.SetMaxOpenConns(20)          // максимум открытых соединений
    db.SetMaxIdleConns(5)           // максимум простаивающих
    db.SetConnMaxLifetime(5 * time.Minute) // время жизни соединения

    // Ретраи на старте — ждём, пока БД поднимется (до 60 секунд)
    for i := 0; i < 30; i++ {
        if err := db.Ping(); err == nil {
            return db, nil
        }
        time.Sleep(2 * time.Second)
    }
    return nil, fmt.Errorf("database not ready after 60 seconds")
}

// Migrate создаёт таблицу messages и индекс, если их нет
func Migrate(db *sql.DB) error {
    schema := `
        CREATE TABLE IF NOT EXISTS messages (
            id SERIAL PRIMARY KEY,
            author TEXT NOT NULL,
            text TEXT NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(created_at DESC);
    `
    _, err := db.Exec(schema)
    return err
}
