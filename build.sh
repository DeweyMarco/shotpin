#!/bin/bash
# Compiles ShotPin and atomically installs it into ~/Applications/ShotPin.app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/ShotPin.app"
ARCH="${SHOTPIN_ARCH:-$(uname -m)}"
BUILD_DIR=""
LOCK_FILE="$APP_DIR/.ShotPin.install.lock"
LOCK_OWNED=false
LOCK_CHILD_PID=""

cleanup() {
  if [[ -n "$BUILD_DIR" && -e "$BUILD_DIR/Previous.app" && ! -e "$APP" ]]; then
    mv "$BUILD_DIR/Previous.app" "$APP"
  fi
  if [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]]; then
    rm -rf "$BUILD_DIR"
  fi
  if [[ "$LOCK_OWNED" == true ]]; then
    rm -f "$LOCK_FILE" || true
  fi
}

forward_signal() {
  local signal_name=$1
  local exit_code=$2
  trap - HUP INT TERM
  if [[ -n "$LOCK_CHILD_PID" ]]; then
    kill -s "$signal_name" -- "-$LOCK_CHILD_PID" >/dev/null 2>&1 \
      || kill -s "$signal_name" "$LOCK_CHILD_PID" >/dev/null 2>&1 \
      || true
    wait "$LOCK_CHILD_PID" >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}

mkdir -p "$APP_DIR"
trap cleanup EXIT
trap 'forward_signal HUP 129' HUP
trap 'forward_signal INT 130' INT
trap 'forward_signal TERM 143' TERM
if [[ "${SHOTPIN_INSTALL_LOCK_HELD:-}" != "1" ]]; then
  if [[ -L "$LOCK_FILE" ]]; then
    echo "Refusing to use symlinked lock file: $LOCK_FILE" >&2
    exit 1
  fi
  if ! shlock -f "$LOCK_FILE" -p $$; then
    echo "Another ShotPin build or install is already running." >&2
    exit 75
  fi
  LOCK_OWNED=true
  set -m
  env SHOTPIN_INSTALL_LOCK_HELD=1 "$0" "$@" &
  LOCK_CHILD_PID=$!
  set +m
  set +e
  wait "$LOCK_CHILD_PID"
  CHILD_STATUS=$?
  set -e
  LOCK_CHILD_PID=""
  exit "$CHILD_STATUS"
fi
if [[ ( -e "$APP" || -L "$APP" ) && ( ! -d "$APP" || -L "$APP" ) ]]; then
  echo "Refusing to replace non-directory path: $APP" >&2
  exit 1
fi
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
if [[ -e "$APP" || -L "$APP" ]]; then
  mv "$APP" "$BACKUP_APP"
fi
if ! mv "$STAGED_APP" "$APP"; then
  if [[ -e "$BACKUP_APP" ]]; then
    mv "$BACKUP_APP" "$APP"
  fi
  exit 1
fi

printf 'built %s\n' "$APP" || true
