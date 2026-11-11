#!/command/with-contenv bash
# Runs once after the collector is up (it creates the otel.* tables on start).
#  1. Keeps every table's TTL in sync with RETENTION_DAYS. The exporter only
#     sets TTL when it creates a table, so a later change needs ALTER.
#  2. Adds MATERIALIZED helper columns to otel_logs for keys the dashboards
#     filter on. Idempotent; safe to run on every boot.
set -euo pipefail

log() { echo "[schema-tune] $*"; }
q() { clickhouse-client --query "$1"; }

DAYS=${RETENTION_DAYS:-30}
TABLES=(otel_logs otel_traces otel_traces_trace_id_ts otel_metrics_sum otel_metrics_gauge
        otel_metrics_histogram otel_metrics_exponential_histogram otel_metrics_summary)
IN_LIST=$(printf "'%s'," "${TABLES[@]}")
IN_LIST=${IN_LIST%,}

for _ in $(seq 1 90); do
  n=$(q "SELECT count() FROM system.tables WHERE database='otel' AND name IN (${IN_LIST})" 2>/dev/null || echo 0)
  [ "$n" -eq "${#TABLES[@]}" ] && break
  sleep 1
done
[ "$n" -eq "${#TABLES[@]}" ] || { log "ERROR: collector did not create the otel tables (found $n of ${#TABLES[@]})"; exit 1; }

# 1. TTL
for t in "${TABLES[@]}"; do
  ddl=$(q "SELECT create_table_query FROM system.tables WHERE database='otel' AND name='${t}'")
  if grep -q "+ toIntervalDay(${DAYS})" <<<"$ddl"; then
    continue
  fi
  field=$(grep -oE 'TTL [^ ]+ \+ toInterval' <<<"$ddl" | head -1 | sed -E 's/^TTL ([^ ]+) \+ toInterval$/\1/' || true)
  if [ -z "$field" ]; then
    case "$t" in otel_logs|otel_traces) field='toDateTime(Timestamp)' ;; *) field='toDateTime(TimeUnix)' ;; esac
  fi
  log "setting retention of otel.${t} to ${DAYS} days"
  q "ALTER TABLE otel.${t} MODIFY TTL ${field} + toIntervalDay(${DAYS})"
done

# 2. Helper columns. Claude Code may put these keys on the log record or on the
#    resource, so prefer the record value and fall back to the resource.
attr() { echo "if(LogAttributes['$1'] != '', LogAttributes['$1'], ResourceAttributes['$1'])"; }
add_col() {
  q "ALTER TABLE otel.otel_logs ADD COLUMN IF NOT EXISTS $1 String MATERIALIZED $2"
}
add_col SessionId "$(attr session.id)"
add_col PromptId  "$(attr prompt.id)"
add_col Event     "replaceOne($(attr event.name), 'claude_code.', '')"
add_col UserEmail "$(attr user.email)"
add_col UserId    "$(attr user.id)"
# "owner/name" from OTEL_METRICS_INCLUDE_REPOSITORY=true (empty when not enabled
# on the client or when the project has no git origin remote).
add_col Repository "concat(if($(attr vcs.owner.name) != '', concat($(attr vcs.owner.name), '/'), ''), $(attr vcs.repository.name))"

log "done"
