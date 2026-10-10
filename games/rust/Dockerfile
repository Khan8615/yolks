# syntax=docker/dockerfile:1

FROM --platform=$TARGETOS/$TARGETARCH debian:bookworm-slim

LABEL org.opencontainers.image.title="RustSentinel"
LABEL org.opencontainers.image.description="Rust Dedicated Server for Pterodactyl using SteamCMD"
LABEL org.opencontainers.image.source="https://wiki.facepunch.com/rust/Creating-a-server"

ENV DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------
# Runtime dependencies
# ------------------------------------------------------------

RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libc6 \
        libc6:i386 \
        libgcc-s1 \
        libgcc-s1:i386 \
        libstdc++6 \
        libstdc++6:i386 \
        libglib2.0-0 \
        libcurl4 \
        libcurl3-gnutls \
        libssl3 \
        libssl3:i386 \
        libnss3 \
        zlib1g \
        zlib1g:i386 \
        liblzma5 \
        libunwind8 \
        libuuid1 \
        libatomic1 \
        tini \
        bash \
        curl \
        wget \
        unzip \
        file \
        iproute2 \
        procps \
        tar \
        gzip \
        coreutils \
        findutils \
    && rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------
# SteamCMD
# SteamCMD is kept outside /home/container so Pterodactyl
# server regeneration cannot remove it.
# ------------------------------------------------------------

RUN mkdir -p /opt/steamcmd \
    && cd /opt/steamcmd \
    && curl -fsSL \
        "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
        -o steamcmd_linux.tar.gz \
    && tar -xzf steamcmd_linux.tar.gz \
    && rm -f steamcmd_linux.tar.gz \
    && chmod +x /opt/steamcmd/steamcmd.sh \
    && chown -R 1000:1000 /opt/steamcmd

# ------------------------------------------------------------
# Pterodactyl user
# ------------------------------------------------------------

RUN useradd \
    --create-home \
    --uid 1000 \
    --shell /bin/bash \
    container

# ------------------------------------------------------------
# Pterodactyl environment
# ------------------------------------------------------------

ENV USER=container
ENV HOME=/home/container

WORKDIR /home/container

# ------------------------------------------------------------
# Entrypoint
# ------------------------------------------------------------

COPY --chmod=755 entrypoint.sh /entrypoint.sh

# ------------------------------------------------------------
# Runtime permissions
# ------------------------------------------------------------

RUN mkdir -p /home/container \
    && chown -R container:container \
        /home/container \
        /opt/steamcmd \
        /entrypoint.sh

USER container

# ------------------------------------------------------------
# Entrypoint
# ------------------------------------------------------------

ENTRYPOINT ["/usr/bin/tini", "-g", "--"]

CMD ["/entrypoint.sh"]
