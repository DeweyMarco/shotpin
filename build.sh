#!/bin/bash
# Compiles ShotPin and assembles it into ~/Applications/ShotPin.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/ShotPin.app"
BIN="$APP/Contents/MacOS/ShotPin"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
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

swiftc -O -framework AppKit -framework CoreServices \
  -o "$BIN" "$ROOT/Sources/main.swift"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "built $APP"
