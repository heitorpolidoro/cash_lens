# syntax=docker/dockerfile:1
FROM python:3.12-slim AS base

# Avoid interactive tzdata and speed up installs
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# System dependencies for scientific stack and psycopg2
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc \
    libpq-dev \
    libgomp1 \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy only requirements first to leverage Docker layer caching
COPY ml/requirements.txt /app/requirements.txt
RUN pip install --upgrade pip && pip install -r /app/requirements.txt

# Copy application code
COPY ml /app/ml

# Default environment
ENV PY_SERVICE_PORT=8000

EXPOSE 8000

# Run the FastAPI app with Uvicorn
CMD ["uvicorn", "ml.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
