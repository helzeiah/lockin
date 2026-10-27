#!/bin/bash
# Builds Focus.app.
#   ./app/build.sh             build for this Mac, install to ~/Applications, (re)start it
#   ./app/build.sh --release   universal (Apple silicon + Intel) build in dist/, zipped for a GitHub release
# Optional: BUNDLE_ID=com.you.focus, SIGN_ID="name of a code-signing certificate in your keychain".
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

RELEASE=0
[[ "${1:-}" == "--release" ]] && RELEASE=1
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-1.0.0}"
if [[ $RELEASE == 1 ]]; then
  BUNDLE_ID="${BUNDLE_ID:-io.github.helzeiah.lockin}"
  APP="$ROOT/dist/Focus.app"; ARCHS=(arm64 x86_64)
else
  BUNDLE_ID="${BUNDLE_ID:-com.$(whoami | tr -cd 'a-zA-Z0-9-').focus}"
  APP="$HOME/Applications/Focus.app"; ARCHS=("$(uname -m)")
fi
MIN_OS=14.0
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Compile each architecture, then merge them into one binary.
compile() {  # output, swiftc args...
  local out="$1"; shift
  local parts=()
  for a in "${ARCHS[@]}"; do
    swiftc -O -swift-version 5 -target "$a-apple-macos$MIN_OS" "$@" -o "$out.$a"
    parts+=("$out.$a")
  done
  lipo -create "${parts[@]}" -output "$out"
  rm -f "${parts[@]}"
}
echo "compiling Focus (${ARCHS[*]})..."
compile "$APP/Contents/MacOS/Focus" -parse-as-library app/Sources/*.swift
compile "$APP/Contents/Resources/calevents" bin/calevents.swift
cp coach.py ai.py config.example.json "$APP/Contents/Resources/"
[[ -f app/AppIcon.icns ]] && cp app/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>Focus</string>
<key>CFBundleDisplayName</key><string>Focus</string>
<key>CFBundleExecutable</key><string>Focus</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
<key>LSUIElement</key><true/>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Focus</string><key>CFBundleURLSchemes</key><array><string>focus</string></array></dict></array>
<key>NSAppleEventsUsageDescription</key><string>Focus checks which tab is open in your browser and terminal so it can tell when you drift.</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>Focus reads today's events so it can plan around them.</string>
<key>NSCalendarsUsageDescription</key><string>Focus reads today's events so it can plan around them.</string>
</dict></plist>
PL

# Sign. A stable identity keeps macOS's Calendar/Automation permissions across rebuilds; ad-hoc signatures change
# every build, so macOS asks again each time. The README shows how to make a free local signing certificate.
SIGN_ID="${SIGN_ID:-Focus Local Signing}"
if [[ $RELEASE == 0 ]] && security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then SIGN="$SIGN_ID"; else SIGN="-"; fi
codesign --force -s "$SIGN" -i "$BUNDLE_ID.calevents" "$APP/Contents/Resources/calevents"
codesign --force -s "$SIGN" "$APP"

if [[ $RELEASE == 1 ]]; then
  (cd dist && rm -f Focus.zip && ditto -c -k --keepParent Focus.app Focus.zip)
  echo "built dist/Focus.app and dist/Focus.zip (v$VERSION)"
  exit 0
fi

pkill -x Focus 2>/dev/null || true
sleep 0.5
open -g "$APP"
echo "built and started $APP (v$VERSION)"
