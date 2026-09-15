# syntax=docker/dockerfile:1.27@sha256:bde3983e9c939224420ddaf6b784cc30e09b035a4dea01f581230c50809f372e
# =============================================================================
# JuiceFS — the JuiceFS S3 gateway, one container, no second service required
#
# JuiceFS keeps file metadata in a database and the file contents in an object
# store. Upstream ships no image meant to be installed as a container: the
# documented routes are a Docker volume plugin (which Unraid cannot install
# from a template) and `juicedata/mount`, which expects the whole command line
# to be given by hand. This image exists to close that gap. It reads its
# settings from the environment, so every one of them is a field in the Unraid
# template, and it creates the file system on first boot instead of asking for
# a console step.
#
# The binary is taken from the upstream release and checked against the
# published SHA256, not copied out of a third-party image.
#
# GitHub:  https://github.com/junkerderprovinz/juicefs
# Image:   ghcr.io/junkerderprovinz/juicefs
# License: Apache-2.0
# =============================================================================

ARG JUICEFS_VERSION=1.4.1
ARG S6_OVERLAY_VERSION=3.2.0.2

# -----------------------------------------------------------------------------
# Stage 1 — fetch and verify the official binary
#
# Separate stage so the download tools and the tarball never reach the final
# image. The checksums come from the release's own checksums.txt; they are
# pinned here so a re-tagged release cannot change what gets installed.
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS fetch

ARG JUICEFS_VERSION
ARG TARGETARCH

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# One checksum per architecture. A new version means new lines here, and the
# build fails loudly if they do not match, which is the point.
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

# -----------------------------------------------------------------------------
# Stage 2 — final image
# -----------------------------------------------------------------------------
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

# Init-log banner: single source at .github/assets/banner-raw.txt, CR stripped
# so the log shows it cleanly. Printed by the ready service as the last block.
COPY .github/assets/banner-raw.txt /usr/local/share/banner-raw.txt
RUN tr -d '\r' < /usr/local/share/banner-raw.txt > /usr/local/share/banner.txt

COPY rootfs/ /
RUN chmod +x /usr/local/bin/print-banner.sh \
    /etc/cont-init.d/10-config.sh \
    /etc/services.d/juicefs/run \
    /etc/services.d/juicefs-ready/run

# A failing init step must stop the container. Without this, s6-overlay's
# default is to carry on quietly: the init script would exit 1, say the gateway
# will not start, and the gateway would then restart about once a second
# forever while the container still showed as running.
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2

# The S3 gateway. Nothing else is served, and nothing else needs publishing.
EXPOSE 9000

# So a container that is up but not serving is visible as such, in Unraid's
# docker tab and in `docker ps`. An unauthenticated request is refused with 403,
# which still proves the listener is there, so the status code is what counts.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    # Exec form with the shell as the first argument rather than implied: the
    # probe needs a shell for the substitution and the test, and naming it is
    # what the lint gate on the push hook asks for.
    CMD ["sh", "-c", "c=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9000); [ \"$c\" = \"200\" ] || [ \"$c\" = \"403\" ]"]

# /config holds the metadata database when the default SQLite engine is used;
# /data holds the object store when the default local backend is used. Both are
# separate so a user can put the database on fast storage and the blobs on the
# array.
#
# /cache is where the read cache goes. It is a volume rather than a directory in
# the container's own layer, because the cache grows to whatever the free-space
# ratio allows and that layer is the worst place for it.
VOLUME ["/data", "/config", "/cache"]

ENTRYPOINT ["/init"]
