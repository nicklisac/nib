#!/usr/bin/env bash
set -euo pipefail

# Nib CLI Install Script
# Usage: curl -fsSL https://raw.githubusercontent.com/nicklisac/nib/main/install.sh | bash

REPO="nicklisac/nib"
INSTALL_DIR="${NIB_INSTALL_DIR:-$HOME/.local/bin}"

# Detect OS and Arch
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$OS" in
  linux*)
    PLATFORM="linux"
    ;;
  darwin*)
    PLATFORM="macos"
    ;;
  *)
    echo "Unsupported operating system: $OS" >&2
    exit 1
    ;;
esac

case "$ARCH" in
  x86_64|amd64)
    ARCH_NAME="x64"
    ;;
  arm64|aarch64)
    ARCH_NAME="arm64"
    ;;
  *)
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

TARGET="${PLATFORM}-${ARCH_NAME}"

# Fetch latest release tag
LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$LATEST_TAG" ]; then
  echo "Error: Could not determine latest release for ${REPO}." >&2
  exit 1
fi

ARCHIVE_NAME="nib-${LATEST_TAG}-${TARGET}.tar.gz"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${LATEST_TAG}/${ARCHIVE_NAME}"

mkdir -p "$INSTALL_DIR"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading Nib ${LATEST_TAG} for ${TARGET}..."
curl -fsSL "$DOWNLOAD_URL" -o "${TMP_DIR}/${ARCHIVE_NAME}"

echo "Extracting..."
tar -xzf "${TMP_DIR}/${ARCHIVE_NAME}" -C "$TMP_DIR"

# Install binary atomically
mv -f "${TMP_DIR}/nib" "${INSTALL_DIR}/nib"
chmod +x "${INSTALL_DIR}/nib"

echo "✔ Successfully installed Nib to ${INSTALL_DIR}/nib"

# Verify if INSTALL_DIR is in PATH
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    echo ""
    echo "Notice: ${INSTALL_DIR} is not in your PATH."
    echo "Add it by running:"
    echo "  export PATH=\"\$PATH:${INSTALL_DIR}\""
    echo "or add that line to your ~/.bashrc or ~/.zshrc."
    ;;
esac
