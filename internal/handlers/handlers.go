package handlers

import (
    "database/sql"
    "encoding/json"
    "log/slog"
    "net/http"
    "strings"

    "github.com/VA-LEKSEEVA/final-app/internal/db"
    "github.com/VA-LEKSEEVA/final-app/internal/metrics"
)

// Server — структура, объединяющая зависимости (БД, логгер, статика)
type Server struct {
    DB     *sql.DB
    Log    *slog.Logger
    Static http.Handler // для раздачи статических файлов
}

// Routes — регистрирует все маршруты и оборачивает их в middleware
func (s *Server) Routes() http.Handler {
    mux := http.NewServeMux()

    // === API и хелсы ===
    mux.HandleFunc("GET /health", s.healthHandler)
    mux.HandleFunc("GET /api/messages", s.listMessages)
    mux.HandleFunc("POST /api/messages", s.createMessage)

    // === Статика ===
    mux.Handle("GET /static/", http.StripPrefix("/static/", s.Static))

    // === Index.html ===
    mux.HandleFunc("GET /{$}", s.serveIndex)

    // Оборачиваем в middleware (логирование + метрики)
    return MetricsMiddleware(LoggingMiddleware(s.Log, mux))
}

// healthHandler — проверяет БД и возвращает {"status":"ok"}
func (s *Server) healthHandler(w http.ResponseWriter, r *http.Request) {
    if err := s.DB.Ping(); err != nil {
        http.Error(w, "db unhealthy", http.StatusServiceUnavailable)
        return
    }
    w.Header().Set("Content-Type", "application/json")
    w.Write([]byte(`{"status":"ok"}`))
}

// serveIndex — отдаёт index.html из папки web/
func (s *Server) serveIndex(w http.ResponseWriter, r *http.Request) {
    http.ServeFile(w, r, "web/index.html")
}

// listMessages — GET /api/messages → JSON-список сообщений
func (s *Server) listMessages(w http.ResponseWriter, r *http.Request) {
    messages, err := db.ListMessages(s.DB)
    if err != nil {
        s.Log.Error("list messages failed", "err", err)
        http.Error(w, "internal error", http.StatusInternalServerError)
        return
    }
    // Если сообщений нет, возвращаем пустой массив (не null)
    if messages == nil {
        messages = []db.Message{}
    }
    // Обновляем метрику
    metrics.MessagesTotal.Set(float64(len(messages)))

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(messages)
}

// createMessage — POST /api/messages → создаёт сообщение
func (s *Server) createMessage(w http.ResponseWriter, r *http.Request) {
    var input struct {
        Author string `json:"author"`
        Text   string `json:"text"`
    }
    // Декодируем JSON из тела запроса
    if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
        http.Error(w, "invalid JSON", http.StatusBadRequest)
        return
    }

    // Очистка от пробелов по краям
    input.Author = strings.TrimSpace(input.Author)
    input.Text = strings.TrimSpace(input.Text)

    // Валидация
    if input.Author == "" || input.Text == "" {
        http.Error(w, "author and text required", http.StatusBadRequest)
        return
    }
    if len(input.Author) > 100 || len(input.Text) > 1000 {
        http.Error(w, "fields too long", http.StatusBadRequest)
        return
    }

    // Сохраняем в БД
    msg, err := db.CreateMessage(s.DB, input.Author, input.Text)
    if err != nil {
        s.Log.Error("create message failed", "err", err)
        http.Error(w, "internal error", http.StatusInternalServerError)
        return
    }

    // Возвращаем созданное сообщение с кодом 201 Created
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(http.StatusCreated)
    json.NewEncoder(w).Encode(msg)
}
