// =============================================================
// index.js — Node.js API with full OpenTelemetry instrumentation
//
// LINE 1: require('./otel/otel') MUST be first — before anything else
// This ensures auto-instrumentation patches pg, ioredis, express
// before they are loaded.
// =============================================================
require("./otel/otel");   // ← MUST be first line

const express   = require("express");
const { Pool }  = require("pg");
const Redis     = require("ioredis");
const winston   = require("winston");
const client    = require("prom-client");
const { trace, context, SpanStatusCode } = require("@opentelemetry/api");

const app  = express();
const PORT = process.env.PORT || 3000;

// ── Structured logger (JSON, traceID injected) ────────────────
// traceID appears in every log line → Loki correlates to Tempo
const logger = winston.createLogger({
  level: process.env.LOG_LEVEL || "info",
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.json(),
    // Inject OpenTelemetry traceID + spanID into every log line
    winston.format((info) => {
      const span = trace.getActiveSpan();
      if (span) {
        const ctx = span.spanContext();
        info.traceId  = ctx.traceId;
        info.spanId   = ctx.spanId;
        info.traceFlags = ctx.traceFlags;
      }
      return info;
    })()
  ),
  transports: [new winston.transports.Console()],
});

// ── Prometheus metrics (for Prometheus scrape endpoint) ───────
// OTel also exports metrics — these are the prom-client ones for /metrics
const register = new client.Registry();
client.collectDefaultMetrics({ register });

const httpRequestDuration = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "HTTP request duration in seconds",
  labelNames: ["method", "route", "status_code"],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  registers: [register],
});

const httpRequestsTotal = new client.Counter({
  name: "http_requests_total",
  help: "Total HTTP requests",
  labelNames: ["method", "route", "status_code"],
  registers: [register],
});

// ── DB + Redis ─────────────────────────────────────────────────
const pool = new Pool({
  host:     process.env.DB_HOST,
  port:     parseInt(process.env.DB_PORT || "5432"),
  database: process.env.DB_NAME,
  user:     process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  // Connection pool settings — important for production
  max:            10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 2000,
});

const redis = new Redis({
  host:         process.env.REDIS_HOST,
  port:         parseInt(process.env.REDIS_PORT || "6379"),
  lazyConnect:  true,
  retryStrategy: (times) => Math.min(times * 50, 2000),
  maxRetriesPerRequest: 3,
});

// ── Middleware ─────────────────────────────────────────────────
app.use(express.json());

// Request logging middleware — structured JSON with traceID
app.use((req, res, next) => {
  req._startTime = Date.now();
  res.on("finish", () => {
    const duration = (Date.now() - req._startTime) / 1000;
    const route = req.route?.path || req.path;

    logger.info("http request", {
      method:     req.method,
      route,
      status:     res.statusCode,
      duration_s: duration,
      user_agent: req.headers["user-agent"],
      ip:         req.ip,
    });

    // Record Prometheus metrics
    httpRequestDuration.observe(
      { method: req.method, route, status_code: res.statusCode },
      duration
    );
    httpRequestsTotal.inc(
      { method: req.method, route, status_code: res.statusCode }
    );
  });
  next();
});

// ── Routes ─────────────────────────────────────────────────────

// Health — no tracing noise
app.get("/health", (_req, res) => {
  res.json({ status: "ok", ts: new Date() });
});

// Readiness — checks DB + Redis
app.get("/ready", async (_req, res) => {
  try {
    await pool.query("SELECT 1");
    await redis.ping();
    res.json({ status: "ready" });
  } catch (err) {
    logger.error("readiness check failed", { error: err.message });
    res.status(503).json({ status: "not ready", error: err.message });
  }
});

// Prometheus scrape endpoint
app.get("/metrics", async (_req, res) => {
  res.set("Content-Type", register.contentType);
  res.end(await register.metrics());
});

// GET /api/items — Redis cache → Postgres fallback
app.get("/api/items", async (req, res) => {
  // Get current span (created by OTel auto-instrumentation for this route)
  const span = trace.getActiveSpan();

  try {
    // ── Redis cache check ──────────────────────────────────────
    span?.setAttribute("cache.operation", "get");
    const cached = await redis.get("items");

    if (cached) {
      span?.setAttribute("cache.hit", true);
      logger.info("cache hit", { key: "items" });
      return res.json({ source: "cache", data: JSON.parse(cached) });
    }

    span?.setAttribute("cache.hit", false);
    logger.info("cache miss", { key: "items" });

    // ── Postgres query ─────────────────────────────────────────
    // OTel pg instrumentation creates a child span for this query automatically
    // The span includes: db.statement, db.operation, db.name, net.peer.name
    const { rows } = await pool.query(
      "SELECT id, name, value, created_at FROM items ORDER BY id DESC LIMIT 50"
    );

    span?.setAttribute("db.rows_returned", rows.length);

    // ── Cache the result ───────────────────────────────────────
    await redis.set("items", JSON.stringify(rows), "EX", 60);

    res.json({ source: "db", data: rows });

  } catch (err) {
    // Record error on the span — visible in Tempo as a failed span
    span?.recordException(err);
    span?.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
    logger.error("GET /api/items failed", { error: err.message });
    res.status(500).json({ error: "internal server error" });
  }
});

// POST /api/items
app.post("/api/items", async (req, res) => {
  const span = trace.getActiveSpan();
  const { name, value } = req.body;

  if (!name) {
    span?.setAttribute("validation.error", "missing name");
    return res.status(400).json({ error: "name is required" });
  }

  try {
    span?.setAttribute("item.name", name);

    const { rows } = await pool.query(
      "INSERT INTO items (name, value) VALUES ($1, $2) RETURNING *",
      [name, value]
    );

    // Invalidate cache
    await redis.del("items");
    span?.setAttribute("cache.invalidated", true);

    logger.info("item created", { id: rows[0].id, name });
    res.status(201).json(rows[0]);

  } catch (err) {
    span?.recordException(err);
    span?.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
    logger.error("POST /api/items failed", { error: err.message });
    res.status(500).json({ error: "internal server error" });
  }
});

// ── Manual span example — custom business operation ───────────
// Use this pattern when you want to trace a specific block of code
app.get("/api/items/:id", async (req, res) => {
  const tracer = trace.getTracer("myapp-api");

  // Create a custom child span for the business logic
  return tracer.startActiveSpan("fetch-item-with-permissions", async (span) => {
    try {
      span.setAttribute("item.id", req.params.id);

      // ── Child span: permission check ─────────────────────────
      await tracer.startActiveSpan("check-permissions", async (permSpan) => {
        // Simulate permission check
        permSpan.setAttribute("user.id", req.headers["x-user-id"] || "anonymous");
        permSpan.end();
      });

      // ── Child span: database fetch ────────────────────────────
      const { rows } = await pool.query(
        "SELECT * FROM items WHERE id = $1",
        [req.params.id]
      );

      if (!rows.length) {
        span.setAttribute("item.found", false);
        span.end();
        return res.status(404).json({ error: "not found" });
      }

      span.setAttribute("item.found", true);
      span.end();
      res.json(rows[0]);

    } catch (err) {
      span.recordException(err);
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      span.end();
      res.status(500).json({ error: "internal server error" });
    }
  });
});

// ── Start ──────────────────────────────────────────────────────
async function start() {
  await redis.connect().catch(() => {});
  await pool.query(`
    CREATE TABLE IF NOT EXISTS items (
      id         SERIAL PRIMARY KEY,
      name       TEXT NOT NULL,
      value      TEXT,
      created_at TIMESTAMPTZ DEFAULT now()
    )
  `);
  app.listen(PORT, () => {
    logger.info("API started", { port: PORT, env: process.env.NODE_ENV });
  });
}

start().catch((err) => {
  logger.error("startup failed", { error: err.message });
  process.exit(1);
});
