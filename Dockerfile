FROM alpine:3.23

# ── System packages ──────────────────────────────────────────────
RUN apk add --no-cache \
    git \
    make \
    bash \
    ca-certificates \
    curl \
    jq \
    ripgrep \
    fd \
    gnupg \
    openssh-client \
    poppler-utils \
    procps \
    sudo \
    g++ \
    build-base \
    file \
    fish \
    unzip \
    github-cli \
    shadow \
    nodejs \
    npm \
    docker-cli \
    docker-cli-compose \
    gosu \
    python3 \
    py3-pip \
    socat

# ── Go + gopls ────────────────────────────────────────────────────
ARG GO_VERSION=go1.26.0
COPY scripts/go-install.sh /tmp/go-install.sh
RUN chmod +x /tmp/go-install.sh && /tmp/go-install.sh "${GO_VERSION}" \
    && rm /tmp/go-install.sh \
    && export PATH="/usr/local/go/bin:${PATH}" \
    && go install golang.org/x/tools/gopls@latest \
    && cp /root/go/bin/gopls /usr/local/bin/gopls \
    && rm -rf /root/go /root/.cache/go-build
ENV PATH="/usr/local/go/bin:${PATH}"

# ── Terraform + Terragrunt ────────────────────────────────────────
RUN ARCH=$(uname -m) \
    && case "$ARCH" in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; esac \
    && curl -fsSL "https://releases.hashicorp.com/terraform/1.11.2/terraform_1.11.2_linux_${ARCH}.zip" -o /tmp/terraform.zip \
    && unzip -o /tmp/terraform.zip -d /usr/local/bin/ \
    && rm /tmp/terraform.zip \
    && curl -fsSL "https://github.com/gruntwork-io/terragrunt/releases/download/v0.77.10/terragrunt_linux_${ARCH}" -o /usr/local/bin/terragrunt \
    && chmod +x /usr/local/bin/terragrunt

# ── Host-mirrored user ──────────────────────────────────────────
ARG HOST_UID=1000
ARG HOST_USER=user
ARG HOST_HOME=/home/${HOST_USER}
RUN mkdir -p "$(dirname ${HOST_HOME})" \
    && adduser -D -u ${HOST_UID} \
    -h ${HOST_HOME} \
    -s /usr/bin/fish \
    ${HOST_USER} \
    && echo "${HOST_USER} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# ── Claude Code (native installer) ─────────────────────────────
USER ${HOST_USER}
RUN curl -fsSL https://claude.ai/install.sh | bash
USER root
ENV PATH="${HOST_HOME}/.local/bin:${PATH}"
ENV DISABLE_AUTOUPDATER=1

# ── LSP servers (for Claude Code LSP tool) ────────────────────────
RUN npm install -g typescript typescript-language-server pyright

# ── Environment marker ────────────────────────────────────────────
RUN touch /this-is-claude-docker-env

# ── Security wrappers (replace real binaries) ─────────────────────
RUN mkdir -p /usr/libexec/git-real && mv /usr/bin/git /usr/libexec/git-real/git
COPY scripts/git-wrapper.sh    /usr/bin/git
COPY scripts/docker-wrapper.sh /usr/local/bin/docker
COPY scripts/entrypoint.sh     /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/bin/git /usr/local/bin/docker /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
