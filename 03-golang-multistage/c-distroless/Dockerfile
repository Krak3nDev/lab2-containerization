FROM golang:1.22 AS builder

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags='-s -w' -o /out/fizzbuzz .

FROM gcr.io/distroless/static-debian12:nonroot

WORKDIR /app
COPY --from=builder /out/fizzbuzz /app/fizzbuzz
COPY --from=builder /src/templates /app/templates

EXPOSE 8080

ENTRYPOINT ["/app/fizzbuzz", "serve"]
