const express = require("express");
const { Pool }  = require("pg");
const Redis     = require("ioredis");
const client    = require("prom-client");
const morgan    = require("morgan");

const app  = express();
const PORT = process.env.PORT || 3000;

// ─── Prometheus metrics ────────────────────────────────────────
const register = new client.Registry();
client.collectDefaultMetrics({ register });
const httpRequests = new client.Counter({
  name: "http_requests_total",
  help: "Total HTTP requests",
  labelNames: ["method", "route", "status"],
  registers: [register],
});

// ─── DB + Redis ────────────────────────────────────────────────
const pool = new Pool({
  host:     process.env.DB_HOST,
  port:     parseInt(process.env.DB_PORT || "5432"),
  database: process.env.DB_NAME,
  user:     process.env.DB_USER,
  password: process.env.DB_PASSWORD,
});

const redis = new Redis({
  host: process.env.REDIS_HOST,
  port: parseInt(process.env.REDIS_PORT || "6379"),
  lazyConnect: true,
  retryStrategy: (times) => Math.min(times * 50, 2000),
});

// ─── Middleware ────────────────────────────────────────────────
app.use(express.json());
app.use(morgan("combined"));
app.use((req, _res, next) => {
  req._start = Date.now();
  next();
});

// ─── Routes ───────────────────────────────────────────────────
app.get("/health", (_req, res) => res.json({ status: "ok", ts: new Date() }));

app.get("/ready", async (_req, res) => {
  try {
    await pool.query("SELECT 1");
    await redis.ping();
    res.json({ status: "ready" });
  } catch (err) {
    res.status(503).json({ status: "not ready", error: err.message });
  }
});

app.get("/metrics", async (_req, res) => {
  res.set("Content-Type", register.contentType);
  res.end(await register.metrics());
});

app.get("/api/items", async (_req, res) => {
  const cached = await redis.get("items");
  if (cached) return res.json({ source: "cache", data: JSON.parse(cached) });

  const { rows } = await pool.query("SELECT * FROM items ORDER BY id DESC LIMIT 50");
  await redis.set("items", JSON.stringify(rows), "EX", 60);
  res.json({ source: "db", data: rows });
});

app.post("/api/items", async (req, res) => {
  const { name, value } = req.body;
  const { rows } = await pool.query(
    "INSERT INTO items (name, value) VALUES ($1, $2) RETURNING *",
    [name, value]
  );
  await redis.del("items");
  res.status(201).json(rows[0]);
});

// ─── Count metrics after response ─────────────────────────────
app.use((req, res, next) => {
  res.on("finish", () => {
    httpRequests.inc({ method: req.method, route: req.path, status: res.statusCode });
  });
  next();
});

// ─── Start ────────────────────────────────────────────────────
async function start() {
  await redis.connect().catch(() => {}); // lazy — ok if not ready yet
  await pool.query(`
    CREATE TABLE IF NOT EXISTS items (
      id    SERIAL PRIMARY KEY,
      name  TEXT NOT NULL,
      value TEXT,
      created_at TIMESTAMPTZ DEFAULT now()
    )
  `);
  app.listen(PORT, () => console.log(`API listening on :${PORT}`));
}

start().catch((err) => { console.error(err); process.exit(1); });
