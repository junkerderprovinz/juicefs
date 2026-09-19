# syntax=docker/dockerfile:1.27@sha256:bde3983e9c939224420ddaf6b784cc30e09b035a4dea01f581230c50809f372e
# The JuiceFS S3 gateway in one container, with no second service required.
#
# JuiceFS keeps file metadata in a database and the contents in an object store.
# Upstream ships no image meant to be installed as a container: the documented
# routes are a Docker volume plugin, which Unraid cannot install from a
# template, and `juicedata/mount`, which expects the whole command line by hand.
# This image reads its settings from the environment, so each one is a field in
# the Unraid template, and creates the file system on first boot.
#
# GitHub:  https://github.com/junkerderprovinz/juicefs
# Image:   ghcr.io/junkerderprovinz/juicefs
# License: Apache-2.0

ARG JUICEFS_VERSION=1.4.1
ARG S6_OVERLAY_VERSION=3.2.0.2

# The fetch stage keeps the download tools and the tarball out of the final
# image. The checksums come from the release's checksums.txt and are pinned here
# so a re-tagged release cannot change what gets installed.
FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS fetch

ARG JUICEFS_VERSION
ARG TARGETARCH

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# A new version needs new checksums here; a mismatch fails the build.
RUN case "${TARGETARCH}" in \
        amd64) SHA="01ee09a21a9351a465e09906f113845e1c6a19bea70f530e5e2b2125b2dd3b82" ;; \
        arm64) SHA="1015ade83a7a93180a29f6c93ee5780a3eda52522331934ef2ef0cc0921995fd" ;; \
        *)     echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && URL="https://github.com/juicedata/juicefs/releases/download/v${JUICEFS_VERSION}/juicefs-${JUICEFS_VERSION}-linux-${TARGETARCH}.tar.gz" \
    && curl -fsSL -o /tmp/juicefs.tar.gz "${URL}" \
    && echo "${SHA}  /tmp/juicefs.tar.gz" | sha256sum -c - \
    && tar -C /tmp -xzf /tmp/juicefs.tar.gz juicefs \
    && install -m 0755 /tmp/juicefs /usr/local/bin/juicefs \
    && /usr/local/bin/juicefs --version

FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171

ARG S6_OVERLAY_VERSION
ARG TARGETARCH
ARG JUICEFS_VERSION

LABEL org.opencontainers.image.title="JuiceFS" \
      org.opencontainers.image.description="JuiceFS S3 gateway, plug-and-play for Unraid" \
      org.opencontainers.image.source="https://github.com/junkerderprovinz/juicefs" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="${JUICEFS_VERSION}" \
      org.opencontainers.image.vendor="junkerderprovinz" \
      maintainer="junkerderprovinz"

# hadolint ignore=DL3002
USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# - gosu:        drop to PUID:PGID in the service scripts
# - openssl:     generate a secret key when the user supplied none
# - ca-certificates, curl: health checks and remote object stores over TLS
# - tzdata:      TZ env var support
# - xz-utils:    decompress the s6-overlay archives
# - sqlite3:     the default metadata engine, and lets a user inspect the file
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        gosu \
        openssl \
        ca-certificates \
        curl \
        tzdata \
        xz-utils \
        sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# Install s6-overlay v3 (init system + process supervisor).
RUN case "${TARGETARCH}" in \
        amd64)  S6_ARCH="x86_64"   ;; \
        arm64)  S6_ARCH="aarch64"  ;; \
        arm)    S6_ARCH="arm"      ;; \
        *)      echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && S6_BASE="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}" \
    && curl -fsSL "${S6_BASE}/s6-overlay-noarch.tar.xz"     | tar -C / -Jxp \
    && curl -fsSL "${S6_BASE}/s6-overlay-${S6_ARCH}.tar.xz" | tar -C / -Jxp

COPY --from=fetch /usr/local/bin/juicefs /usr/local/bin/juicefs

RUN chmod +x /usr/local/bin/juicefs \
    && mkdir -p /data /config

# CR is stripped so a Windows checkout cannot break the init-log banner.
COPY .github/assets/banner-raw.txt /usr/local/share/banner-raw.txt
RUN tr -d '\r' < /usr/local/share/banner-raw.txt > /usr/local/share/banner.txt

COPY rootfs/ /
RUN chmod +x /usr/local/bin/print-banner.sh \
    /etc/cont-init.d/10-config.sh \
    /etc/services.d/juicefs/run \
    /etc/services.d/juicefs-ready/run

# A failing init step stops the container. s6-overlay's default carries on, and
# the gateway would then restart about once a second while the container still
# showed as running.
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2

# The S3 gateway. Nothing else is served, and nothing else needs publishing.
EXPOSE 9000

# Shows a container that is up but not serving as unhealthy in Unraid and in
# `docker ps`. An unauthenticated request gets 403, which still proves the
# listener is there.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    # Exec form with an explicit shell: the probe needs one for the
    # substitution, and the lint gate wants it named.
    CMD ["sh", "-c", "c=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9000); [ \"$c\" = \"200\" ] || [ \"$c\" = \"403\" ]"]

# With the defaults, /config holds the SQLite metadata database and /data the
# object store, so the database can sit on fast storage and the blobs on the
# array. The read cache in /cache grows to whatever the free-space ratio
# allows, which is why it is a volume and not the container's own layer.
VOLUME ["/data", "/config", "/cache"]

ENTRYPOINT ["/init"]
