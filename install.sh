#!/bin/bash
set -euo pipefail

REPO="Starter-Pack-Studios/XcodeClean"
APP_NAME="XcodeClean.app"
INSTALL_DIR="/Applications"
TMP_DIR=$(mktemp -d)

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "Fetching latest release..."
DOWNLOAD_URL=$(curl -sL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep '"browser_download_url".*\.zip' \
  | head -1 \
  | cut -d '"' -f 4)

if [ -z "$DOWNLOAD_URL" ]; then
  echo "Error: Could not find a release. Check https://github.com/$REPO/releases"
  exit 1
fi

echo "Downloading $DOWNLOAD_URL..."
curl -sL "$DOWNLOAD_URL" -o "$TMP_DIR/XcodeClean.zip"

echo "Installing to $INSTALL_DIR..."
unzip -qo "$TMP_DIR/XcodeClean.zip" -d "$TMP_DIR"

if [ -d "$INSTALL_DIR/$APP_NAME" ]; then
  rm -rf "$INSTALL_DIR/$APP_NAME"
fi

mv "$TMP_DIR/$APP_NAME" "$INSTALL_DIR/"
xattr -d com.apple.quarantine "$INSTALL_DIR/$APP_NAME" 2>/dev/null || true

echo "XcodeClean installed successfully! Opening now..."
open "$INSTALL_DIR/$APP_NAME"
