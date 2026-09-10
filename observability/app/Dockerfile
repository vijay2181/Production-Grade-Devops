# ── Stage 1: build ────────────────────────────────────────────────
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
# Install ALL deps including @opentelemetry/* packages
RUN npm ci --only=production

# ── Stage 2: runtime ──────────────────────────────────────────────
FROM node:20-alpine AS runtime

# Non-root user
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Copy production node_modules (includes OTel SDK)
COPY --from=builder /app/node_modules ./node_modules

# Copy app source + OTel init file
COPY src/    ./src/
COPY otel/   ./otel/
COPY package.json ./

USER appuser
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

# NOTE: src/index.js has require('./otel/otel') as its first line
# The OTel SDK is initialised before any other module loads
CMD ["node", "src/index.js"]
