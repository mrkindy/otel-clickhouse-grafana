# syntax=docker/dockerfile:1.7
#
# otel-clickhouse-grafana: one container that receives OpenTelemetry (OTLP),
# stores it in ClickHouse and shows it in Grafana, behind Caddy (automatic HTTPS).
# Processes are supervised by s6-overlay.

ARG DEBIAN_IMAGE=debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2
ARG GO_IMAGE=golang:1.27.4-bookworm

ARG CLICKHOUSE_VERSION=26.8.36.3
ARG GRAFANA_VERSION=13.3.0
ARG CH_PLUGIN_VERSION=4.23.5
ARG CH_PLUGIN_SHA256_AMD64=c1d661a92f49fb360ce08091bbdcba8f1c47fca578ceb55289028e6f57a2088b
ARG CH_PLUGIN_SHA256_ARM64=7fc8c084d3d2318660671124a9b0981bf43233e0f95b7cb8e0eaecd664d9e8e7
ARG CADDY_VERSION=2.11.9
ARG S6_OVERLAY_VERSION=3.2.3.2
ARG OTELCOL_VERSION=0.165.0

# ---------------------------------------------------------------------------
# Downloads run on the build machine's own architecture (no emulation) and
# fetch the binaries for TARGETARCH. Every download is checksum-verified.
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM ${DEBIAN_IMAGE} AS downloader
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils unzip \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /dl
ARG TARGETARCH
ARG CLICKHOUSE_VERSION GRAFANA_VERSION CH_PLUGIN_VERSION CH_PLUGIN_SHA256_AMD64 CH_PLUGIN_SHA256_ARM64
ARG CADDY_VERSION S6_OVERLAY_VERSION
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# ClickHouse: static binary + stock config.xml/users.xml (overridden by config.d/users.d).
RUN base="https://packages.clickhouse.com/tgz/lts"; \
    for pkg in clickhouse-common-static clickhouse-server; do \
      f="${pkg}-${CLICKHOUSE_VERSION}-${TARGETARCH}.tgz"; \
      curl -fsSLO "${base}/${f}"; curl -fsSLO "${base}/${f}.sha512"; \
      sha512sum -c "${f}.sha512"; tar xzf "${f}"; \
    done; \
    mkdir -p /out/usr/bin /out/etc/clickhouse-server; \
    install -m 0755 "clickhouse-common-static-${CLICKHOUSE_VERSION}/usr/bin/clickhouse" /out/usr/bin/clickhouse; \
    cp "clickhouse-server-${CLICKHOUSE_VERSION}/etc/clickhouse-server/config.xml" \
       "clickhouse-server-${CLICKHOUSE_VERSION}/etc/clickhouse-server/users.xml" /out/etc/clickhouse-server/; \
    rm -rf clickhouse-*

# Grafana OSS + ClickHouse datasource plugin (installed outside the /data volume).
RUN f="grafana-${GRAFANA_VERSION}.linux-${TARGETARCH}.tar.gz"; \
    curl -fsSLO "https://dl.grafana.com/oss/release/${f}"; \
    echo "$(curl -fsSL "https://dl.grafana.com/oss/release/${f}.sha256")  ${f}" | sha256sum -c; \
    mkdir -p /out/usr/share/grafana; tar xzf "${f}" --strip-components=1 -C /out/usr/share/grafana; rm "${f}"; \
    rm -rf /out/usr/share/grafana/conf/provisioning; \
    case "${TARGETARCH}" in amd64) sum="${CH_PLUGIN_SHA256_AMD64}";; arm64) sum="${CH_PLUGIN_SHA256_ARM64}";; *) exit 1;; esac; \
    curl -fsSL -o plugin.zip "https://grafana.com/api/plugins/grafana-clickhouse-datasource/versions/${CH_PLUGIN_VERSION}/download?os=linux&arch=${TARGETARCH}"; \
    echo "${sum}  plugin.zip" | sha256sum -c; \
    mkdir -p /out/usr/share/grafana-plugins; unzip -q plugin.zip -d /out/usr/share/grafana-plugins; rm plugin.zip

# Caddy.
RUN f="caddy_${CADDY_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    curl -fsSLO "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/${f}"; \
    curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_checksums.txt" \
      | grep " ${f}\$" | sha512sum -c; \
    tar xzf "${f}" caddy; install -m 0755 caddy /out/usr/bin/caddy; rm -f caddy "${f}"

# s6-overlay (its tarballs unpack relative to /).
RUN case "${TARGETARCH}" in amd64) s6arch=x86_64;; arm64) s6arch=aarch64;; *) exit 1;; esac; \
    mkdir -p /s6root; \
    for f in s6-overlay-noarch.tar.xz "s6-overlay-${s6arch}.tar.xz"; do \
      curl -fsSLO "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/${f}"; \
      curl -fsSLO "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/${f}.sha256"; \
      sha256sum -c "${f}.sha256"; tar -C /s6root -Jxpf "${f}"; rm "${f}" "${f}.sha256"; \
    done

# Trim: like Grafana's -slim image, drop bundled datasources we don't use (~550 MB; the
# canvas panel stays because Grafana expects it)
# and browser source maps (~160 MB). Caddy is moved out of /out so the final stage
# can install it and set its capability in a single layer.
RUN find /out/usr/share/grafana/data/plugins-bundled -mindepth 1 -maxdepth 1 ! -name canvas -exec rm -rf {} + \
 && find /out/usr/share/grafana/public -name '*.map' -delete \
 && mv /out/usr/bin/caddy /caddy

# ---------------------------------------------------------------------------
# Slim OpenTelemetry Collector built with ocb: only the components we use.
# Cross-compiled for TARGETARCH with CGO disabled (no emulation needed).
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS otelcol
ARG BUILDARCH TARGETARCH OTELCOL_VERSION
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
WORKDIR /build
RUN f="ocb_${OTELCOL_VERSION}_linux_${BUILDARCH}"; \
    base="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/cmd%2Fbuilder%2Fv${OTELCOL_VERSION}"; \
    curl -fsSLO "${base}/${f}"; \
    echo "$(curl -fsSL "${base}/${f}.sha256" | cut -d' ' -f1)  ${f}" | sha256sum -c; \
    install -m 0755 "${f}" /usr/local/bin/ocb
COPY otelcol-builder.yaml .
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    # Each attempt is time-limited: a stalled module download would otherwise hang the build forever.
    for attempt in 1 2 3; do \
      CGO_ENABLED=0 GOOS=linux GOARCH="${TARGETARCH}" timeout 900 ocb --config otelcol-builder.yaml && break; \
      [ "${attempt}" = 3 ] && exit 1; echo "ocb failed (attempt ${attempt}), retrying"; sleep 10; \
    done; \
    install -m 0755 _build/otelcol /otelcol

# ---------------------------------------------------------------------------
# Final image.
# ---------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE}
ARG CLICKHOUSE_VERSION GRAFANA_VERSION CADDY_VERSION OTELCOL_VERSION S6_OVERLAY_VERSION
LABEL org.opencontainers.image.title="otel-clickhouse-grafana" \
      org.opencontainers.image.description="All-in-one OpenTelemetry backend: OTLP collector, ClickHouse and Grafana behind Caddy (automatic HTTPS), with Claude Code dashboards." \
      org.opencontainers.image.licenses="Apache-2.0" \
      io.otel-clickhouse-grafana.clickhouse="${CLICKHOUSE_VERSION}" \
      io.otel-clickhouse-grafana.grafana="${GRAFANA_VERSION}" \
      io.otel-clickhouse-grafana.caddy="${CADDY_VERSION}" \
      io.otel-clickhouse-grafana.otelcol="${OTELCOL_VERSION}" \
      io.otel-clickhouse-grafana.s6-overlay="${S6_OVERLAY_VERSION}"

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl tzdata procps libcap2-bin \
 && rm -rf /var/lib/apt/lists/* \
 && for u in clickhouse grafana otelcol caddy; do useradd --system --no-create-home --shell /usr/sbin/nologin "$u"; done

COPY --from=downloader /s6root/ /
COPY --from=downloader /out/ /
COPY --from=otelcol /otelcol /usr/local/bin/otelcol
COPY rootfs/ /

# Caddy runs as a non-root user; the file capability lets it bind ports 80/443.
RUN --mount=type=bind,from=downloader,source=/caddy,target=/tmp/caddy \
    install -m 0755 /tmp/caddy /usr/bin/caddy \
 && setcap cap_net_bind_service=+ep /usr/bin/caddy \
 && ln -s /usr/bin/clickhouse /usr/bin/clickhouse-server \
 && ln -s /usr/bin/clickhouse /usr/bin/clickhouse-client \
 && ln -s /usr/share/grafana/bin/grafana /usr/bin/grafana \
 && chmod 0755 /etc/s6-overlay/scripts/* /usr/local/bin/*.sh \
 && find /etc/s6-overlay/s6-rc.d -name run -o -name check | xargs chmod 0755

ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_SERVICES_GRACETIME=15000 \
    S6_KILL_GRACETIME=5000 \
    S6_VERBOSITY=1 \
    XDG_DATA_HOME=/data \
    XDG_CONFIG_HOME=/run/caddy-config \
    RETENTION_DAYS=30 \
    CLICKHOUSE_MEMORY_RATIO=0.45 \
    ACME_STAGING=0 \
    GF_PATHS_HOME=/usr/share/grafana \
    GF_PATHS_DATA=/data/grafana \
    GF_PATHS_LOGS=/data/grafana/logs \
    GF_PATHS_PLUGINS=/usr/share/grafana-plugins \
    GF_PATHS_PROVISIONING=/etc/grafana/provisioning \
    GF_SERVER_HTTP_ADDR=127.0.0.1 \
    GF_SERVER_HTTP_PORT=3000 \
    GF_AUTH_ANONYMOUS_ENABLED=false \
    GF_USERS_ALLOW_SIGN_UP=false \
    GF_PLUGINS_PREINSTALL_DISABLED=true \
    GF_ANALYTICS_REPORTING_ENABLED=false \
    GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false \
    GF_NEWS_NEWS_FEED_ENABLED=false \
    GF_METRICS_ENABLED=false \
    GF_LOG_MODE=console \
    GF_LOG_LEVEL=warn \
    GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/etc/grafana/dashboards/claude-code-overview.json

EXPOSE 80 443
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --start-interval=3s --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]
ENTRYPOINT ["/init"]
