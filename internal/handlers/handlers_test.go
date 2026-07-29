package handlers

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/VA-LEKSEEVA/final-app/internal/db"
)

func TestCreateMessageValidation(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		body   string
		status int
		error  string
	}{
		{name: "empty body", body: "", status: http.StatusBadRequest, error: "request body is required"},
		{name: "invalid JSON", body: `{`, status: http.StatusBadRequest, error: "invalid JSON"},
		{name: "unknown field", body: `{"author":"A","text":"B","admin":true}`, status: http.StatusBadRequest, error: "invalid JSON"},
		{name: "multiple values", body: `{"author":"A","text":"B"} {}`, status: http.StatusBadRequest, error: "request body must contain one JSON object"},
		{name: "blank author", body: `{"author":"  ","text":"B"}`, status: http.StatusBadRequest, error: "author and text are required"},
		{name: "long author by runes", body: `{"author":"` + strings.Repeat("я", 101) + `","text":"B"}`, status: http.StatusBadRequest, error: "fields are too long"},
		{name: "long text by runes", body: `{"author":"A","text":"` + strings.Repeat("я", 1001) + `"}`, status: http.StatusBadRequest, error: "fields are too long"},
	}

	server := &Server{DB: &sql.DB{}, Log: discardLogger()}
	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			request := httptest.NewRequest(http.MethodPost, "/api/messages", strings.NewReader(tt.body))
			response := httptest.NewRecorder()

			server.createMessage(response, request)

			if response.Code != tt.status {
				t.Fatalf("status = %d, want %d; body=%s", response.Code, tt.status, response.Body.String())
			}
			var payload map[string]string
			if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
				t.Fatalf("decode response: %v", err)
			}
			if payload["error"] != tt.error {
				t.Fatalf("error = %q, want %q", payload["error"], tt.error)
			}
			if got := response.Header().Get("Content-Type"); got != "application/json; charset=utf-8" {
				t.Fatalf("content type = %q", got)
			}
		})
	}
}

func TestCreateMessageRejectsUnsupportedContentType(t *testing.T) {
	t.Parallel()

	server := &Server{DB: &sql.DB{}, Log: discardLogger()}
	request := httptest.NewRequest(http.MethodPost, "/api/messages", strings.NewReader(`{"author":"A","text":"B"}`))
	request.Header.Set("Content-Type", "text/plain")
	response := httptest.NewRecorder()

	server.createMessage(response, request)

	if response.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("status = %d, want %d; body=%s", response.Code, http.StatusUnsupportedMediaType, response.Body.String())
	}
}

func TestCreateMessageRejectsLargeBody(t *testing.T) {
	t.Parallel()

	server := &Server{DB: &sql.DB{}, Log: discardLogger()}
	body := `{"author":"A","text":"` + strings.Repeat("x", maxRequestBody) + `"}`
	request := httptest.NewRequest(
		http.MethodPost,
		"/api/messages",
		bytes.NewReader([]byte(body)),
	)
	response := httptest.NewRecorder()

	server.createMessage(response, request)

	if response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want %d; body=%s", response.Code, http.StatusRequestEntityTooLarge, response.Body.String())
	}
}

func TestRoutesHealthAndSecurity(t *testing.T) {
	t.Parallel()

	server := &Server{Log: discardLogger()}
	request := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	response := httptest.NewRecorder()

	server.Routes().ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}
	if got := response.Header().Get("X-Content-Type-Options"); got != "nosniff" {
		t.Fatalf("X-Content-Type-Options = %q", got)
	}
	if got := response.Header().Get("Content-Security-Policy"); got == "" {
		t.Fatal("Content-Security-Policy is missing")
	}
}

func TestReadinessWithoutDatabase(t *testing.T) {
	t.Parallel()

	server := &Server{Log: discardLogger()}
	request := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	response := httptest.NewRecorder()

	server.Routes().ServeHTTP(response, request)

	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusServiceUnavailable)
	}
}

func TestRecoveryMiddleware(t *testing.T) {
	t.Parallel()

	next := http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic("boom")
	})
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	response := httptest.NewRecorder()

	RecoveryMiddleware(discardLogger(), next).ServeHTTP(response, request)

	if response.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusInternalServerError)
	}
}

func TestRecoveryDoesNotOverwriteStartedResponse(t *testing.T) {
	t.Parallel()

	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte("started"))
		panic("boom")
	})
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	response := httptest.NewRecorder()
	writer := &statusWriter{ResponseWriter: response, status: http.StatusOK}

	RecoveryMiddleware(discardLogger(), next).ServeHTTP(writer, request)

	if response.Code != http.StatusAccepted {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusAccepted)
	}
	if response.Body.String() != "started" {
		t.Fatalf("body = %q, want started", response.Body.String())
	}
}

func TestStatusWriterOnlyWritesHeaderOnce(t *testing.T) {
	t.Parallel()

	response := httptest.NewRecorder()
	writer := &statusWriter{ResponseWriter: response, status: http.StatusOK}
	writer.WriteHeader(http.StatusCreated)
	writer.WriteHeader(http.StatusNoContent)
	_, _ = writer.Write([]byte("ok"))

	if writer.status != http.StatusCreated {
		t.Fatalf("status = %d, want %d", writer.status, http.StatusCreated)
	}
	if writer.bytes != 2 {
		t.Fatalf("bytes = %d, want 2", writer.bytes)
	}
}

func TestWriteJSONEmptyMessagesIsArray(t *testing.T) {
	t.Parallel()

	response := httptest.NewRecorder()
	writeJSON(response, http.StatusOK, make([]db.Message, 0))

	if got := strings.TrimSpace(response.Body.String()); got != "[]" {
		t.Fatalf("body = %s, want []", got)
	}
}

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}
