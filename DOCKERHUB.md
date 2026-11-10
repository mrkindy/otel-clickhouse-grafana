# otel-clickhouse-grafana

**A complete OpenTelemetry backend in one container.** Send OTLP traces, metrics
and logs over HTTPS. They are stored in ClickHouse and shown in Grafana, with
ready-made dashboards for **Claude Code** usage: cost, tokens, sessions, team
and productivity.

- **One `docker run`:** collector, database, dashboards and automatic HTTPS (Let's Encrypt).
- **Secure by default:** token-protected ingestion, no anonymous Grafana, internal services on localhost only.
- **Runs on a 2 GB server**, with ClickHouse tuned for small machines.
- **Self-healing:** every process is supervised and restarted if it crashes.

Source, issues and full documentation: **https://github.com/mrkindy/otel-clickhouse-grafana**

---

## Tags and platforms

| Tag | Meaning |
|---|---|
| `latest` | Latest stable release |
| `1.0.0` | Exact version |
| `1.0` | Latest patch of 1.0 |

Platforms: `linux/amd64`, `linux/arm64`

## What's inside

```
internet ──443/80──> Caddy (automatic HTTPS)
                       ├─ /v1/*  ──> OpenTelemetry Collector ──┐  (Bearer token check)
                       ├─ gRPC   ──> OpenTelemetry Collector ──┤
                       └─ else   ──> Grafana                   ▼
                                       └── read-only ──> ClickHouse
```

| Component | Version |
|---|---|
| ClickHouse (LTS) | 26.8.36.3 |
| Grafana OSS + ClickHouse datasource | 13.3.0 / 4.23.5 |
| OpenTelemetry Collector (slim custom build) | 0.165.0 |
| Caddy | 2.11.9 |
| s6-overlay (process supervisor) | 3.2.3.2 |

## Quick start

### On a server with a domain

Point a DNS `A` record at the server and open ports 80 and 443:

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

> **Forgot the token or password?** When `DOMAIN` is set, the container never
> runs open. Missing values are generated and kept on the volume, and are never
> printed to the logs. Read them with:
> ```sh
> docker exec otel cat /data/secrets/otlp_token
> docker exec otel cat /data/secrets/grafana_admin_password
> ```

While testing a new domain, add `-e ACME_STAGING=1` to avoid Let's Encrypt
rate limits.

### Locally, to try it out

```sh
docker run -d --name otel -p 8080:80 -v otel-data:/data mrkindy/otel-clickhouse-grafana:latest
```

Grafana is at `http://localhost:8080` (`admin` / `admin`). Without `DOMAIN`
the container serves plain HTTP. OTLP accepts data from anyone who can reach
it unless you set `OTLP_TOKENS`.

### Docker Compose

```yaml
services:
  otel:
    image: mrkindy/otel-clickhouse-grafana:latest
    restart: unless-stopped
    stop_grace_period: 30s
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - otel-data:/data
    environment:
      DOMAIN: otel.example.com
      ACME_EMAIL: you@example.com
      OTLP_TOKENS: ${OTLP_TOKENS}
      GRAFANA_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}

volumes:
  otel-data:
```

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `DOMAIN` | unset | Public hostname, enabling automatic HTTPS. `localhost` uses a self-signed certificate. Unset means plain HTTP on port 80. |
| `ACME_EMAIL` | unset | Contact email for Let's Encrypt. |
| `ACME_STAGING` | `0` | `1` uses the Let's Encrypt staging server while testing. |
| `OTLP_TOKENS` | unset | Comma-separated accepted tokens, one per developer. Remove one and recreate the container to revoke it. |
| `GRAFANA_ADMIN_PASSWORD` | unset | Grafana `admin` password, at least 8 characters. Applied on every start. |
| `RETENTION_DAYS` | `30` | How long data is kept. A change also applies to existing data. |
| `CLICKHOUSE_MEMORY_RATIO` | `0.45` | Share of RAM that ClickHouse may use. |
| `GF_*` | | Any Grafana setting, e.g. `GF_SERVER_ROOT_URL`. |

Invalid values, such as `DOMAIN=https://…`, a short password or a token with a
space, stop the container at startup with a clear message in `docker logs`.

| Port | Use |
|---|---|
| `80` | HTTP, ACME challenge, redirect to HTTPS |
| `443` | HTTPS: Grafana, OTLP/HTTP (`/v1/traces`, `/v1/metrics`, `/v1/logs`) and OTLP/gRPC |

| Path | Use |
|---|---|
| `/data` | **Mount a volume here.** ClickHouse data, Grafana database, TLS certificates, generated secrets. |

## Sending Claude Code telemetry

Add this to `~/.claude/settings.json` for one developer, or to the managed
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
    "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Bearer <token>"
  }
}
```

New sessions appear in Grafana within about a minute.

Optional client settings:

| Setting | Effect |
|---|---|
| `OTEL_LOG_TOOL_DETAILS=1` | Real MCP, skill and plugin names, plus tool parameters, in events. |
| `OTEL_LOG_USER_PROMPTS=1` | Prompt text in events. Off by default because prompts can contain secrets. |
| `OTEL_RESOURCE_ATTRIBUTES=team.id=backend` | Tag a team. With an API key, Bedrock or Vertex, add `user.email=…` here so users can be told apart. |

Keep Claude Code's default *delta* metrics temporality. The dashboards ignore
cumulative metrics.

## Dashboards

Everything below is in the **Claude Code** folder in Grafana.

| Dashboard | Shows |
|---|---|
| **Overview** | Total cost, tokens by type and model, cache hit rate, active users, sessions, API errors |
| **Sessions** | One row per session: user, duration, cost, prompts, tool calls, errors. Click a session to open it. |
| **Session Detail** | The full timeline of one session, grouped by prompt: API calls, tools and their durations, permission decisions, errors |
| **Team** | Cost, tokens, sessions and active time per developer |
| **Productivity** | Lines added and removed, commits, pull requests, active time, edit accept rate by language |

## Other applications

Any OpenTelemetry SDK or collector can send to the same endpoint. Point it at
`https://<DOMAIN>` with the header `Authorization: Bearer <token>`, over
`http/protobuf` or `grpc`. Data lands in `otel.otel_traces`, `otel.otel_logs`
and `otel.otel_metrics_*`, which you can query in Grafana **Explore**,
including the trace view.

## Requirements

- **RAM:** 2 GB is enough for a small team's Claude Code data. Add swap on a 2 GB server.
- **CPU:** amd64 needs AVX2 (x86-64-v3). arm64 needs ARMv8.2-A, such as Graviton 2+, Ampere or Apple Silicon; Raspberry Pi 4 is not supported.
- **Network:** ports 80 and 443 reachable from the internet for Let's Encrypt.
- Don't run with `--cap-drop ALL` or `no-new-privileges`: Caddy needs a file capability to bind ports 80 and 443 as a non-root user.

## Operations

| Task | Command |
|---|---|
| Logs | `docker logs otel` |
| Health | `docker inspect -f '{{.State.Health.Status}}' otel` |
| Query ClickHouse | `docker exec -it otel clickhouse-client` |
| Backup | Stop the container, then `docker run --rm -v otel-data:/data -v "$PWD":/backup debian tar czf /backup/otel-data.tgz /data` |
| Upgrade | `docker pull mrkindy/otel-clickhouse-grafana:latest`, then recreate the container with the same volume |

Keep the `/data` volume across upgrades. It also holds the TLS certificates,
and losing them means requesting new ones, which Let's Encrypt limits to 5
per domain per week.

## License

The image's own files are Apache-2.0. Bundled software keeps its own license:
ClickHouse, the OpenTelemetry Collector, Caddy and the ClickHouse Grafana
plugin are Apache-2.0, s6-overlay is ISC, and **Grafana is AGPL-3.0**.

Not affiliated with Anthropic, Grafana Labs or ClickHouse, Inc.
