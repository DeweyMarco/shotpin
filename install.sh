#!/bin/bash
# Builds ShotPin, turns off the native screenshot thumbnail, and registers a
# LaunchAgent so ShotPin runs at login.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/ShotPin.app"
PLIST="$HOME/Library/LaunchAgents/com.shotpin.agent.plist"
LABEL="com.shotpin.agent"

"$ROOT/build.sh"

# The native floating thumbnail would sit in the same corner and also delays the
# file write until it expires, so ShotPin replaces it entirely.
defaults write com.apple.screencapture show-thumbnail -bool false

cat > "$PLIST" <<PLISTEOF
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
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/shotpin.err.log</string>
  <key>StandardOutPath</key><string>/tmp/shotpin.out.log</string>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl kickstart -k "gui/$UID/$LABEL"

echo "ShotPin installed and running. Take a screenshot to test it."
