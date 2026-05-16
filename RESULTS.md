# Зведена таблиця результатів

Усі вимірювання виконано на одній машині — конфігурація у [`MACHINE.md`](MACHINE.md).
Стартові репозиторії:
- Python: `KPI-FICT-MTSD/lab-03-starter-project-python @ 85f43a6df964c0fd2be9ef0d02297e49b553f8c4`
- Go: `comsys-kpi-ua/deploy.lab-containers-starter-project-golang @ 8545aca5a00fe82a6a1c1c03ecb85eef11f6f60e`

Параметри замірів:
- Cold = `docker build --no-cache -t … .` (повне відтворення без BuildKit-кешу).
- Warm = `docker build -t … .` (з кешем після попередньої збірки).
- Time — wall clock, `time.time()` довкола `docker build`.
- Size — `docker image inspect -f '{{.Size}}'`, переведено у MB (1024×1024).

## 1A — Python application

| ID | Base | Cache state | Image size | Build (s) | Коментар |
|---|---|---|---|---|---|
| 1A-a | python:3.13-slim-bookworm | cold (no-cache) | 184.4 MB | 9.44 | Наївний `COPY . . → pip install -r requirements/backend.in` |
| 1A-b | python:3.13-slim-bookworm | warm, після правки `spaceship/main.py` | 184.4 MB | 6.90 | Кеш бази є, але `COPY . .` інвалідує шар `pip install` |
| 1A-c | python:3.13-slim-bookworm | cold (no-cache), правильний шар-порядок | 184.4 MB | 6.17 | Спочатку `COPY requirements`, потім pip install, наприкінці код |
| 1A-c (re) | python:3.13-slim-bookworm | warm, після правки коду | 184.4 MB | **0.73** | `pip install` шар закешовано — перебудовується лише `COPY spaceship` |
| 1A-d | python:3.13-alpine | cold (no-cache) | **87.6 MB** | 11.01 | `apk add --virtual gcc musl-dev libffi-dev` для збірки `uvloop`, після pip — `apk del` |
| 1A-e (Debian) | python:3.13-slim-bookworm + numpy | cold | 247.8 MB | 7.59 | numpy ставиться з prebuilt wheel (manylinux) — швидко |
| 1A-e (Alpine) | python:3.13-alpine + numpy | cold | 154.2 MB | 12.13 | numpy потребує build deps (gcc/g++), пакет ставиться з джерела |

## 1B — Musl (Alpine) vs glibc (Ubuntu) DNS resolution

Команда клієнтів: `getent hosts myservice.internal` з прапорами `--dns=<dnsmasq-IP> --dns-search=corp`.
dnsmasq має лише запис `address=/myservice.internal.corp/10.0.0.50` (точна назва з search-суфіксом).

| Клієнт | Бібліотека резолвера | Результат | Exit |
|---|---|---|---|
| ubuntu:latest | glibc (libc6 / NSS) | `10.0.0.50  myservice.internal.corp` | 0 |
| alpine:latest | musl libc | (нічого) | 2 |

dnsmasq-лог (фрагмент):
```
query[A] myservice.internal       from <ubuntu>  → NXDOMAIN
query[A] myservice.internal.corp  from <ubuntu>  → config 10.0.0.50  ← glibc застосував search
query[A] myservice.internal       from <alpine>  → NXDOMAIN
(жодного запиту myservice.internal.corp від alpine-клієнта)
```

Висновок: glibc розширює `search corp` ⇒ виконує запит `myservice.internal.corp`. musl у такому ж сценарії — НЕ розширює (через `ndots` за замовчуванням і відсутність розширення для імен, що містять крапку).

## 1C — Golang multi-stage

| ID | Runtime base | Image size | Build (s) | Δ до 1C-a |
|---|---|---|---|---|
| 1C-a | golang:1.22 (весь toolchain) | 878.1 MB | 21.08 | — |
| 1C-b | scratch (порожній) | **6.8 MB** | 6.05 | **−99.2 %** |
| 1C-c | gcr.io/distroless/static-debian12:nonroot | 8.8 MB | 8.29 | −99.0 % |

Що ж лежить у 878 МБ образі 1C-a:
```
246 MB  /usr/local/go     ← Go toolchain не потрібен у runtime
 79 MB  /root             ← go module cache (~/go)
 11 MB  /app              ← виконуваний бінарник + темплейти
```
Тобто >99 % образу — артефакти збірки, які можна викинути на наступному етапі.
