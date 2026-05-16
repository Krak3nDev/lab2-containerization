FROM python:3.13-slim-bookworm

WORKDIR /app

COPY . .
RUN pip install --no-cache-dir -r requirements/backend.in

EXPOSE 8000

CMD ["uvicorn", "spaceship.main:app", "--host", "0.0.0.0", "--port", "8000"]
