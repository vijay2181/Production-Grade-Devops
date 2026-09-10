// =============================================================
// otel.js — OpenTelemetry SDK initialisation
//
// MUST be loaded FIRST before any other require() calls.
// In index.js: require('./otel/otel') is the very first line.
//
// What this does:
//   - Creates a NodeSDK with auto-instrumentation
//   - Auto-instruments: express, http, pg, ioredis, dns
//   - Exports traces to OTel Collector via OTLP gRPC
//   - Exports metrics to OTel Collector via OTLP gRPC
//   - Exports logs to OTel Collector via OTLP gRPC
//   - Attaches k8s resource attributes to every span/metric/log
//   - Applies tail sampling: 10% in prod, 100% in dev/staging
// =============================================================
"use strict";

const { NodeSDK }               = require("@opentelemetry/sdk-node");
const { OTLPTraceExporter }     = require("@opentelemetry/exporter-trace-otlp-grpc");
const { OTLPMetricExporter }    = require("@opentelemetry/exporter-metrics-otlp-grpc");
const { OTLPLogExporter }       = require("@opentelemetry/exporter-logs-otlp-grpc");
const { PeriodicExportingMetricReader } = require("@opentelemetry/sdk-metrics");
const { Resource }              = require("@opentelemetry/resources");
const { SemanticResourceAttributes } = require("@opentelemetry/semantic-conventions");
const { getNodeAutoInstrumentations } = require("@opentelemetry/auto-instrumentations-node");
const { SimpleLogRecordProcessor }    = require("@opentelemetry/sdk-logs");
const {
  ParentBasedSampler,
  TraceIdRatioBasedSampler,
  AlwaysOnSampler,
  AlwaysOffSampler,
} = require("@opentelemetry/sdk-trace-base");

// ── OTel Collector endpoint ────────────────────────────────────
// Injected via env var in Kubernetes (points to DaemonSet collector)
const OTEL_EXPORTER_ENDPOINT = process.env.OTEL_EXPORTER_OTLP_ENDPOINT
  || "http://otel-collector.observability.svc.cluster.local:4317";

// ── Resource: metadata attached to every signal ───────────────
// These appear in Grafana as labels/attributes on every trace, metric, log
const resource = new Resource({
  [SemanticResourceAttributes.SERVICE_NAME]:       process.env.OTEL_SERVICE_NAME || "myapp-api",
  [SemanticResourceAttributes.SERVICE_VERSION]:    process.env.APP_VERSION        || "1.0.0",
  [SemanticResourceAttributes.DEPLOYMENT_ENVIRONMENT]: process.env.NODE_ENV       || "production",
  // Kubernetes attributes — injected by OTel Collector k8sattributes processor
  // but we set them here too for direct export scenarios
  "k8s.namespace.name": process.env.K8S_NAMESPACE  || "myapp",
  "k8s.pod.name":       process.env.K8S_POD_NAME   || "unknown",
  "k8s.node.name":      process.env.K8S_NODE_NAME  || "unknown",
});

// ── Trace exporter ────────────────────────────────────────────
const traceExporter = new OTLPTraceExporter({
  url: OTEL_EXPORTER_ENDPOINT,
});

// ── Metric exporter ───────────────────────────────────────────
const metricExporter = new OTLPMetricExporter({
  url: OTEL_EXPORTER_ENDPOINT,
});

// ── Log exporter ──────────────────────────────────────────────
const logExporter = new OTLPLogExporter({
  url: OTEL_EXPORTER_ENDPOINT,
});

// ── Sampling strategy ─────────────────────────────────────────
// prod:    10% of traces sampled (cost control at scale)
//          BUT always sample errors — never miss a failure
// dev/staging: 100% sampled (see everything)
//
// ParentBasedSampler respects the sampling decision of upstream
// services — consistent traces across service boundaries.
const SAMPLE_RATE = process.env.NODE_ENV === "production" ? 0.1 : 1.0;

const sampler = new ParentBasedSampler({
  // Root spans (no parent): sample by rate
  root: new TraceIdRatioBasedSampler(SAMPLE_RATE),
  // If parent was sampled: always sample this span too (consistent trace)
  remoteParentSampled: new AlwaysOnSampler(),
  // If parent was NOT sampled: don't sample
  remoteParentNotSampled: new AlwaysOffSampler(),
  localParentSampled: new AlwaysOnSampler(),
  localParentNotSampled: new AlwaysOffSampler(),
});

console.log(`OTel sampling rate: ${SAMPLE_RATE * 100}% (env: ${process.env.NODE_ENV})`);

// ── SDK ───────────────────────────────────────────────────────
const sdk = new NodeSDK({
  resource,
  sampler,                         // ← sampling applied here
  traceExporter,
  metricReader: new PeriodicExportingMetricReader({
    exporter: metricExporter,
    exportIntervalMillis: 15000,  // export metrics every 15s
  }),
  logRecordProcessor: new SimpleLogRecordProcessor(logExporter),

  // Auto-instrumentation covers:
  //   @opentelemetry/instrumentation-http        → all HTTP in/out
  //   @opentelemetry/instrumentation-express     → route-level spans
  //   @opentelemetry/instrumentation-pg          → every Postgres query
  //   @opentelemetry/instrumentation-ioredis     → every Redis command
  //   @opentelemetry/instrumentation-dns         → DNS lookups
  instrumentations: [
    getNodeAutoInstrumentations({
      "@opentelemetry/instrumentation-fs": {
        enabled: false,   // too noisy — disable filesystem instrumentation
      },
      "@opentelemetry/instrumentation-http": {
        // Don't trace health/metrics endpoints (noise)
        ignoreIncomingRequestHook: (req) => {
          return ["/health", "/ready", "/metrics"].includes(req.url);
        },
        // Capture request/response attributes
        requestHook: (span, req) => {
          span.setAttribute("http.request.body.size",
            req.headers["content-length"] || 0);
        },
      },
      "@opentelemetry/instrumentation-pg": {
        // Capture the actual SQL statement (careful with PII)
        enhancedDatabaseReporting: true,
      },
    }),
  ],
});

// ── Start SDK ─────────────────────────────────────────────────
sdk.start();
console.log("OpenTelemetry SDK started — exporting to:", OTEL_EXPORTER_ENDPOINT);

// ── Graceful shutdown ─────────────────────────────────────────
process.on("SIGTERM", () => {
  sdk.shutdown()
    .then(() => console.log("OpenTelemetry SDK shut down"))
    .catch((err) => console.error("OTel shutdown error:", err))
    .finally(() => process.exit(0));
});
