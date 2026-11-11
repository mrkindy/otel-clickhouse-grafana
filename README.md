# otel-clickhouse-grafana

One container that receives OpenTelemetry data, stores it in ClickHouse and
shows it in Grafana, with automatic HTTPS. Ships with dashboards for
**Claude Code** usage: cost and tokens, per-session timelines, team
comparison and productivity.

```
internet ──443/80──> Caddy (automatic Let's Encrypt)
                       ├─ /v1/*  ──> OpenTelemetry Collector ──┐  (Bearer token check)
                       ├─ gRPC   ──> OpenTelemetry Collector ──┤
                       └─ else   ──> Grafana                   ▼
                                       └── read-only ──> ClickHouse
```

All internal services listen on `127.0.0.1` inside the container. Only ports
80 and 443 are exposed. Processes are supervised by
[s6-overlay](https://github.com/just-containers/s6-overlay): if one crashes it
is restarted, and the container health check fails while any component is down.

| Component | Version |
|---|---|
| ClickHouse (LTS) | 26.8.36.3 |
| Grafana OSS | 13.3.0 |
| grafana-clickhouse-datasource | 4.23.5 |
| OpenTelemetry Collector (custom build: otlp, memory_limiter, clickhouse, bearertokenauth, health_check) | 0.165.0 |
| Caddy | 2.11.9 |
| s6-overlay | 3.2.3.2 |

## Quick start

### On a server with a domain

Point a DNS `A` record at the server, open ports 80 and 443, then:

```sh
docker run -d --name otel --restart unless-stopped --stop-timeout 30 \
  -p 80:80 -p 443:443 \
  -v otel-data:/data \
  -e DOMAIN=otel.example.com \
  -e ACME_EMAIL=you@example.com \
  -e OTLP_TOKENS=token-for-alice,token-for-bob \
  -e GRAFANA_ADMIN_PASSWORD='choose-a-strong-password' \
  mrkindy/otel-clickhouse-grafana:latest
```

Open `https://otel.example.com` and log in as `admin`.

If you leave out `OTLP_TOKENS` or `GRAFANA_ADMIN_PASSWORD` while `DOMAIN` is set,
the container never runs open: it generates a random token / password and keeps
it in `/data/secrets/` on the volume, so restarts don't change it. The values
are **not** written to the logs; `docker logs` only says where they are. Read
them with:

```sh
docker exec otel cat /data/secrets/otlp_token
docker exec otel cat /data/secrets/grafana_admin_password
```

Setting `OTLP_TOKENS` / `GRAFANA_ADMIN_PASSWORD` yourself later takes
precedence over the generated values.

While testing, add `-e ACME_STAGING=1` so failed attempts don't count against
Let's Encrypt's production limits (5 certificates for the same domain per 7
days). Keep the `/data` volume: it holds the certificates, and losing it means
requesting new ones.

### Locally (no domain)

```sh
docker run -d --name otel -p 8080:80 -v otel-data:/data mrkindy/otel-clickhouse-grafana:latest
```

Grafana is at `http://localhost:8080` (`admin` / `admin`; Grafana asks you to
change it). OTLP/HTTP is at `http://localhost:8080/v1/...`. Without
`OTLP_TOKENS` the OTLP endpoint accepts data from anyone who can reach it.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `DOMAIN` | unset | Public hostname. When set, Caddy gets a Let's Encrypt certificate and serves HTTPS on 443 (HTTP on 80 redirects). `DOMAIN=localhost` uses Caddy's internal CA instead, for testing. Unset: plain HTTP on port 80. |
| `ACME_EMAIL` | unset | Contact email for Let's Encrypt. |
| `ACME_STAGING` | `0` | `1` uses the Let's Encrypt staging server (untrusted certificates, generous limits). |
| `OTLP_TOKENS` | unset | Comma-separated list of accepted tokens (no spaces inside a token). Clients send `Authorization: Bearer <token>`. Give each developer their own token so one can be revoked by removing it and recreating the container. With `DOMAIN` set and no tokens, one is generated (see above). |
| `GRAFANA_ADMIN_PASSWORD` | unset | Password of the Grafana `admin` user (at least 8 characters). Applied on every start, so changing it and recreating the container changes the password. With `DOMAIN` set and no password, one is generated (see above). |
| `RETENTION_DAYS` | `30` | How long data is kept. Changing it updates existing tables on the next start. |
| `CLICKHOUSE_MEMORY_RATIO` | `0.45` | Share of the container's (or host's) RAM that ClickHouse may use. |

Any Grafana setting can also be passed as `GF_<SECTION>_<KEY>`.

Invalid values (a `DOMAIN` with `https://`, a short password, a token with a
space, a malformed `ACME_EMAIL` or `CLICKHOUSE_MEMORY_RATIO`) stop the container
at startup with a message in `docker logs` explaining what to fix.

## Sending Claude Code telemetry

Add this to `~/.claude/settings.json` (per developer) or to the managed
settings file for the whole team (`/etc/claude-code/managed-settings.json` on
Linux, `/Library/Application Support/ClaudeCode/managed-settings.json` on
macOS, `C:\Program Files\ClaudeCode\managed-settings.json` on Windows):

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "https://otel.example.com",
    "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Bearer <token>",
    "OTEL_METRICS_INCLUDE_REPOSITORY": "true"
  }
}
```

`OTEL_METRICS_INCLUDE_REPOSITORY` (Claude Code 2.1.269+) tags every session with
its git repository (`owner/name` from the `origin` remote), which powers the
**Repository** filter and the per-repository panels. Use the value `true`, not
`1`. Projects without a git `origin` remote appear as "(no repository)".

Keep Claude Code's default delta temporality: the dashboards ignore metrics
sent with `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative`.

Templates are in [client/](client/). Metrics are sent every 60 seconds and
events every 5 seconds, so a new session appears in Grafana within about a
minute.

Optional client settings:

| Setting | Effect |
|---|---|
| `OTEL_LOG_TOOL_DETAILS=1` | Real MCP server, skill and plugin names, and tool parameters (Bash commands, file paths) in events. |
| `OTEL_LOG_USER_PROMPTS=1` | Prompt text in events (off by default: prompts can contain secrets). |
| `OTEL_RESOURCE_ATTRIBUTES=team.id=backend` | Tag a team. **Required for identity** when using an API key, Bedrock or Vertex: then Claude Code sends no email, so set e.g. `user.email=alice@example.com` here. No spaces; comma-separated. |
| `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` + `OTEL_TRACES_EXPORTER=otlp` | Beta traces (one trace per prompt), stored in `otel.otel_traces` and viewable in Grafana Explore. |

## Dashboards

All in the **Claude Code** folder, filterable by **User** and **Repository**:

| Dashboard | Shows |
|---|---|
| Overview (home) | Total cost, tokens by type and model, cache hit rate, active users, sessions, API errors, cost by repository. |
| Sessions | One row per session: user, repository, start, duration, cost, prompts, tool calls, errors. Click a session for details. |
| Session Detail | The timeline of one session, grouped by prompt: API calls, tools and their durations, permission decisions, errors. |
| Team | Per-user and per-repository cost, tokens, sessions and active time. |
| Productivity | Lines added and removed, commits, pull requests, active time, edit accept/reject rate by language. |

Any other OpenTelemetry source can send to the same endpoint; its data lands in
the same tables (`otel.otel_logs`, `otel.otel_traces`, `otel.otel_metrics_*`)
and can be explored in Grafana.

## Requirements

- **RAM:** 2 GB is enough for a small team's Claude Code data. Add swap on a
  2 GB server. ClickHouse is capped at 45% of RAM.
- **CPU:** `linux/amd64` requires a CPU with AVX2 (x86-64-v3); `linux/arm64`
  requires ARMv8.2-A (Graviton 2+, Ampere, Apple Silicon; not Raspberry Pi 4).
- **Ports:** 80 and 443 reachable from the internet for Let's Encrypt.
- Do not run with `--cap-drop ALL` or `no-new-privileges`: Caddy binds ports
  80/443 as a non-root user through a file capability.

## Operations

- **Data:** everything lives in the `/data` volume (`clickhouse/`, `grafana/`,
  `caddy/` with certificates).
- **Backup:** stop the container and copy the volume, e.g.
  `docker run --rm -v otel-data:/data -v "$PWD":/backup debian tar czf /backup/otel-data.tgz /data`.
- **Query ClickHouse directly:** `docker exec -it otel clickhouse-client`.
- **Upgrade:** pull the new tag and recreate the container with the same volume.
- **Logs:** `docker logs otel`.

## Building

```sh
make build   # local architecture
make test    # build + end-to-end smoke test
make push IMAGE=<dockerhub-user>/otel-clickhouse-grafana VERSION=1.0.0   # amd64 + arm64
```

- Dashboards are generated: edit [dashboards/build.py](dashboards/build.py), run
  `python3 dashboards/build.py`, and commit the JSON it writes to
  `rootfs/etc/grafana/dashboards/`.
- [test/smoke.sh](test/smoke.sh) starts the image with a 2 GB memory limit and
  checks token auth, storage, retention, Grafana login and provisioning, that
  every dashboard query runs, network exposure, process restarts, persistence,
  password and retention changes on an existing volume, and HTTPS.
- `make push` builds arm64 under QEMU for the final stage (downloads and the
  collector are cross-built natively). On a machine without QEMU, register it
  once with `docker run --privileged --rm tonistiigi/binfmt --install arm64`
  and use a `docker-container` buildx builder.
- [.github/workflows/release.yml](.github/workflows/release.yml) tests and
  publishes on every `v*.*.*` tag. It needs the `DOCKERHUB_TOKEN` repository
  secret; `DOCKERHUB_USERNAME` (variable or secret) is optional and defaults to
  the GitHub repository owner.

## Licenses

This repository: Apache-2.0. Bundled software keeps its own license:
ClickHouse, OpenTelemetry Collector, Caddy and the ClickHouse Grafana plugin
are Apache-2.0; s6-overlay is ISC; **Grafana is AGPL-3.0**.
