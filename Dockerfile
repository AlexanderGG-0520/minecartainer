# syntax=docker/dockerfile:1

# ============================================================
# Azul Zulu repository metadata
# ============================================================
FROM debian:13-slim AS zulu-repo

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
    GNUPGHOME="$(mktemp -d)"; \
    export GNUPGHOME; \
    curl -fsSL https://repos.azul.com/azul-repo.key | gpg --batch --import; \
    gpg --batch --export --armor '27BC 0C8C B3D8 1623 F59B DADC B199 8361 219B D9C9' > /azul.pgp.asc; \
    printf '%s\n' 'deb [signed-by=/usr/share/keyrings/azul.pgp.asc] https://repos.azul.com/zulu/deb stable main' > /zulu.list; \
    gpgconf --kill all; \
    rm -rf "${GNUPGHOME}" /var/lib/apt/lists/*

# ============================================================
# Shared tools
# ============================================================
FROM debian:13-slim AS tools

ARG MCRCON_VERSION=0.7.2
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*

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
# Shared CPU runtime
# ============================================================
FROM debian:13-slim AS runtime-common

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get -y upgrade \
 && apt-get install -y --no-install-recommends \
      bash curl ca-certificates tini procps tzdata \
      pciutils ocl-icd-libopencl1 jq unzip tar \
      rsync libpopt0 awscli \
 && rm -rf /var/lib/apt/lists/*

COPY --from=zulu-repo /azul.pgp.asc /usr/share/keyrings/azul.pgp.asc
COPY --from=zulu-repo /zulu.list /etc/apt/sources.list.d/zulu.list
COPY --from=tools /usr/local/bin/mcrcon /usr/local/bin/mcrcon
COPY entrypoint.sh /entrypoint.sh
COPY scripts/lib /scripts/lib

ARG UID=10001
ARG GID=10001

RUN chmod 0755 /entrypoint.sh /usr/local/bin/mcrcon \
 && groupadd -g "${GID}" mc \
 && useradd -m -u "${UID}" -g "${GID}" -s /bin/bash mc \
 && mkdir -p /data /mods /plugins /config /datapacks /resourcepacks \
 && chown -R mc:mc /data /mods /plugins /config /datapacks /resourcepacks

USER mc:mc
ENV HOME=/data
WORKDIR /data
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["run"]

# ============================================================
# Parameterized CPU runtime
# JAVA_VERSION: 8 / 11 / 17 / 21 / 25
# ============================================================
FROM runtime-common AS runtime

ARG JAVA_VERSION=25
USER root

RUN set -eux; \
    case "${JAVA_VERSION}" in \
      8|11|17|21|25) ;; \
      *) echo "Unsupported JAVA_VERSION: ${JAVA_VERSION}" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends "zulu${JAVA_VERSION}-jre"; \
    rm -rf /var/lib/apt/lists/*; \
    java_home="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"; \
    mkdir -p /opt/java; \
    ln -s "${java_home}" /opt/java/openjdk; \
    /opt/java/openjdk/bin/java -version

ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"
USER mc:mc

# ============================================================
# Backward-compatible named CPU targets
# ============================================================
FROM runtime-common AS runtime-jre8
USER root
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends zulu8-jre; \
    rm -rf /var/lib/apt/lists/*; \
    java_home="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"; \
    mkdir -p /opt/java; \
    ln -s "${java_home}" /opt/java/openjdk; \
    /opt/java/openjdk/bin/java -version
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"
USER mc:mc

FROM runtime-common AS runtime-jre11
USER root
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends zulu11-jre; \
    rm -rf /var/lib/apt/lists/*; \
    java_home="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"; \
    mkdir -p /opt/java; \
    ln -s "${java_home}" /opt/java/openjdk; \
    /opt/java/openjdk/bin/java -version
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"
USER mc:mc

FROM runtime-common AS runtime-jre17
USER root
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends zulu17-jre; \
    rm -rf /var/lib/apt/lists/*; \
    java_home="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"; \
    mkdir -p /opt/java; \
    ln -s "${java_home}" /opt/java/openjdk; \
    /opt/java/openjdk/bin/java -version
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"
USER mc:mc

FROM runtime-common AS runtime-jre21
USER root
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends zulu21-jre; \
    rm -rf /var/lib/apt/lists/*; \
    java_home="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"; \
    mkdir -p /opt/java; \
    ln -s "${java_home}" /opt/java/openjdk; \
    /opt/java/openjdk/bin/java -version
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"
USER mc:mc

FROM runtime-common AS runtime-jre25
USER root
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends zulu25-jre; \
    rm -rf /var/lib/apt/lists/*; \
    java_home="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"; \
    mkdir -p /opt/java; \
    ln -s "${java_home}" /opt/java/openjdk; \
    /opt/java/openjdk/bin/java -version
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"
USER mc:mc

# ============================================================
# GPU runtime (Java 25 only)
# ============================================================
FROM nvidia/cuda:13.3.1-runtime-ubuntu24.04 AS runtime-gpu

ENV DEBIAN_FRONTEND=noninteractive
ARG JAVA_VERSION=25
ARG AWS_CLI_VERSION=2.23.6

COPY --from=zulu-repo /azul.pgp.asc /usr/share/keyrings/azul.pgp.asc
COPY --from=zulu-repo /zulu.list /etc/apt/sources.list.d/zulu.list

RUN set -eux; \
    test "${JAVA_VERSION}" = "25"; \
    apt-get update; \
    apt-get -y upgrade; \
    apt-get install -y --no-install-recommends \
      bash ca-certificates curl tini procps tzdata \
      pciutils ocl-icd-libopencl1 clinfo jq unzip rsync libpopt0 \
      "zulu${JAVA_VERSION}-jre"; \
    rm -rf /var/lib/apt/lists/*; \
    java_home="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"; \
    mkdir -p /opt/java; \
    ln -s "${java_home}" /opt/java/openjdk; \
    /opt/java/openjdk/bin/java -version

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

ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"

COPY --from=tools /usr/local/bin/mcrcon /usr/local/bin/mcrcon
COPY entrypoint.sh /entrypoint.sh
COPY scripts/lib /scripts/lib

ENV RUNTIME_FLAVOR=gpu

ARG UID=10001
ARG GID=10001

RUN chmod 0755 /entrypoint.sh /usr/local/bin/mcrcon \
 && groupadd -g "${GID}" mc \
 && useradd -m -u "${UID}" -g "${GID}" -s /bin/bash mc \
 && mkdir -p /data /mods /plugins /config /datapacks /resourcepacks \
 && chown -R mc:mc /data /mods /plugins /config /datapacks /resourcepacks

USER mc:mc
ENV HOME=/data
WORKDIR /data
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["run"]

# Backward-compatible GPU target.
FROM runtime-gpu AS runtime-jre25-gpu
