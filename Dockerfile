FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

ARG TARGETARCH
ARG TOFU_VERSION=1.13.9
ARG KUBECTL_VERSION=v1.37.2
ARG LARAKUBE_CLI_VERSION=canary
ARG LARAKUBE_CLI_SHA256_AMD64=
ARG LARAKUBE_CLI_SHA256_ARM64=

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl jq openssh-client openssl unzip; \
    work="$(mktemp -d)"; cd "$work"; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    curl -fsSLO "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${arch}.tar.gz"; \
    curl -fsSLO "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_SHA256SUMS"; \
    grep " tofu_${TOFU_VERSION}_linux_${arch}.tar.gz$" "tofu_${TOFU_VERSION}_SHA256SUMS" | sha256sum -c -; \
    tar -xzf "tofu_${TOFU_VERSION}_linux_${arch}.tar.gz" tofu; \
    install -m 0755 tofu /usr/local/bin/tofu; \
    curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl"; \
    echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl.sha256")  kubectl" | sha256sum -c -; \
    install -m 0755 kubectl /usr/local/bin/kubectl; \
    case "$arch" in \
        amd64) asset=larakube-linux-x64; sum="${LARAKUBE_CLI_SHA256_AMD64}" ;; \
        arm64) asset=larakube-linux-arm; sum="${LARAKUBE_CLI_SHA256_ARM64}" ;; \
        *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o larakube "https://github.com/luchavez-technologies/larakube-cli/releases/download/${LARAKUBE_CLI_VERSION}/${asset}"; \
    if [ -n "$sum" ]; then echo "$sum  larakube" | sha256sum -c -; fi; \
    install -m 0755 larakube /usr/local/bin/larakube; \
    cd /; rm -rf "$work"; \
    apt-get purge -y unzip; apt-get autoremove -y; rm -rf /var/lib/apt/lists/*; \
    useradd --uid 10001 --create-home --home-dir /home/runner --shell /usr/sbin/nologin runner

COPY ssh_config /etc/ssh/ssh_config.d/larakube.conf
COPY entrypoint.sh /usr/local/bin/larakube-runner
RUN chmod 0644 /etc/ssh/ssh_config.d/larakube.conf && chmod 0755 /usr/local/bin/larakube-runner

USER 10001:10001
WORKDIR /home/runner
ENV HOME=/home/runner HISTFILE=/dev/null TF_IN_AUTOMATION=1 TF_INPUT=0
ENTRYPOINT ["/usr/local/bin/larakube-runner"]
