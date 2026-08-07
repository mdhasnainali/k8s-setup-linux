#!/bin/bash
set -e

# Installs the k8s-setup CLI by symlinking bin/k8s-setup onto PATH.
# Usage: ./install.sh [install-dir]   (default: /usr/local/bin)

INSTALL_DIR="${1:-/usr/local/bin}"
ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

if [[ ! -w "$INSTALL_DIR" ]]; then
    SUDO="sudo"
else
    SUDO=""
fi

$SUDO ln -sf "$ROOT_DIR/bin/k8s-setup" "$INSTALL_DIR/k8s-setup"
chmod +x "$ROOT_DIR/bin/k8s-setup" "$ROOT_DIR"/scripts/*.sh

echo "Installed: $INSTALL_DIR/k8s-setup -> $ROOT_DIR/bin/k8s-setup"
echo "Run 'k8s-setup help' to get started."
