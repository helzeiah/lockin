#!/bin/bash
# Installs the latest lockin release into ~/Applications and opens it.
#   curl -fsSL https://raw.githubusercontent.com/helzeiah/lockin/main/install.sh | bash
set -euo pipefail

main() {
  local repo="helzeiah/lockin" dest="$HOME/Applications"
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  [[ "$(uname)" == "Darwin" ]] || { echo "lockin is a macOS app."; exit 1; }
  local major; major="$(sw_vers -productVersion | cut -d. -f1)"
  (( major >= 14 )) || { echo "lockin needs macOS 14 (Sonoma) or later."; exit 1; }

  echo "Downloading lockin..."
  curl -fsSL "https://github.com/$repo/releases/latest/download/lockin.zip" -o "$tmp/lockin.zip"
  ditto -x -k "$tmp/lockin.zip" "$tmp"

  # Quit only our own copies: this app, and the old Focus.app from before the rename.
  pkill -f "^$dest/lockin.app/Contents/MacOS/lockin" 2>/dev/null || true
  pkill -f "^$dest/Focus.app/Contents/MacOS/Focus" 2>/dev/null || true
  sleep 0.5

  mkdir -p "$dest"
  rm -rf "$dest/lockin.app"
  mv "$tmp/lockin.app" "$dest/"
  xattr -dr com.apple.quarantine "$dest/lockin.app" 2>/dev/null || true
  # The app used to be called Focus. Settings and history carry over on first launch.
  [[ -d "$dest/Focus.app" ]] && rm -rf "$dest/Focus.app"

  open "$dest/lockin.app"
  echo "Installed to $dest/lockin.app. Look for the target icon in the menu bar."
}

main "$@"
