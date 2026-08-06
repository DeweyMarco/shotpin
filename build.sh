#!/bin/bash
# Compiles ShotPin and atomically installs it into ~/Applications/ShotPin.app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/ShotPin.app"
ARCH="${SHOTPIN_ARCH:-$(uname -m)}"
BUILD_DIR=""

cleanup() {
  if [[ -n "$BUILD_DIR" && -e "$BUILD_DIR/Previous.app" && ! -e "$APP" ]]; then
    mv "$BUILD_DIR/Previous.app" "$APP"
  fi
  if [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]]; then
    rm -rf "$BUILD_DIR"
  fi
}
trap cleanup EXIT

mkdir -p "$APP_DIR"
BUILD_DIR="$(mktemp -d "$APP_DIR/.ShotPin.build.XXXXXX")"
STAGED_APP="$BUILD_DIR/ShotPin.app"
BIN="$STAGED_APP/Contents/MacOS/ShotPin"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

cat > "$STAGED_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ShotPin</string>
  <key>CFBundleDisplayName</key><string>ShotPin</string>
  <key>CFBundleExecutable</key><string>ShotPin</string>
  <key>CFBundleIdentifier</key><string>com.shotpin.ShotPin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

plutil -lint "$STAGED_APP/Contents/Info.plist"
swiftc -O -target "${ARCH}-apple-macosx13.0" \
  -framework AppKit -framework CoreServices \
  -o "$BIN" "$ROOT/Sources/main.swift"

codesign --force --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

# Both paths live in APP_DIR, so each rename is atomic. Keep the previous bundle
# until the replacement is in place, and restore it if that final rename fails.
BACKUP_APP="$BUILD_DIR/Previous.app"
if [[ -e "$APP" ]]; then
  mv "$APP" "$BACKUP_APP"
fi
if ! mv "$STAGED_APP" "$APP"; then
  if [[ -e "$BACKUP_APP" ]]; then
    mv "$BACKUP_APP" "$APP"
  fi
  exit 1
fi

echo "built $APP"
