# Guestbook

Небольшая production-oriented гостевая книга на Go и PostgreSQL.

## Возможности

- JSON API для чтения и создания сообщений;
- валидация входных данных и ограничение размера запроса;
- liveness/readiness probes;
- Prometheus-метрики;
- структурированные JSON-логи;
- graceful shutdown и таймауты HTTP-сервера;
- контейнер без root-прав и Docker Compose для локального запуска.

## Быстрый старт

```bash
docker compose up --build
```

Приложение будет доступно на `http://localhost:8080`.

Для production обязательно задайте собственный пароль:

```bash
POSTGRES_PASSWORD='strong-password' docker compose up --build -d
```

## Конфигурация

| Переменная | Обязательна | По умолчанию | Назначение |
| --- | --- | --- | --- |
| `DATABASE_URL` | да | — | PostgreSQL DSN |
| `LISTEN_ADDR` | нет | `:8080` | Адрес HTTP-сервера |
| `LOG_LEVEL` | нет | `INFO` | Уровень логов |
| `STARTUP_TIMEOUT` | нет | `60s` | Ожидание PostgreSQL |
| `SHUTDOWN_TIMEOUT` | нет | `10s` | Graceful shutdown |
| `HTTP_READ_HEADER_TIMEOUT` | нет | `5s` | Таймаут чтения заголовков |
| `HTTP_READ_TIMEOUT` | нет | `10s` | Таймаут чтения запроса |
| `HTTP_WRITE_TIMEOUT` | нет | `15s` | Таймаут ответа |
| `HTTP_IDLE_TIMEOUT` | нет | `60s` | Keep-alive таймаут |

## HTTP

- `GET /` — интерфейс гостевой книги;
- `GET /api/messages` — до 100 последних сообщений;
- `POST /api/messages` — создать сообщение;
- `GET /healthz` — liveness;
- `GET /readyz` и `GET /health` — readiness с проверкой PostgreSQL;
- `GET /metrics` — Prometheus.

Пример:

```bash
curl -X POST http://localhost:8080/api/messages \
  -H 'Content-Type: application/json' \
  -d '{"author":"Анна","text":"Привет!"}'
```

## Проверки

```bash
gofmt -w .
go vet ./...
go test -race ./...
go build ./...
```
