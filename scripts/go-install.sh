#!/bin/bash
set -euo pipefail

# Install Go into the container.
# Usage: go-install.sh <version>
# Example: go-install.sh go1.26.0

VERSION="${1:?Usage: go-install.sh <version> (e.g. go1.26.0)}"
ARCH=$(uname -m)
case "$ARCH" in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; esac

echo "Installing ${VERSION} for linux/${ARCH}..."

curl -fsSL "https://go.dev/dl/${VERSION}.linux-${ARCH}.tar.gz" \
  | tar -C /usr/local -xz

# Symlinks to match host path references (macOS and Linux)
mkdir -p /opt/go
ln -sf /usr/local/go /opt/go/go.darwin-arm64
ln -sf /usr/local/go /opt/go/go.darwin-amd64
ln -sf /usr/local/go /opt/go/go.linux-amd64
ln -sf /usr/local/go /opt/go/go.linux-arm64

echo "Go installed at /usr/local/go (symlinked from /opt/go/go.*)"
/usr/local/go/bin/go version
