#!/usr/bin/env bash
# =============================================================
# generate-load.sh — Generate traffic to produce traces + metrics + logs
#
# Run this after installing the observability stack to
# immediately see data in Grafana Tempo, Loki, and Prometheus.
#
# Usage: ./scripts/generate-load.sh <api-endpoint>
# Example: ./scripts/generate-load.sh https://api.myapp.com
# =============================================================
set -euo pipefail

ENDPOINT="${1:-http://localhost:3000}"
DURATION="${2:-300}"   # seconds

echo "=== Generating load against ${ENDPOINT} for ${DURATION}s ==="
echo "This will produce traces in Tempo, logs in Loki, and metrics in Prometheus."
echo ""

# ── Install k6 if needed ─────────────────────────────────────────
command -v k6 &>/dev/null || brew install k6

# ── Run load test ─────────────────────────────────────────────────
k6 run - <<EOF
import http from 'k6/http';
import { check, sleep } from 'k6';
import { randomString } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

export let options = {
  stages: [
    { duration: '30s', target: 10  },
    { duration: '${DURATION}s', target: 30  },
    { duration: '30s', target: 0   },
  ],
  thresholds: {
    http_req_failed:   ['rate<0.01'],
    http_req_duration: ['p(95)<500'],
  },
};

export default function () {
  // ── GET /api/items — generates Redis + Postgres spans ─────────
  let getRes = http.get('${ENDPOINT}/api/items', {
    headers: { 'X-Request-ID': randomString(16) }
  });
  check(getRes, { 'GET 200': (r) => r.status === 200 });

  sleep(0.2);

  // ── POST /api/items — generates write spans ────────────────────
  let postRes = http.post(
    '${ENDPOINT}/api/items',
    JSON.stringify({ name: 'load-test-' + randomString(8), value: String(Date.now()) }),
    { headers: { 'Content-Type': 'application/json' } }
  );
  check(postRes, { 'POST 201': (r) => r.status === 201 });

  sleep(0.3);

  // ── GET /api/items/:id — generates custom span + child spans ──
  let id = Math.floor(Math.random() * 10) + 1;
  let getByIdRes = http.get('${ENDPOINT}/api/items/' + id);
  // 404 is expected for non-existent items — still generates a trace

  sleep(0.5);
}
EOF

echo ""
echo "=== Load generation complete ==="
echo ""
echo "View results:"
echo "  Grafana → Explore → Tempo → Search by service: myapp-api"
echo "  Grafana → Explore → Loki  → {app=\"api\"} | json"
echo "  Grafana → Dashboards → MyApp Observability"
