FROM python:3.13-alpine

WORKDIR /app

COPY requirements/backend.in requirements/backend.in
RUN apk add --no-cache --virtual .build-deps gcc musl-dev libffi-dev \
 && pip install --no-cache-dir -r requirements/backend.in \
 && apk del .build-deps

COPY spaceship spaceship
COPY build build

EXPOSE 8000

CMD ["uvicorn", "spaceship.main:app", "--host", "0.0.0.0", "--port", "8000"]
