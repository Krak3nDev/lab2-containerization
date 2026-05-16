# Лабораторна робота №2 — Контейнеризація

Студент: Бігіч Назар.
Звіт: [`REPORT.md`](REPORT.md).
Зведена таблиця результатів: [`RESULTS.md`](RESULTS.md).
Конфігурація машини: [`MACHINE.md`](MACHINE.md).

## Структура

```
01-python-base/
  ├── a-initial/              # 1A-a: наївний Dockerfile (COPY всього + pip install)
  ├── c-cache-optimized/      # 1A-c: cache-friendly шар-порядок
  ├── d-alpine/               # 1A-d: python:3.13-alpine
  ├── e-numpy/{debian,alpine} # 1A-e: numpy + /api/matrix endpoint
  ├── run-all.sh              # запуск 1A-a..1A-e + post-edit вимірювання
  └── results.txt
02-dns-musl-glibc/
  ├── run.sh                  # 1B: dnsmasq + ubuntu vs alpine клієнти
  └── logs/                   # dnsmasq + per-client output
03-golang-multistage/
  ├── a-single-stage/         # 1C-a: golang:1.22 — повний toolchain в runtime
  ├── b-scratch/              # 1C-b: multi-stage → FROM scratch
  ├── c-distroless/           # 1C-c: multi-stage → distroless/static
  ├── run-all.sh
  └── results.txt
MACHINE.md
RESULTS.md
REPORT.md
SUBMISSION.md
```

## Відтворення (швидко)

Передумови: Docker із Compose; macOS/Linux; ~10 GB вільного місця для образів.

```bash
git clone https://github.com/KPI-FICT-MTSD/lab-03-starter-project-python /tmp/lab2-python-starter
git -C /tmp/lab2-python-starter checkout 85f43a6df964c0fd2be9ef0d02297e49b553f8c4

git clone https://github.com/comsys-kpi-ua/deploy.lab-containers-starter-project-golang /tmp/lab2-go-starter
git -C /tmp/lab2-go-starter checkout 8545aca5a00fe82a6a1c1c03ecb85eef11f6f60e

./01-python-base/run-all.sh
./02-dns-musl-glibc/run.sh
./03-golang-multistage/run-all.sh
```

Практична частина (docker-compose стек для mywebapp): https://github.com/Krak3nDev/mywebapp — див. секцію `## Запуск через Docker Compose` у README цієї репи.
