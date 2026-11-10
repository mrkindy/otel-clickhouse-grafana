#!/usr/bin/env bash
# End-to-end smoke test for the all-in-one image.
# Usage: IMAGE=otel-clickhouse-grafana:dev test/smoke.sh
# Requires: docker, curl, python3 on the host.
set -uo pipefail

IMAGE=${IMAGE:-otel-clickhouse-grafana:dev}
HERE=$(cd "$(dirname "$0")" && pwd)
RUN_ID=$$
NAME=octg-smoke-$RUN_ID
TLS_NAME=octg-smoke-tls-$RUN_ID
VOL=octg-smoke-data-$RUN_ID
PORT=${PORT:-18080}
TLS_PORT=${TLS_PORT:-18443}
TOKEN=smoke-token-123
ADMIN_PASS=smoke-admin-pass
BASE=http://127.0.0.1:$PORT

passed=0
failed=0
check() {
  local desc=$1
  shift
  if "$@"; then
    echo "ok   - $desc"
    passed=$((passed + 1))
  else
    echo "FAIL - $desc"
    failed=$((failed + 1))
  fi
}

cleanup() {
  docker rm -f "$NAME" "$TLS_NAME" "$NAME-gen" >/dev/null 2>&1
  docker volume rm "$VOL" "$VOL-gen" >/dev/null 2>&1
}
trap cleanup EXIT

wait_healthy() {
  local name=$1 status
  for _ in $(seq 1 90); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo missing)
    [ "$status" = healthy ] && return 0
    [ "$status" = missing ] && return 1
    sleep 2
  done
  return 1
}

# Poll a command until it succeeds (max ~40s).
eventually() {
  for _ in $(seq 1 20); do
    "$@" && return 0
    sleep 2
  done
  return 1
}

http_code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
ch() { docker exec "$NAME" clickhouse-client --query "$1" 2>/dev/null; }

post_otlp() { # $1=signal $2=fixture $3=token(optional)
  local auth=()
  [ -n "${3:-}" ] && auth=(-H "Authorization: Bearer $3")
  # Fixture timestamps are rewritten to "now" so retention/TTL never drops them.
  python3 "$HERE/fixture_now.py" "$HERE/fixtures/$2" |
    http_code -X POST "$BASE/v1/$1" -H 'Content-Type: application/json' "${auth[@]}" --data-binary @-
}

refused() { # only "connection refused" (curl exit 7) counts; timeouts or an empty IP do not
  [ -n "$IP" ] || return 1
  curl -s -m 3 -o /dev/null "$1"
  [ $? -eq 7 ]
}

# Start a container that must refuse to start: exits non-zero and logs $2.
refuses_to_start() { # $1=name suffix $2=expected log text, rest=docker run args
  local n="$NAME-bad-$1" want=$2 code
  shift 2
  docker run -d --name "$n" "$@" "$IMAGE" >/dev/null
  code=$(timeout 60 docker wait "$n" 2>/dev/null || echo timeout)
  if [ "$code" != 0 ] && [ "$code" != timeout ] && docker logs "$n" 2>&1 | grep -qF "$want"; then
    docker rm -f "$n" >/dev/null; return 0
  fi
  echo "    (exit=$code) $(docker logs "$n" 2>&1 | grep -F init-config | tail -2)"
  docker rm -f "$n" >/dev/null; return 1
}

# True when the query's numeric result is >= $1. Re-evaluated on every call,
# so it can be retried with `eventually`.
count_ge() {
  local v
  v=$(ch "$2")
  [ -n "$v" ] && [ "$v" -ge "$1" ]
}
otlp_status_is() { [ "$(post_otlp "$2" "$3" "${4:-}")" = "$1" ]; }

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "FAIL - image $IMAGE not found (build it first: make build)"
  exit 1
fi

echo "# starting $IMAGE (plain HTTP mode, tokens set)"
docker run -d --name "$NAME" --memory=2g -p "127.0.0.1:$PORT:80" -v "$VOL:/data" \
  -e OTLP_TOKENS="other-token, $TOKEN" -e GRAFANA_ADMIN_PASSWORD="$ADMIN_PASS" \
  "$IMAGE" >/dev/null

check "container becomes healthy" wait_healthy "$NAME"

# --- OTLP ingestion and auth -------------------------------------------------
check "OTLP without token is rejected (401)" test "$(post_otlp logs logs.json)" = 401
check "OTLP with wrong token is rejected (401)" test "$(post_otlp logs logs.json wrong)" = 401
check "Grafana /metrics is not public" test "$(http_code "$BASE/metrics")" != 200
check "OTLP logs with valid token accepted (200)" test "$(post_otlp logs logs.json "$TOKEN")" = 200
check "second token in the list also works" test "$(post_otlp metrics metrics.json other-token)" = 200

check "cumulative metric accepted (200)" test "$(post_otlp metrics metrics_cumulative.json "$TOKEN")" = 200
check "metrics stored in otel_metrics_sum" eventually count_ge 1 \
  "SELECT count() FROM otel.otel_metrics_sum WHERE MetricName='claude_code.cost.usage'"
check "logs stored in otel_logs" eventually count_ge 1 \
  "SELECT count() FROM otel.otel_logs WHERE LogAttributes['session.id']='smoke-session'"
check "SessionId materialized column is populated" count_ge 1 \
  "SELECT count() FROM otel.otel_logs WHERE SessionId='smoke-session'"
check "retention TTL (30 days) applied to otel_logs" bash -c \
  "docker exec $NAME clickhouse-client --query \"SELECT create_table_query FROM system.tables WHERE database='otel' AND name='otel_logs'\" | grep -q 'toIntervalDay(30)'"
check "retention TTL applied to otel_metrics_sum" bash -c \
  "docker exec $NAME clickhouse-client --query \"SELECT create_table_query FROM system.tables WHERE database='otel' AND name='otel_metrics_sum'\" | grep -q 'toIntervalDay(30)'"

# --- Grafana -----------------------------------------------------------------
check "Grafana health through Caddy" test "$(http_code "$BASE/api/health")" = 200
check "anonymous Grafana access is denied" test "$(http_code "$BASE/api/search")" = 401
check "admin password from env works" test "$(http_code -u "admin:$ADMIN_PASS" "$BASE/api/search")" = 200
check "ClickHouse datasource is healthy" bash -c \
  "curl -s -u admin:$ADMIN_PASS $BASE/api/datasources/uid/clickhouse/health | grep -q '\"status\":\"OK\"'"
eventually count_ge 1 "SELECT count() FROM otel.otel_metrics_sum WHERE AggregationTemporality = 2" >/dev/null
check "all dashboards provisioned, every panel query succeeds, key values correct" \
  python3 "$HERE/check_dashboards.py" "$BASE" admin "$ADMIN_PASS" \
    "claude-code-overview:Total cost=0.43" "claude-code-overview:Sessions=1" \
    "claude-code-productivity:Lines added=120" "claude-code-sessions:Prompts=1"
check "grafana_ro cannot raise its ClickHouse query limits" bash -c \
  "! docker exec $NAME sh -c 'clickhouse-client --user grafana_ro --password \"\$(cat /run/grafana/ch_password)\" --query \"SELECT 1 SETTINGS max_threads=64\"' >/dev/null 2>&1"
check "grafana_ro can still query within its limits" bash -c \
  "docker exec $NAME sh -c 'clickhouse-client --user grafana_ro --password \"\$(cat /run/grafana/ch_password)\" --query \"SELECT 1 SETTINGS max_threads=2\"' >/dev/null 2>&1"

# --- Network exposure ----------------------------------------------------------
IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME")
for p in 3000 4317 4318 8123 9000 13133; do
  check "internal port $p not reachable from outside the container" refused "http://$IP:$p/"
done

# --- Supervision and persistence ---------------------------------------------
old_pid=$(docker exec "$NAME" pgrep -f '^/usr/local/bin/otelcol')
check "collector process found" test -n "$old_pid"
docker exec "$NAME" kill "$old_pid" >/dev/null 2>&1
new_pid_differs() { local p; p=$(docker exec "$NAME" pgrep -f '^/usr/local/bin/otelcol'); [ -n "$p" ] && [ "$p" != "$old_pid" ]; }
check "collector is restarted with a new PID after being killed" eventually new_pid_differs
check "collector accepts data again after restart" eventually otlp_status_is 200 logs logs.json "$TOKEN"

before=$(ch "SELECT count() FROM otel.otel_logs")
docker restart "$NAME" >/dev/null
check "healthy again after docker restart" wait_healthy "$NAME"
check "data survives restart" eventually count_ge "${before:-1}" "SELECT count() FROM otel.otel_logs"
check "admin password still valid after restart" test "$(http_code -u "admin:$ADMIN_PASS" "$BASE/api/search")" = 200

# Recreate on the same volume with a different password: the new one must apply.
docker rm -f "$NAME" >/dev/null
docker run -d --name "$NAME" --memory=2g -p "127.0.0.1:$PORT:80" -v "$VOL:/data" \
  -e OTLP_TOKENS="$TOKEN" -e GRAFANA_ADMIN_PASSWORD="$ADMIN_PASS-2" -e RETENTION_DAYS=7 \
  "$IMAGE" >/dev/null
check "healthy after recreate on existing volume" wait_healthy "$NAME"
check "changed GRAFANA_ADMIN_PASSWORD applies to existing database" \
  test "$(http_code -u "admin:$ADMIN_PASS-2" "$BASE/api/search")" = 200
check "old admin password no longer works" test "$(http_code -u "admin:$ADMIN_PASS" "$BASE/api/search")" = 401
check "changed RETENTION_DAYS applied to existing tables" bash -c \
  "docker exec $NAME clickhouse-client --query \"SELECT create_table_query FROM system.tables WHERE database='otel' AND name='otel_logs'\" | grep -q 'toIntervalDay(7)'"
check "removed token is no longer accepted" test "$(post_otlp logs logs.json other-token)" = 401

mem=$(docker stats --no-stream --format '{{.MemUsage}}' "$NAME" | awk '{print $1}')
echo "# memory in use: $mem"
check "memory use stays under 1.5GiB" python3 -c "
import re,sys
v,u=re.match(r'([0-9.]+)([KMG]i?B)','$mem').groups()
mult={'KiB':1/1024,'MiB':1,'GiB':1024,'KB':1/1000,'MB':1,'GB':1000}[u]
sys.exit(0 if float(v)*mult < 1536 else 1)"

# --- Invalid configuration fails fast with a clear message -------------------
check "too-short GRAFANA_ADMIN_PASSWORD refused" refuses_to_start shortpw "GRAFANA_ADMIN_PASSWORD must be at least" \
  -e GRAFANA_ADMIN_PASSWORD=abc
check "token containing whitespace refused" refuses_to_start spacetok "OTLP_TOKENS: tokens must not contain spaces" \
  -e OTLP_TOKENS="tokA, tok B"
check "DOMAIN with a scheme refused" refuses_to_start scheme "DOMAIN must be a bare hostname" \
  -e DOMAIN=https://otel.example.com
check "ACME_EMAIL with whitespace refused" refuses_to_start email "ACME_EMAIL is not a valid e-mail address" \
  -e DOMAIN=localhost -e ACME_EMAIL="a b@x.io"
check "invalid CLICKHOUSE_MEMORY_RATIO refused" refuses_to_start ratio "CLICKHOUSE_MEMORY_RATIO must be a number" \
  -e CLICKHOUSE_MEMORY_RATIO=lots

# --- Public mode without credentials: secrets are generated once and kept ------
# --network none: Caddy cannot reach Let's Encrypt, so no real ACME traffic happens.
GEN_NAME=$NAME-gen
GEN_VOL=$VOL-gen
inside() { docker exec "$GEN_NAME" "$@"; }
gen_secret_from_logs() { # $1 = label in the log line
  docker logs "$GEN_NAME" 2>&1 | grep -F "generated $1" | sed -E 's/.*: ([^ ]+)$/\1/' | tail -1
}
docker run -d --name "$GEN_NAME" --network none -v "$GEN_VOL:/data" \
  -e DOMAIN=otel.example.test -e ACME_STAGING=1 "$IMAGE" >/dev/null
check "public mode without credentials becomes healthy" wait_healthy "$GEN_NAME"
GEN_TOKEN=$(gen_secret_from_logs "an OTLP token")
GEN_PASS=$(gen_secret_from_logs "a Grafana admin password")
check "a generated OTLP token is printed once in the logs" test -n "$GEN_TOKEN"
check "a generated Grafana password is printed once in the logs" test -n "$GEN_PASS"
otlp_inside() { # $1 = token (may be empty)
  python3 "$HERE/fixture_now.py" "$HERE/fixtures/logs.json" | docker exec -i "$GEN_NAME" curl -s -o /dev/null \
    -w '%{http_code}' -X POST http://127.0.0.1:4318/v1/logs -H 'Content-Type: application/json' \
    ${1:+-H "Authorization: Bearer $1"} --data-binary @-
}
check "public mode: OTLP without token rejected" test "$(otlp_inside "")" = 401
check "public mode: generated token accepted" test "$(otlp_inside "$GEN_TOKEN")" = 200
check "public mode: generated Grafana password works" test \
  "$(inside curl -s -o /dev/null -w '%{http_code}' -u "admin:$GEN_PASS" http://127.0.0.1:3000/api/search)" = 200
check "public mode: admin/admin does not work" test \
  "$(inside curl -s -o /dev/null -w '%{http_code}' -u admin:admin http://127.0.0.1:3000/api/search)" = 401
docker restart "$GEN_NAME" >/dev/null
check "public mode: healthy after restart" wait_healthy "$GEN_NAME"
check "public mode: same token still works after restart" test "$(otlp_inside "$GEN_TOKEN")" = 200
check "public mode: same password still works after restart" test \
  "$(inside curl -s -o /dev/null -w '%{http_code}' -u "admin:$GEN_PASS" http://127.0.0.1:3000/api/search)" = 200
check "public mode: secrets are not printed again on restart" test \
  "$(docker logs "$GEN_NAME" 2>&1 | grep -cF "$GEN_TOKEN")" = 1
docker rm -f "$GEN_NAME" >/dev/null
docker volume rm "$GEN_VOL" >/dev/null

# --- TLS mode (Caddy internal CA for DOMAIN=localhost) -----------------------
echo "# starting TLS mode container (DOMAIN=localhost)"
docker run -d --name "$TLS_NAME" --memory=2g -p "127.0.0.1:$TLS_PORT:443" \
  -e DOMAIN=localhost -e OTLP_TOKENS="$TOKEN" -e GRAFANA_ADMIN_PASSWORD="$ADMIN_PASS" \
  "$IMAGE" >/dev/null
check "TLS container becomes healthy" wait_healthy "$TLS_NAME"
check "Grafana served over HTTPS" test \
  "$(http_code -k --resolve "localhost:$TLS_PORT:127.0.0.1" "https://localhost:$TLS_PORT/api/health")" = 200
check "OTLP over HTTPS with token accepted" test "$(python3 "$HERE/fixture_now.py" "$HERE/fixtures/logs.json" |
  http_code -k --resolve "localhost:$TLS_PORT:127.0.0.1" -X POST "https://localhost:$TLS_PORT/v1/logs" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" --data-binary @-)" = 200

echo
echo "# passed: $passed  failed: $failed"
if [ "$failed" -ne 0 ]; then
  echo "# --- last container logs ---"
  docker logs --tail 60 "$NAME" 2>&1
  exit 1
fi
