# === STAGE 1: Сборка ===
FROM golang:1.23 AS builder

WORKDIR /src

# Копируем только go.mod и go.sum для кэширования зависимостей
COPY go.mod go.sum ./
RUN go mod download

# Копируем остальной код
COPY . .

# Собираем статический бинарник (CGO_ENABLED=0, без libc)
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w" \
    -o /out/server ./cmd/server

# === STAGE 2: Финальный образ на distroless ===
FROM gcr.io/distroless/static-debian12:nonroot

WORKDIR /app

# Копируем бинарник из предыдущего этапа
COPY --from=builder /out/server ./

# Копируем статику (web/ папку)
COPY --from=builder /src/web ./web

# Пользователь nonroot уже существует в образе
USER nonroot:nonroot

EXPOSE 8080

ENTRYPOINT ["/app/server"]
