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

type Server struct {
	DB     *sql.DB
	Log    *slog.Logger
	Static http.Handler
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.healthHandler)
	mux.HandleFunc("GET /api/messages", s.listMessages)
	mux.HandleFunc("POST /api/messages", s.createMessage)
	mux.Handle("GET /static/", http.StripPrefix("/static/", s.Static))
	mux.HandleFunc("GET /{$}", s.serveIndex)
	return MetricsMiddleware(LoggingMiddleware(s.Log, mux))
}

func (s *Server) healthHandler(w http.ResponseWriter, r *http.Request) {
	if err := s.DB.Ping(); err != nil {
		http.Error(w, "db unhealthy", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, err := w.Write([]byte(`{"status":"ok"}`))
	if err != nil {
		s.Log.Error("failed to write health response", "err", err)
	}
}

func (s *Server) serveIndex(w http.ResponseWriter, r *http.Request) {
	http.ServeFile(w, r, "web/index.html")
}

func (s *Server) listMessages(w http.ResponseWriter, r *http.Request) {
	messages, err := db.ListMessages(s.DB)
	if err != nil {
		s.Log.Error("list messages failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if messages == nil {
		messages = []db.Message{}
	}
	metrics.MessagesTotal.Set(float64(len(messages)))
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(messages); err != nil {
		s.Log.Error("failed to encode messages", "err", err)
	}
}

func (s *Server) createMessage(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Author string `json:"author"`
		Text   string `json:"text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	input.Author = strings.TrimSpace(input.Author)
	input.Text = strings.TrimSpace(input.Text)
	if input.Author == "" || input.Text == "" {
		http.Error(w, "author and text required", http.StatusBadRequest)
		return
	}
	if len(input.Author) > 100 || len(input.Text) > 1000 {
		http.Error(w, "fields too long", http.StatusBadRequest)
		return
	}
	msg, err := db.CreateMessage(s.DB, input.Author, input.Text)
	if err != nil {
		s.Log.Error("create message failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	if err := json.NewEncoder(w).Encode(msg); err != nil {
		s.Log.Error("failed to encode created message", "err", err)
	}
}
