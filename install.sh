#!/bin/bash
# Builds ShotPin, turns off the native screenshot thumbnail, and registers a
# LaunchAgent so ShotPin runs at login.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/ShotPin.app"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$LAUNCH_AGENTS_DIR/com.shotpin.agent.plist"
LABEL="com.shotpin.agent"
DOMAIN="gui/$UID"
SERVICE="$DOMAIN/$LABEL"
INSTALL_DIR=""
INSTALL_COMPLETE=false
ROLLBACK_READY=false
OLD_APP_EXISTS=false
OLD_PLIST_EXISTS=false
OLD_AGENT_LOADED=false
THUMBNAIL_CHANGED=false
OLD_THUMBNAIL_EXISTS=false
OLD_THUMBNAIL_VALUE=""

rollback() {
  local status=$?
  if [[ "$INSTALL_COMPLETE" == true ]]; then
    [[ -n "$INSTALL_DIR" && -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR"
    return
  fi
  if [[ "$ROLLBACK_READY" == false ]]; then
    [[ -n "$INSTALL_DIR" && -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR"
    echo "ShotPin installation failed before any installed state was changed." >&2
    exit "$status"
  fi

  set +e
  launchctl bootout "$SERVICE" >/dev/null 2>&1

  if [[ "$OLD_PLIST_EXISTS" == true ]]; then
    cp "$INSTALL_DIR/Previous.plist" "$PLIST"
  else
    rm -f "$PLIST"
  fi

  if [[ "$OLD_APP_EXISTS" == true ]]; then
    rm -rf "$APP"
    ditto "$INSTALL_DIR/Previous.app" "$APP"
  else
    rm -rf "$APP"
  fi

  if [[ "$THUMBNAIL_CHANGED" == true ]]; then
    if [[ "$OLD_THUMBNAIL_EXISTS" == true ]]; then
      defaults write com.apple.screencapture show-thumbnail -bool "$OLD_THUMBNAIL_VALUE"
    else
      defaults delete com.apple.screencapture show-thumbnail >/dev/null 2>&1
    fi
  fi

  if [[ "$OLD_AGENT_LOADED" == true && "$OLD_PLIST_EXISTS" == true ]]; then
    launchctl bootstrap "$DOMAIN" "$PLIST" >/dev/null 2>&1
  fi

  [[ -n "$INSTALL_DIR" && -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR"
  echo "ShotPin installation failed; the previous installation was restored." >&2
  exit "$status"
}
trap rollback EXIT

mkdir -p "$HOME/Applications" "$LAUNCH_AGENTS_DIR"
INSTALL_DIR="$(mktemp -d "$HOME/Applications/.ShotPin.install.XXXXXX")"

if [[ -d "$APP" ]]; then
  ditto "$APP" "$INSTALL_DIR/Previous.app"
  OLD_APP_EXISTS=true
fi
if [[ -f "$PLIST" ]]; then
  cp "$PLIST" "$INSTALL_DIR/Previous.plist"
  OLD_PLIST_EXISTS=true
fi
if launchctl print "$SERVICE" >/dev/null 2>&1; then
  OLD_AGENT_LOADED=true
fi
if OLD_THUMBNAIL_VALUE="$(defaults read com.apple.screencapture show-thumbnail 2>/dev/null)"; then
  OLD_THUMBNAIL_EXISTS=true
fi

"$ROOT/build.sh"
ROLLBACK_READY=true

NEW_PLIST="$INSTALL_DIR/com.shotpin.agent.plist"
cat > "$NEW_PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/MacOS/ShotPin</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>/tmp/shotpin.err.log</string>
  <key>StandardOutPath</key><string>/tmp/shotpin.out.log</string>
</dict>
</plist>
PLISTEOF
plutil -lint "$NEW_PLIST"

# The native floating thumbnail would sit in the same corner and also delays the
# file write until it expires, so ShotPin replaces it entirely.
THUMBNAIL_CHANGED=true
defaults write com.apple.screencapture show-thumbnail -bool false

launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
install -m 644 "$NEW_PLIST" "$PLIST"
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$SERVICE"

INSTALL_COMPLETE=true
echo "ShotPin installed and running. Take a screenshot to test it."
