# ============================================================
# Base
# ============================================================
FROM debian:stable-slim AS base

ARG MCRCON_VERSION=0.7.2
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get -y upgrade && apt-get install -y --no-install-recommends \
    bash curl ca-certificates tini procps \
    pciutils ocl-icd-libopencl1 jq unzip \
 && rm -rf /var/lib/apt/lists/*

# --- mcrcon (static) ---
RUN set -eux; \
    curl -fsSL "https://github.com/Tiiffi/mcrcon/releases/download/v${MCRCON_VERSION}/mcrcon-${MCRCON_VERSION}-linux-x86-64-static.zip" -o /tmp/mcrcon.zip; \
    mkdir -p /tmp/mcrcon; \
    unzip -q /tmp/mcrcon.zip -d /tmp/mcrcon; \
    mcrcon_path="$(find /tmp/mcrcon -type f -name mcrcon | head -n 1)"; \
    test -n "${mcrcon_path}"; \
    install -m 0755 "${mcrcon_path}" /usr/local/bin/mcrcon; \
    rm -rf /tmp/mcrcon /tmp/mcrcon.zip; \
    /usr/local/bin/mcrcon -h || true

# ============================================================
# Runtime base
# ============================================================
FROM debian:stable-slim AS runtime-base

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get -y upgrade && apt-get install -y --no-install-recommends \
    bash curl ca-certificates tini procps tzdata \
    pciutils ocl-icd-libopencl1 jq unzip tar \
    rsync libpopt0 awscli \
 && rm -rf /var/lib/apt/lists/*

COPY scripts/lib /scripts/lib
# ============================================================
# Java base images
# ============================================================
FROM eclipse-temurin:8-jre  AS jre8
FROM eclipse-temurin:11-jre AS jre11
FROM eclipse-temurin:17-jre AS jre17
FROM eclipse-temurin:21-jre AS jre21
FROM eclipse-temurin:25-jre AS jre25

# ============================================================
# Runtime images (CPU)
# ============================================================

# -------- Java 8 --------
FROM runtime-base AS runtime-jre8

# --- Java 8 ---
COPY --from=jre8 /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"
COPY --from=base /usr/local/bin/mcrcon /usr/local/bin/mcrcon
COPY entrypoint.sh /entrypoint.sh
ARG UID=10001
ARG GID=10001

RUN chmod 0755 /entrypoint.sh \
 && chmod 0755 /usr/local/bin/mcrcon

RUN groupadd -g ${GID} mc \
 && useradd -m -u ${UID} -g ${GID} -s /bin/bash mc \
 && mkdir -p /data /mods /plugins /config /datapacks /resourcepacks \
 && chown -R mc:mc /data /mods /plugins /config /datapacks /resourcepacks

USER mc:mc
ENV HOME=/data
WORKDIR /data
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["run"]

# -------- Java 11 --------
FROM runtime-base AS runtime-jre11

# --- Java 11 ---
COPY --from=jre11 /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"
COPY --from=base /usr/local/bin/mcrcon /usr/local/bin/mcrcon
COPY entrypoint.sh /entrypoint.sh
ARG UID=10001
ARG GID=10001

RUN chmod 0755 /entrypoint.sh \
 && chmod 0755 /usr/local/bin/mcrcon

RUN groupadd -g ${GID} mc \
 && useradd -m -u ${UID} -g ${GID} -s /bin/bash mc \
 && mkdir -p /data /mods /plugins /config /datapacks /resourcepacks \
 && chown -R mc:mc /data /mods /plugins /config /datapacks /resourcepacks

USER mc:mc
ENV HOME=/data
WORKDIR /data
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["run"]

# -------- Java 17 --------
FROM runtime-base AS runtime-jre17

# --- Java 17 ---
COPY --from=jre17 /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"
COPY --from=base /usr/local/bin/mcrcon /usr/local/bin/mcrcon
COPY entrypoint.sh /entrypoint.sh
ARG UID=10001
ARG GID=10001

RUN chmod 0755 /entrypoint.sh \
 && chmod 0755 /usr/local/bin/mcrcon

RUN groupadd -g ${GID} mc \
 && useradd -m -u ${UID} -g ${GID} -s /bin/bash mc \
 && mkdir -p /data /mods /plugins /config /datapacks /resourcepacks \
 && chown -R mc:mc /data /mods /plugins /config /datapacks /resourcepacks

USER mc:mc
ENV HOME=/data
WORKDIR /data
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["run"]

# -------- Java 21 --------
FROM runtime-base AS runtime-jre21

# --- Java 21 ---
COPY --from=jre21 /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"
COPY --from=base /usr/local/bin/mcrcon /usr/local/bin/mcrcon
COPY entrypoint.sh /entrypoint.sh
ARG UID=10001
ARG GID=10001

RUN chmod 0755 /entrypoint.sh \
 && chmod 0755 /usr/local/bin/mcrcon

RUN groupadd -g ${GID} mc \
 && useradd -m -u ${UID} -g ${GID} -s /bin/bash mc \
 && mkdir -p /data /mods /plugins /config /datapacks /resourcepacks \
 && chown -R mc:mc /data /mods /plugins /config /datapacks /resourcepacks

USER mc:mc
ENV HOME=/data
WORKDIR /data
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["run"]

# -------- Java 25 --------
FROM runtime-base AS runtime-jre25

# --- Java 25 ---
COPY --from=jre25 /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"
COPY --from=base /usr/local/bin/mcrcon /usr/local/bin/mcrcon
COPY entrypoint.sh /entrypoint.sh
ARG UID=10001
ARG GID=10001

RUN chmod 0755 /entrypoint.sh \
 && chmod 0755 /usr/local/bin/mcrcon

RUN groupadd -g ${GID} mc \
 && useradd -m -u ${UID} -g ${GID} -s /bin/bash mc \
 && mkdir -p /data /mods /plugins /config /datapacks /resourcepacks \
 && chown -R mc:mc /data /mods /plugins /config /datapacks /resourcepacks

USER mc:mc
ENV HOME=/data
WORKDIR /data
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["run"]

# ============================================================
# GPU runtime (Java 25 only)
# ============================================================
FROM nvidia/cuda:13.3.1-runtime-ubuntu24.04 AS runtime-jre25-gpu

ENV DEBIAN_FRONTEND=noninteractive
ARG AWS_CLI_VERSION=2.23.6

RUN apt-get update && apt-get -y upgrade && apt-get install -y --no-install-recommends \
    bash ca-certificates curl tini procps tzdata \
    pciutils ocl-icd-libopencl1 clinfo jq unzip rsync libpopt0 \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "${arch}" in \
      amd64) aws_arch="x86_64" ;; \
      arm64) aws_arch="aarch64" ;; \
      *) echo "Unsupported architecture for AWS CLI: ${arch}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}-${AWS_CLI_VERSION}.zip" -o /tmp/awscliv2.zip; \
    unzip -q /tmp/awscliv2.zip -d /tmp; \
    /tmp/aws/install; \
    rm -rf /tmp/aws /tmp/awscliv2.zip; \
    aws_version="$(aws --version 2>&1)"; \
    echo "${aws_version}"; \
    case "${aws_version}" in \
      aws-cli/${AWS_CLI_VERSION}\ *) ;; \
      *) echo "Unexpected AWS CLI version: ${aws_version}" >&2; exit 1 ;; \
    esac

# LWJGL expects libOpenCL.so (not only libOpenCL.so.1)
RUN set -eux; \
    if [ -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ] && [ ! -e /usr/lib/x86_64-linux-gnu/libOpenCL.so ]; then \
      ln -s /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 /usr/lib/x86_64-linux-gnu/libOpenCL.so; \
    fi

# --- Java 25 ---
COPY --from=eclipse-temurin:25-jre /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# --- entrypoint ---
COPY --from=base /usr/local/bin/mcrcon /usr/local/bin/mcrcon
COPY entrypoint.sh /entrypoint.sh
COPY scripts/lib /scripts/lib

ENV RUNTIME_FLAVOR=gpu
ENV ENABLE_C2ME_OPENCL=true

ARG UID=10001
ARG GID=10001

RUN chmod 0755 /entrypoint.sh \
 && chmod 0755 /usr/local/bin/mcrcon

RUN groupadd -g ${GID} mc \
 && useradd -m -u ${UID} -g ${GID} -s /bin/bash mc \
 && mkdir -p /data /mods /plugins /config /datapacks /resourcepacks \
 && chown -R mc:mc /data /mods /plugins /config /datapacks /resourcepacks

USER mc:mc
ENV HOME=/data
WORKDIR /data

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["run"]
