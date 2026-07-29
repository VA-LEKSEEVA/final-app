package handlers

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/VA-LEKSEEVA/final-app/internal/db"
	"github.com/VA-LEKSEEVA/final-app/internal/metrics"
)

const (
	maxAuthorLength = 100
	maxTextLength   = 1000
	maxRequestBody  = 16 << 10
	dbTimeout       = 3 * time.Second
)

var errMultipleJSONValues = errors.New("multiple JSON values")

type Server struct {
	DB     *sql.DB
	Log    *slog.Logger
	Static http.Handler
	Index  string
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.livenessHandler)
	mux.HandleFunc("GET /readyz", s.readinessHandler)
	mux.HandleFunc("GET /health", s.readinessHandler)
	mux.HandleFunc("GET /api/messages", s.listMessages)
	mux.HandleFunc("POST /api/messages", s.createMessage)
	if s.Static != nil {
		mux.Handle("GET /static/", http.StripPrefix("/static/", s.Static))
	}
	mux.HandleFunc("GET /{$}", s.serveIndex)

	log := s.Log
	if log == nil {
		log = slog.Default()
	}
	return MetricsMiddleware(LoggingMiddleware(log, RecoveryMiddleware(log, SecurityHeadersMiddleware(mux))))
}

func (s *Server) livenessHandler(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) readinessHandler(w http.ResponseWriter, r *http.Request) {
	if s.DB == nil {
		writeError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), dbTimeout)
	defer cancel()
	if err := s.DB.PingContext(ctx); err != nil {
		s.logger().Warn("readiness check failed", "err", err)
		writeError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) serveIndex(w http.ResponseWriter, r *http.Request) {
	index := s.Index
	if index == "" {
		index = "web/index.html"
	}
	http.ServeFile(w, r, index)
}

func (s *Server) listMessages(w http.ResponseWriter, r *http.Request) {
	if s.DB == nil {
		writeError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), dbTimeout)
	defer cancel()
	messages, err := db.ListMessagesContext(ctx, s.DB)
	if err != nil {
		s.logger().Error("list messages failed", "err", err)
		writeDatabaseError(w, err)
		return
	}

	if count, err := db.CountMessagesContext(ctx, s.DB); err == nil {
		metrics.MessagesTotal.Set(float64(count))
	} else {
		s.logger().Warn("count messages failed", "err", err)
	}
	writeJSON(w, http.StatusOK, messages)
}

func (s *Server) createMessage(w http.ResponseWriter, r *http.Request) {
	if s.DB == nil {
		writeError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	if contentType := r.Header.Get("Content-Type"); contentType != "" {
		mediaType, _, err := mime.ParseMediaType(contentType)
		if err != nil || mediaType != "application/json" {
			writeError(w, http.StatusUnsupportedMediaType, "Content-Type must be application/json")
			return
		}
	}

	var input struct {
		Author string `json:"author"`
		Text   string `json:"text"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBody)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		s.handleDecodeError(w, err)
		return
	}
	if err := ensureSingleJSONValue(decoder); err != nil {
		s.handleDecodeError(w, err)
		return
	}

	input.Author = strings.TrimSpace(input.Author)
	input.Text = strings.TrimSpace(input.Text)
	if input.Author == "" || input.Text == "" {
		writeError(w, http.StatusBadRequest, "author and text are required")
		return
	}
	if !utf8.ValidString(input.Author) || !utf8.ValidString(input.Text) {
		writeError(w, http.StatusBadRequest, "author and text must be valid UTF-8")
		return
	}
	if strings.ContainsRune(input.Author, '\x00') || strings.ContainsRune(input.Text, '\x00') {
		writeError(w, http.StatusBadRequest, "author and text contain unsupported characters")
		return
	}
	if utf8.RuneCountInString(input.Author) > maxAuthorLength ||
		utf8.RuneCountInString(input.Text) > maxTextLength {
		writeError(w, http.StatusBadRequest, "fields are too long")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), dbTimeout)
	defer cancel()
	msg, err := db.CreateMessageContext(ctx, s.DB, input.Author, input.Text)
	if err != nil {
		s.logger().Error("create message failed", "err", err)
		writeDatabaseError(w, err)
		return
	}

	if count, err := db.CountMessagesContext(ctx, s.DB); err == nil {
		metrics.MessagesTotal.Set(float64(count))
	} else {
		s.logger().Warn("count messages after create failed", "err", err)
	}
	writeJSON(w, http.StatusCreated, msg)
}

func (s *Server) handleDecodeError(w http.ResponseWriter, err error) {
	var maxBytesErr *http.MaxBytesError
	switch {
	case errors.As(err, &maxBytesErr):
		writeError(w, http.StatusRequestEntityTooLarge, "request body is too large")
	case errors.Is(err, io.EOF):
		writeError(w, http.StatusBadRequest, "request body is required")
	case errors.Is(err, errMultipleJSONValues):
		writeError(w, http.StatusBadRequest, "request body must contain one JSON object")
	default:
		writeError(w, http.StatusBadRequest, "invalid JSON")
	}
}

func ensureSingleJSONValue(decoder *json.Decoder) error {
	var extra any
	err := decoder.Decode(&extra)
	if errors.Is(err, io.EOF) {
		return nil
	}
	if err == nil {
		return errMultipleJSONValues
	}
	return err
}

func (s *Server) logger() *slog.Logger {
	if s.Log != nil {
		return s.Log
	}
	return slog.Default()
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func writeDatabaseError(w http.ResponseWriter, err error) {
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		writeError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	writeError(w, http.StatusInternalServerError, "internal error")
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	var body strings.Builder
	if err := json.NewEncoder(&body).Encode(value); err != nil {
		slog.Default().Error("failed to encode JSON response", "err", err)
		http.Error(w, http.StatusText(http.StatusInternalServerError), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if _, err := io.WriteString(w, body.String()); err != nil {
		slog.Default().Error("failed to write JSON response", "err", err)
	}
}
