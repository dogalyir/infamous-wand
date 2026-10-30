# syntax=docker/dockerfile:1
# cliproxy-rs con el binario precompilado del release (sin compilar Rust).

# ---- Descarga y verificación ----
FROM debian:bookworm-slim AS fetch
ARG CLIPROXY_VERSION=0.4.0
ARG TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) T=x86_64-unknown-linux-gnu ;; \
      arm64) T=aarch64-unknown-linux-gnu ;; \
      *) echo "Arquitectura no soportada: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    N="cliproxy-${CLIPROXY_VERSION}-${T}"; \
    B="https://github.com/vayungodara/cliproxy-rs/releases/download/v${CLIPROXY_VERSION}"; \
    curl -fsSL --retry 3 -o "$N.tar.gz" "$B/$N.tar.gz"; \
    curl -fsSL --retry 3 -o SHA256SUMS "$B/SHA256SUMS"; \
    grep " $N.tar.gz\$" SHA256SUMS | sha256sum -c -; \
    tar -xzf "$N.tar.gz"; \
    install -m 0755 "$N/cliproxy" /usr/local/bin/cliproxy; \
    /usr/local/bin/cliproxy --version

# ---- Runtime ----
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10001 cliproxy \
 && useradd --system --uid 10001 --gid 10001 --home-dir /data --shell /usr/sbin/nologin cliproxy \
 && mkdir -p /data/auth \
 && chown -R cliproxy:cliproxy /data
COPY --from=fetch /usr/local/bin/cliproxy /usr/local/bin/cliproxy

# Crea /data/config.yaml en el primer arranque a partir de variables de entorno.
COPY --chmod=0755 <<'EOF' /usr/local/bin/entrypoint.sh
#!/bin/sh
set -eu
CONFIG=/data/config.yaml
mkdir -p /data/auth
if [ ! -f "$CONFIG" ]; then
  if [ -z "${CLIPROXY_CLIENT_KEY:-}" ] || [ -z "${CLIPROXY_MANAGEMENT_KEY:-}" ]; then
    echo "Primer arranque: define CLIPROXY_CLIENT_KEY y CLIPROXY_MANAGEMENT_KEY" >&2
    exit 1
  fi
  cat > "$CONFIG" <<CFG
server:
  host: "0.0.0.0"
  port: 8317
access:
  api-keys:
    - "${CLIPROXY_CLIENT_KEY}"
management:
  secret-key: "${CLIPROXY_MANAGEMENT_KEY}"
  allow-remote: true
oauth:
  auth-dir: "/data/auth"
CFG
  echo "config.yaml creado en $CONFIG"
fi
exec cliproxy --config "$CONFIG" "$@"
EOF

USER cliproxy
WORKDIR /data
EXPOSE 8317
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8317/healthz || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
