#!/bin/sh
# Container health: every component must answer. "Connection refused" is a failure.
fail=0
probe() { # name url
  if ! curl -fsS -m 4 -o /dev/null "$2"; then
    echo "unhealthy: $1 ($2)"
    fail=1
  fi
}
probe clickhouse http://127.0.0.1:8123/ping
probe otelcol    http://127.0.0.1:13133/
probe grafana    http://127.0.0.1:3000/api/health

# Caddy: any HTTP answer on :80 means it is serving (it may redirect to HTTPS).
code=$(curl -s -m 4 -o /dev/null -w '%{http_code}' http://127.0.0.1:80/ || true)
if [ "$code" = "000" ]; then
  echo "unhealthy: caddy (no answer on :80)"
  fail=1
fi
exit $fail
