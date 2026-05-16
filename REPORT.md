# Звіт — Лабораторна робота №2: Контейнеризація

**Студент:** Бігіч Назар
**Дата:** 2026-05-16
**Машина для всіх замірів:** [`MACHINE.md`](MACHINE.md) (Apple M4 Pro, 14 cores, 24 GB RAM, macOS 15.7.3, Docker Engine 28.5.2 в OrbStack, linux/arm64).
**Стартери (фіксовані коміти):**
- Python: `KPI-FICT-MTSD/lab-03-starter-project-python @ 85f43a6df964c0fd2be9ef0d02297e49b553f8c4`
- Go: `comsys-kpi-ua/deploy.lab-containers-starter-project-golang @ 8545aca5a00fe82a6a1c1c03ecb85eef11f6f60e`

Усі цифри у звіті відтворюються запуском `01-python-base/run-all.sh`, `02-dns-musl-glibc/run.sh`, `03-golang-multistage/run-all.sh`.

---

## 1. Python — вплив шар-порядку та базового образу

### Експеримент 1A-a → 1A-b: наївний Dockerfile + правка коду

Dockerfile, який бачить більшість новачків:
```dockerfile
FROM python:3.13-slim-bookworm
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -r requirements/backend.in
```

Cold build: 184.4 MB, 9.44 s.
Правлю `spaceship/main.py`, rebuild: **6.90 s**, той самий розмір.

Чому 6.9 s, а не <1 s, як могло б бути? Тому що `COPY . .` йде ПЕРЕД `pip install` — будь-яка зміна у будь-якому файлі інвалідує шар `pip install`, і всі залежності встановлюються наново. Базовий шар (image pull) залишається кешованим — звідси 6.9 s замість 9.4 s, а не 0.7 s.

### Експеримент 1A-c: правильний шар-порядок

```dockerfile
FROM python:3.13-slim-bookworm
WORKDIR /app
COPY requirements/backend.in requirements/backend.in
RUN pip install --no-cache-dir -r requirements/backend.in
COPY spaceship spaceship
COPY build build
```

Cold: 184.4 MB, 6.17 s. Правка коду → rebuild: **0.73 s**.

Різниця 6.90 → 0.73 s — це **~9.5× прискорення** наступних збірок при правці коду. Те, що раніше було повним перевстановленням залежностей, перетворилося на простий `COPY` нових файлів. На реальному CI з 50–200 залежностями ця різниця стає хвилинами.

Розмір однаковий — це очікувано: кінцевий шар-склад однаковий, змінився лише порядок.

### Експеримент 1A-d: alpine замість slim-bookworm

Alpine використовує musl + busybox і дає значно менший базовий образ. Але тут є нюанс: `uvicorn[standard]` тягне `uvloop` і `httptools` — обидва містять C-екстеншени. Для cpython manylinux wheels існують лише під glibc; на musl pip намагається компілювати їх з джерела. Тому Dockerfile потребує транзитних build deps:

```dockerfile
RUN apk add --no-cache --virtual .build-deps gcc musl-dev libffi-dev \
 && pip install --no-cache-dir -r requirements/backend.in \
 && apk del .build-deps
```

Результат: **87.6 MB** (−52 % від bookworm) при cold-build 11 s (повільніше за рахунок компіляції uvloop).

### Експеримент 1A-e: додаємо numpy + endpoint /api/matrix

`spaceship/routers/api.py` отримав ендпоінт, що повертає дві випадкові 10×10 матриці та їх добуток через `numpy.matmul`:

```python
@router.get('/matrix')
def matrix() -> dict:
    a = np.random.rand(10, 10)
    b = np.random.rand(10, 10)
    return {'matrix_a': a.tolist(), 'matrix_b': b.tolist(), 'product': (a @ b).tolist()}
```

Розмір на debian-slim: 184.4 → **247.8 MB** (+63 MB). На alpine: 87.6 → **154.2 MB** (+67 MB).
На обох додалось приблизно стільки ж — це власне numpy + його C-екстеншени.

Час cold-build: debian 7.6 s vs alpine **12.1 s** — alpine знову повільніший через відсутність binary wheel.

Ключовий висновок: для **типового Python-сервісу з кількома C-екстеншенами** (numpy/scipy/psycopg/pillow/cryptography) `python:3.13-slim-bookworm` практично завжди ефективніший: менше build deps, швидші збірки, бінарні wheels. Alpine виправдано лише коли (а) усі залежності pure-Python або (б) глибокий контроль над розміром важливіший за швидкість CI.

---

## 2. Musl vs glibc — DNS і search-домени

Експеримент: один dnsmasq (alpine), що знає лише запис `address=/myservice.internal.corp/10.0.0.50`. Два клієнти (ubuntu = glibc, alpine = musl) однією й тією ж командою `getent hosts myservice.internal` із `--dns-search=corp`.

| Клієнт | Результат |
|---|---|
| ubuntu | `10.0.0.50  myservice.internal.corp` (exit 0) |
| alpine | нічого (exit 2 — not found) |

Що показав dnsmasq-лог:

```
ubuntu → query A myservice.internal       → NXDOMAIN
ubuntu → query A myservice.internal.corp  → config 10.0.0.50   ← glibc застосував search
alpine → query A myservice.internal       → NXDOMAIN
(жодного запиту myservice.internal.corp від alpine)
```

glibc-резолвер за замовчуванням бачить `ndots:1` (на середовищі типового контейнера) і трактує імена з 0 крапок як "single-label" → одразу намагається все з search-доменом, +чисту назву. Musl має історично іншу логіку: search-list використовується тільки для імен ВЗАГАЛІ без крапок. Тому "myservice.internal" для musl — це FQDN, search-list НЕ застосовується.

**Наслідки на практиці:**
- Якщо ваш сервіс залежить від коротких корпоративних імен (наприклад, K8s `myservice.internal` із namespace `corp`), переключення базового образу з debian-slim на alpine може ТИХО зламати DNS-резолюцію, навіть коли інші мережеві перевірки проходять.
- Це класична причина "у dev все працює, у проді — ні", якщо dev на debian, а prod на alpine.
- Workaround: завжди використовувати FQDN з кінцевою крапкою (або повне ім'я з усіма доменами) у конфігах. Не покладатися на ndots/search-list.

**Примітка щодо специфікації:** docx-документ роботи містить команди `docker run` з символом `–` (en-dash) через Word-автоформат. Скрипт `02-dns-musl-glibc/run.sh` явно використовує `--` (double hyphen), як того вимагає Docker CLI.

---

## 3. Golang — multi-stage та distroless

| Підхід | Базовий рантайм | Розмір | Час cold |
|---|---|---|---|
| Single-stage | golang:1.22 | 878.1 MB | 21.08 s |
| Multi-stage → scratch | scratch | **6.8 MB** | 6.05 s |
| Multi-stage → distroless | gcr.io/distroless/static-debian12:nonroot | 8.8 MB | 8.29 s |

**Single-stage** (1C-a) тримає у фінальному образі весь Go toolchain (246 MB), кеш модулів (79 MB) та інші артефакти збірки. Усе це непотрібно в рантаймі — `serve` запускає скомпільований бінарник, який нічого з тих файлів не читає.

**Multi-stage → scratch** (1C-b): два `FROM`. Перший збирає `CGO_ENABLED=0 GOOS=linux go build -ldflags='-s -w'` (статичний бінарник без debug-символів). Другий — `FROM scratch`, куди копіюється лише бінарник і шаблон `templates/index.html`. Образ важить 6.8 МБ — це фактично розмір бінарника + 600 байт темплейту.

Хороший компроміс? У scratch немає НІЧОГО:
- немає `sh` → не можна зайти `docker exec -it ... sh`
- немає `ca-certificates` → HTTPS до зовнішніх сервісів не працює
- немає `tzdata` → time.Now().In(...) лише UTC
- немає `/etc/passwd` → процес біжить як root з UID 0
- немає `/etc/nsswitch.conf` → нативний Go-резолвер обмежений

Для CLI/static-web цього достатньо. Для більшості реальних мікросервісів — недостатньо.

**Multi-stage → distroless** (1C-c): той самий рантайм, але `gcr.io/distroless/static-debian12:nonroot` дає:
- `ca-certificates` (вже на місці)
- `tzdata`
- `/etc/passwd` з користувачем `nonroot` (UID 65532)
- `/etc/nsswitch.conf` з помірковано-нормальною конфігурацією
- `/etc/ssl/certs/ca-certificates.crt`

За це доплачуємо ~2 MB і отримуємо набагато практичніший образ. У реальній продакшн-системі для Go-сервісу `distroless/static` — типово найкращий вибір.

---

## 4. Практична частина — docker-compose для mywebapp

Mywebapp (Лабораторна №1, https://github.com/Krak3nDev/mywebapp) — FastAPI + PostgreSQL + nginx. Перетворив у docker-compose стек із чотирма сервісами:

```
client ↘
  nginx (1.27-alpine, host:80→80)
  └── app (python:3.12-slim-bookworm multi-stage, :8080 internal)
        └── postgres (16-alpine, named volume mywebapp-pgdata)
        ↑
  migrate (one-shot, той самий образ, що й app)
```

Ключові архітектурні рішення:

1. **Окрема мережа `mywebapp-net`** (driver=bridge), а не default. Тільки nginx робить `ports: ["${MYWEBAPP_HOST_PORT:-80}:80"]` назовні; postgres і app залишаються в internal-мережі (доступні лише за DNS-іменами усередині compose-проєкту).
2. **Named volume `mywebapp-pgdata`** на `/var/lib/postgresql/data`. Через це `docker compose down` (без `-v`) лишає БД, `docker compose down -v` — знищує. Перевіряв: POST → down → up → той самий запис; потім `down -v` → up → порожня БД.
3. **Multi-stage Dockerfile (debian-slim + venv)**. У builder робиться venv `/opt/venv` з `pip install -r requirements.txt`; у runtime — той же python:3.12-slim-bookworm + postgresql-client + curl, копіюється лише venv. Жодних `build-essential`/`libpq-dev` не потрібно, бо `psycopg[binary]` несе libpq статично у wheel.
4. **migrate як окремий one-shot** з `depends_on.condition: service_completed_successfully`. Звідси `app` запускається тільки після успішної міграції. Якщо `migrate` падає (наприклад, неправильний пароль), `app` ніколи не стартує — діагностика через `docker compose logs migrate`.
5. **Env-aware конфігурація**. `app/config.py` і `scripts/migrate.sh` симетрично: якщо є `MYWEBAPP_DB_HOST` — читають env vars; інакше — fallback до TOML (для VM/systemd шляху лаби №1). Один кодбейс — два режими запуску.
6. **nginx у контейнері** — окремий конфіг `mywebapp.compose.conf` із `upstream mywebapp_app { server app:8080; }` (Docker-DNS, не loopback), `access_log /dev/stdout`, `error_log /dev/stderr` (контейнерна конвенція). Allow-list ендпоінтів та default-deny такі ж, як у VM-варіанті: `/`, `/items`, `/items/<id>` пускаємо, `/health/*` явно 404 ззовні.
7. **`MYWEBAPP_HOST_PORT` parameterized**: якщо `:80` зайнятий — у `.env` ставимо `MYWEBAPP_HOST_PORT=8080`.

Перевірка V1 (з документації compose):
```bash
docker compose up -d --build               # postgres healthy → migrate exited 0 → app healthy → nginx
curl http://localhost/items                # 200 []
curl -X POST -d '{"name":"x","quantity":1}' -H 'Content-Type: application/json' http://localhost/items  # 201
curl http://localhost/health/alive         # 404 (nginx блокує ззовні)
docker compose down && docker compose up -d   # дані лишаються
docker compose down -v && docker compose up -d  # дані стерті
```

Усі перевірки пройдено локально (macOS / OrbStack engine, linux/aarch64).

---

## 5. Висновки та рекомендації

Окремо по кожному експерименту, з-під чого зроблені.

**Layer-порядок (1A-b vs 1A-c)**. Найдешевша оптимізація з усіх: переставити `COPY requirements` ПЕРЕД `pip install`, а решту коду — після. На прикладі цього лабораторного: 6.9 s → 0.7 s post-edit rebuild. На реальному CI з десятками залежностей це хвилини. **Рекомендація:** завжди починати Dockerfile з найрідше-змінюваного (системні пакети → залежності → код).

**Базовий образ (1A-d vs 1A-c)**. Alpine дає -52 % розміру, але +60 % cold-build часу і потенційний пакет головного болю з C-екстеншенами. **Рекомендація:** для Python-сервісів з типовим набором C-залежностей (numpy/psycopg/pillow/cryptography/orjson) — `python:3.X-slim-bookworm/trixie`. Alpine розглядати тільки коли (а) залежності pure-Python, або (б) розмір — критична метрика бізнесу, або (в) обрана архітектура (musl-only базова) вимагає.

**Musl vs glibc DNS (1B)**. Alpine-резолвер інший і це не баг — це задокументований дизайн musl. **Рекомендація:** ніколи не покладатися на search-list у production. Використовувати FQDN явно. Це знімає клас "у dev працює, у проді — ні" одразу.

**Multi-stage builds для compiled languages (1C)**. 878 MB → 6.8 MB при переході single-stage → scratch. Це не оптимізація, це **інша категорія системи** (контейнер не як середовище збірки, а як runtime-артефакт). **Рекомендація для Go:** `distroless/static` за замовчуванням. Для бінарників з cgo — `distroless/base`. `FROM scratch` тільки якщо точно знаєте, що ваш бінарник не потребує ні CA, ні tzdata, ні passwd.

**Multi-stage для Python (з мого практичного експерименту)**. Виграш менший (з venv ~30–80 MB економії), але збирається типова продакшн-форма: builder ставить залежності у venv, runtime копіює лише venv + код. Це залишає поза runtime-образом pip-кеш, `__pycache__`, тимчасові wheel-файли — і дозволяє в майбутньому додати залежність з C-екстеншеном без зміни runtime-стейджу.

**Контейнеризація багатосервісного застосунку (практична частина)**. Окрема user-defined network, named volume для stateful-частини, healthchecks + `depends_on.condition` для порядку запуску, parameterized host-port для конфліктів. Це мінімум, який має мати будь-який compose stack у serious-проєкті.

---

## 6. Відтворюваність

Запуск усіх експериментів:

```bash
git clone https://github.com/Krak3nDev/lab2-containerization
cd lab2-containerization

# Стартери (фіксовані коміти)
git clone https://github.com/KPI-FICT-MTSD/lab-03-starter-project-python /tmp/lab2-python-starter
git -C /tmp/lab2-python-starter checkout 85f43a6df964c0fd2be9ef0d02297e49b553f8c4
git clone https://github.com/comsys-kpi-ua/deploy.lab-containers-starter-project-golang /tmp/lab2-go-starter
git -C /tmp/lab2-go-starter checkout 8545aca5a00fe82a6a1c1c03ecb85eef11f6f60e

# Експерименти
./01-python-base/run-all.sh                # → 01-python-base/results.txt
./02-dns-musl-glibc/run.sh                 # → 02-dns-musl-glibc/logs/
./03-golang-multistage/run-all.sh          # → 03-golang-multistage/results.txt

# Практична частина
git clone https://github.com/Krak3nDev/mywebapp
cd mywebapp
cp .env.example .env   # відредагувати POSTGRES_PASSWORD / MYWEBAPP_DB_PASSWORD
docker compose up -d --build
curl http://localhost/items
```

Конфігурацію машини — у [`MACHINE.md`](MACHINE.md). Кожен `Dockerfile` лежить поряд із результатом замірів у відповідній підпапці.
