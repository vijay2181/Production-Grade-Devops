# ==============================================================================
# Production Multi-Stage Hardened Dockerfile
# Follows CIS Benchmark and Distroless Least-Privilege Principles
# ==============================================================================

# Build stage
FROM python:3.11-slim-bookworm AS builder

WORKDIR /build

RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc libffi-dev && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

# Final runtime stage using Google Distroless Python
FROM gcr.io/distroless/python3-debian12:nonroot

WORKDIR /app

# Copy python packages from builder
COPY --from=builder /root/.local /home/nonroot/.local
COPY main.py .

ENV PATH=/home/nonroot/.local/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    APP_ENV=production \
    APP_VERSION=1.0.0

USER nonroot

EXPOSE 5000

CMD ["main.py"]
