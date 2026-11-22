FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/ backend/
COPY main.py .

WORKDIR /app/backend
CMD ["uvicorn", "gojo_server:app", "--host", "0.0.0.0", "--port", "8080"]
