#!/bin/bash
# Installs the latest Focus release into ~/Applications and opens it.
#   curl -fsSL https://raw.githubusercontent.com/helzeiah/lockin/main/install.sh | bash
set -euo pipefail
REPO="helzeiah/lockin"
DEST="$HOME/Applications"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[[ "$(uname)" == "Darwin" ]] || { echo "Focus is a macOS app."; exit 1; }
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 14 )) || { echo "Focus needs macOS 14 (Sonoma) or later."; exit 1; }

echo "Downloading Focus..."
curl -fsSL "https://github.com/$REPO/releases/latest/download/Focus.zip" -o "$TMP/Focus.zip"
ditto -x -k "$TMP/Focus.zip" "$TMP"

pkill -x Focus 2>/dev/null || true
mkdir -p "$DEST"
rm -rf "$DEST/Focus.app"
mv "$TMP/Focus.app" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/Focus.app" 2>/dev/null || true

open "$DEST/Focus.app"
echo "Installed to $DEST/Focus.app. Look for the target icon in the menu bar."
