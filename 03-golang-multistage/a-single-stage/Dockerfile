FROM golang:1.22

WORKDIR /app

COPY . .

RUN go mod tidy && go build -o /app/fizzbuzz .

EXPOSE 8080

ENTRYPOINT ["/app/fizzbuzz", "serve"]
