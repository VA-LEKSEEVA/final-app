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
cp .env.example .env
# Замените POSTGRES_PASSWORD в .env
docker compose up --build
```

Приложение будет доступно на `http://localhost:8080`.

`POSTGRES_PASSWORD` не имеет небезопасного значения по умолчанию: Compose
остановится с понятной ошибкой, если пароль не задан.

## Конфигурация

| Переменная | Обязательна | По умолчанию | Назначение |
| --- | --- | --- | --- |
| `DATABASE_URL` | условно | — | PostgreSQL DSN; имеет приоритет над `DB_*` |
| `DB_HOST` | условно | — | Хост PostgreSQL, если `DATABASE_URL` не задан |
| `DB_PORT` | нет | `5432` | Порт PostgreSQL |
| `DB_USER` | условно | — | Пользователь PostgreSQL при конфигурации через `DB_*` |
| `DB_PASSWORD` | нет | — | Пароль PostgreSQL при конфигурации через `DB_*` |
| `DB_NAME` | условно | — | Имя базы при конфигурации через `DB_*` |
| `DB_SSLMODE` | нет | `disable` | Режим SSL при конфигурации через `DB_*` |
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
actionlint
docker compose config
```

## CI/CD

Workflow `.github/workflows/ci.yml`:

1. запускает форматирование, `go vet`, сборку и `golangci-lint`;
2. выполняет тесты с PostgreSQL и сохраняет coverage;
3. собирает и smoke-тестирует Docker-образ на pull request и push;
4. только для push в `main` проверяет Yandex Container Registry, публикует
   immutable-тег `${GITHUB_SHA}` и `latest`;
5. после успешной публикации обновляет `.image.repository` и `.image.tag` в
   единственном `prod.yaml` GitOps-репозитория.

Нужны GitHub Actions secrets:

| Secret | Значение |
| --- | --- |
| `YC_REGISTRY_ID` | ID существующего Yandex Container Registry вида `crp...`/`cr...`, **не имя** реестра |
| `YC_SA_KEY` | полный JSON авторизованного ключа service account |
| `GITOPS_REPO` | `owner/repository` или HTTPS URL GitHub-репозитория |
| `GITOPS_TOKEN` | fine-grained PAT с правом `Contents: Read and write` для GitOps-репозитория |

Service account из `YC_SA_KEY` должен иметь право читать реестр и загружать
Docker-образы. Сам реестр должен существовать: pipeline намеренно не создаёт
cloud-ресурсы автоматически и завершится до `docker push` с точной диагностикой,
если `YC_REGISTRY_ID` пуст, имеет неверный формат, указывает на удалённый реестр
или недоступен service account.
