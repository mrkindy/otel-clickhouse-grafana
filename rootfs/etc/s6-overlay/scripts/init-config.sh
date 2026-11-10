#!/command/with-contenv bash
# One-shot setup that runs before any service starts.
# Turns the user-facing environment variables into config files, generates
# fresh internal passwords on every boot, and prepares the /data volume.
set -euo pipefail

ENV_DIR=/run/s6/container_environment

log() { echo "[init-config] $*"; }
die() { echo "[init-config] ERROR: $*" >&2; exit 1; }

# Make a value visible to every service started after this script.
set_env() { printf '%s' "$2" > "$ENV_DIR/$1"; }
# Hide a value from services started after this script.
unset_env() { rm -f "$ENV_DIR/$1"; }

# Random secret. The leading letter keeps YAML from parsing it as a number.
gen_secret() { printf 'k%s' "$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }

trim_list() { # "a, b ,c" -> one token per line, empties dropped
  tr ',' '\n' <<<"$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed '/^$/d'
}

# ---------------------------------------------------------------------------
# Mode: "public" when DOMAIN is a real hostname (Let's Encrypt), "local" otherwise.
# ---------------------------------------------------------------------------
DOMAIN=${DOMAIN:-}
OTLP_TOKENS=${OTLP_TOKENS:-}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:-}
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != localhost ]; then
  MODE=public
else
  MODE=local
fi
log "mode: $MODE${DOMAIN:+ (domain: $DOMAIN)}"

# ---------------------------------------------------------------------------
# What happens when the container is reachable from the internet (MODE=public)
# but OTLP_TOKENS or GRAFANA_ADMIN_PASSWORD were not provided.
#
# Available here:
#   $MODE                    "public" or "local"
#   $OTLP_TOKENS             comma-separated tokens, may be empty
#   $GRAFANA_ADMIN_PASSWORD  may be empty
#   log / die                print a message / print and stop the container
#   gen_secret               prints a random secret
# If you assign OTLP_TOKENS or GRAFANA_ADMIN_PASSWORD here, the rest of the
# script uses the new values.
# ---------------------------------------------------------------------------
#
# Policy: generate what is missing, keep it on the volume so restarts don't
# break clients, and print each secret only on the boot that created it.
enforce_security_policy() {
  [ "$MODE" = public ] || return 0
  local dir=/data/secrets
  mkdir -p "$dir" && chmod 0700 "$dir"

  if [ -z "$(trim_list "$OTLP_TOKENS")" ]; then
    if [ ! -s "$dir/otlp_token" ]; then
      gen_secret > "$dir/otlp_token"
      log "OTLP_TOKENS not set: generated an OTLP token (shown once, kept in $dir/otlp_token): $(cat "$dir/otlp_token")"
    else
      log "OTLP_TOKENS not set: using the token generated earlier ($dir/otlp_token)"
    fi
    OTLP_TOKENS=$(cat "$dir/otlp_token")
  fi

  if [ -z "$GRAFANA_ADMIN_PASSWORD" ]; then
    if [ ! -s "$dir/grafana_admin_password" ]; then
      gen_secret > "$dir/grafana_admin_password"
      log "GRAFANA_ADMIN_PASSWORD not set: generated a Grafana admin password (shown once, kept in $dir/grafana_admin_password): $(cat "$dir/grafana_admin_password")"
    else
      log "GRAFANA_ADMIN_PASSWORD not set: using the password generated earlier ($dir/grafana_admin_password)"
    fi
    GRAFANA_ADMIN_PASSWORD=$(cat "$dir/grafana_admin_password")
  fi
  chmod 0600 "$dir"/* 2>/dev/null || true
}
enforce_security_policy

# ---------------------------------------------------------------------------
# Validate user input up front: a bad value should stop the container with a
# clear message, not crash-loop a service later.
# ---------------------------------------------------------------------------
HOST_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$'
if [ -n "$DOMAIN" ] && ! [[ "$DOMAIN" =~ $HOST_RE ]]; then
  die "DOMAIN must be a bare hostname such as otel.example.com (no scheme, port or path); got '$DOMAIN'"
fi
if [ -n "${ACME_EMAIL:-}" ] && ! [[ "$ACME_EMAIL" =~ ^[^[:space:]{}@]+@[^[:space:]{}@]+\.[^[:space:]{}@]+$ ]]; then
  die "ACME_EMAIL is not a valid e-mail address: '$ACME_EMAIL'"
fi
if [ -n "$GRAFANA_ADMIN_PASSWORD" ] && [ "${#GRAFANA_ADMIN_PASSWORD}" -lt 8 ]; then
  die "GRAFANA_ADMIN_PASSWORD must be at least 8 characters"
fi
while IFS= read -r token; do
  if [[ "$token" =~ [[:space:]] ]]; then
    die "OTLP_TOKENS: tokens must not contain spaces (separate tokens with commas)"
  fi
done < <(trim_list "$OTLP_TOKENS")
CLICKHOUSE_MEMORY_RATIO=${CLICKHOUSE_MEMORY_RATIO:-0.45}
if ! [[ "$CLICKHOUSE_MEMORY_RATIO" =~ ^(0?\.[0-9]*[1-9][0-9]*|1(\.0*)?)$ ]]; then
  die "CLICKHOUSE_MEMORY_RATIO must be a number between 0 and 1 (e.g. 0.45); got '$CLICKHOUSE_MEMORY_RATIO'"
fi
set_env CLICKHOUSE_MEMORY_RATIO "$CLICKHOUSE_MEMORY_RATIO"

# ---------------------------------------------------------------------------
# Volume layout and ownership.
# ---------------------------------------------------------------------------
mkdir -p /data/clickhouse /data/grafana/logs /data/caddy /run/otelcol /run/grafana /run/caddy /run/caddy-config
chown -R clickhouse:clickhouse /data/clickhouse
chown -R grafana:grafana /data/grafana /run/grafana
chown -R caddy:caddy /data/caddy /run/caddy /run/caddy-config
chown otelcol:otelcol /run/otelcol
chmod 0700 /data/clickhouse /data/caddy /run/otelcol /run/grafana

# ---------------------------------------------------------------------------
# Retention.
# ---------------------------------------------------------------------------
RETENTION_DAYS=${RETENTION_DAYS:-30}
[[ "$RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] || die "RETENTION_DAYS must be a positive whole number of days (got '$RETENTION_DAYS')"
set_env RETENTION_DAYS "$RETENTION_DAYS"
set_env OTEL_TTL "$((RETENTION_DAYS * 24))h"

# ---------------------------------------------------------------------------
# ClickHouse users. Passwords are regenerated on every boot and only stored
# as SHA-256 hashes in ClickHouse's config; plaintext goes to per-service files.
# ---------------------------------------------------------------------------
CH_ADMIN_PW=$(gen_secret)
CH_OTEL_PW=$(gen_secret)
CH_GRAFANA_PW=$(gen_secret)
sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

cat > /etc/clickhouse-server/users.d/zz-passwords.xml <<EOF
<clickhouse>
  <users>
    <default><password remove="1"/><password_sha256_hex>$(sha "$CH_ADMIN_PW")</password_sha256_hex></default>
    <otel><password_sha256_hex>$(sha "$CH_OTEL_PW")</password_sha256_hex></otel>
    <grafana_ro><password_sha256_hex>$(sha "$CH_GRAFANA_PW")</password_sha256_hex></grafana_ro>
  </users>
</clickhouse>
EOF
chown clickhouse:clickhouse /etc/clickhouse-server/users.d/zz-passwords.xml
chmod 0600 /etc/clickhouse-server/users.d/zz-passwords.xml

# Lets `docker exec <ctr> clickhouse-client` (as root) log in without a prompt.
mkdir -p /etc/clickhouse-client
cat > /etc/clickhouse-client/config.xml <<EOF
<config><user>default</user><password>${CH_ADMIN_PW}</password></config>
EOF
chmod 0600 /etc/clickhouse-client/config.xml

printf '%s' "$CH_OTEL_PW" > /run/otelcol/ch_password
printf '%s' "$CH_GRAFANA_PW" > /run/grafana/ch_password
chown otelcol:otelcol /run/otelcol/ch_password
chown grafana:grafana /run/grafana/ch_password
chmod 0400 /run/otelcol/ch_password /run/grafana/ch_password

# ---------------------------------------------------------------------------
# OTLP tokens -> collector. With tokens, the auth overlay is merged in.
# ---------------------------------------------------------------------------
trim_list "$OTLP_TOKENS" > /run/otelcol/tokens
chown otelcol:otelcol /run/otelcol/tokens
chmod 0400 /run/otelcol/tokens
if [ -s /run/otelcol/tokens ]; then
  log "OTLP auth: $(wc -l < /run/otelcol/tokens) token(s) configured"
  set_env OTELCOL_CONFIGS "--config=/etc/otelcol/config.yaml --config=/etc/otelcol/auth.yaml"
else
  log "OTLP auth: DISABLED (no OTLP_TOKENS) — anyone who can reach the port can send data"
  set_env OTELCOL_CONFIGS "--config=/etc/otelcol/config.yaml"
fi
unset_env OTLP_TOKENS

# ---------------------------------------------------------------------------
# Caddy site address and global options.
# ---------------------------------------------------------------------------
{
  echo "grace_period 10s"
  if [ -n "${ACME_EMAIL:-}" ]; then echo "email ${ACME_EMAIL}"; fi
  if [ "${ACME_STAGING:-0}" = 1 ]; then echo "acme_ca https://acme-staging-v02.api.letsencrypt.org/directory"; fi
} > /run/caddy/global-options.caddy
if [ -n "$DOMAIN" ]; then
  set_env SITE_ADDRESS "$DOMAIN"
else
  set_env SITE_ADDRESS ":80"
fi
chown -R caddy:caddy /run/caddy

# ---------------------------------------------------------------------------
# Grafana.
# ---------------------------------------------------------------------------
if [ -n "$DOMAIN" ]; then
  set_env GF_SERVER_ROOT_URL "https://${DOMAIN}/"
  set_env GF_SERVER_DOMAIN "$DOMAIN"
  set_env GF_SECURITY_COOKIE_SECURE true
fi
if [ -n "$GRAFANA_ADMIN_PASSWORD" ]; then
  printf '%s' "$GRAFANA_ADMIN_PASSWORD" > /run/grafana/admin_password
  chown grafana:grafana /run/grafana/admin_password
  chmod 0400 /run/grafana/admin_password
  # First boot: Grafana reads this file when it creates its database.
  # ($__file{} is expanded by Grafana itself; the *__FILE convention only exists
  # in Grafana's official image entrypoint, not in the binary.)
  # shellcheck disable=SC2016
  set_env GF_SECURITY_ADMIN_PASSWORD '$__file{/run/grafana/admin_password}'
  # Later boots: the database already exists, so reset the password explicitly.
  if [ -f /data/grafana/grafana.db ]; then
    log "applying GRAFANA_ADMIN_PASSWORD to the existing Grafana database"
    if ! out=$(s6-setuidgid grafana grafana cli --homepath "$GF_PATHS_HOME" \
        admin reset-admin-password --password-from-stdin < /run/grafana/admin_password 2>&1); then
      echo "$out" | tail -5 >&2
      die "could not reset the Grafana admin password"
    fi
  fi
fi
unset_env GRAFANA_ADMIN_PASSWORD

log "done"
