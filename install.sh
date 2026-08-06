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
LOG_DIR="$HOME/Library/Logs/ShotPin"
LOCK_FILE="$HOME/Applications/.ShotPin.install.lock"
INSTALL_DIR=""
INSTALL_COMPLETE=false
ROLLBACK_READY=false
OLD_APP_EXISTS=false
OLD_PLIST_EXISTS=false
OLD_AGENT_LOADED=false
OLD_AGENT_RUNNING=false
THUMBNAIL_CHANGED=false
OLD_THUMBNAIL_EXISTS=false
OLD_THUMBNAIL_VALUE=""
LOCK_OWNED=false
LOCK_CHILD_PID=""

wait_for_agent_removal() {
  local attempt
  for ((attempt = 0; attempt < 100; attempt++)); do
    if ! launchctl print "$SERVICE" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

unload_agent() {
  if ! launchctl print "$SERVICE" >/dev/null 2>&1; then
    return 0
  fi

  # bootout returns after requesting termination, not after launchd has removed
  # the job. A bootstrap during that interval fails with EINPROGRESS (reported
  # by launchctl as error 5), so wait for the old job to disappear completely.
  launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
  wait_for_agent_removal
}

release_install_lock() {
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

rollback() {
  local status=$?
  if [[ "$INSTALL_COMPLETE" == true ]]; then
    [[ -n "$INSTALL_DIR" && -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR" || true
    return
  fi
  if [[ "$ROLLBACK_READY" == false ]]; then
    [[ -n "$INSTALL_DIR" && -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR" || true
    echo "ShotPin installation failed before any installed state was changed." >&2
    exit "$status"
  fi

  set +e
  local rollback_failed=false
  local agent_unloaded=true
  local plist_restored=true
  local app_restored=true
  if ! unload_agent; then
    rollback_failed=true
    agent_unloaded=false
  fi

  if [[ "$OLD_PLIST_EXISTS" == true ]]; then
    if ! install -m 644 "$INSTALL_DIR/Previous.plist" "$PLIST"; then
      rollback_failed=true
      plist_restored=false
    fi
  else
    if ! rm -f "$PLIST"; then
      rollback_failed=true
      plist_restored=false
    fi
  fi

  if [[ "$OLD_APP_EXISTS" == true ]]; then
    if ! rm -rf "$APP"; then
      rollback_failed=true
      app_restored=false
    elif ! mv "$INSTALL_DIR/Previous.app" "$APP"; then
      rollback_failed=true
      app_restored=false
    fi
  else
    if ! rm -rf "$APP"; then
      rollback_failed=true
      app_restored=false
    fi
  fi

  if [[ "$THUMBNAIL_CHANGED" == true ]]; then
    if [[ "$OLD_THUMBNAIL_EXISTS" == true ]]; then
      if ! defaults write com.apple.screencapture show-thumbnail -bool "$OLD_THUMBNAIL_VALUE"; then
        rollback_failed=true
      fi
    else
      if ! defaults delete com.apple.screencapture show-thumbnail >/dev/null 2>&1; then
        rollback_failed=true
      fi
    fi
  fi

  if [[ "$OLD_AGENT_LOADED" == true && "$OLD_PLIST_EXISTS" == true \
      && "$agent_unloaded" == true && "$plist_restored" == true \
      && "$app_restored" == true ]]; then
    local restore_plist="$PLIST"
    local restore_plist_ready=true
    if [[ "$OLD_AGENT_RUNNING" == false ]]; then
      restore_plist="$INSTALL_DIR/Previous.stopped.plist"
      if ! cp "$INSTALL_DIR/Previous.plist" "$restore_plist"; then
        rollback_failed=true
        restore_plist_ready=false
      elif ! plutil -replace RunAtLoad -bool false "$restore_plist" 2>/dev/null \
          && ! plutil -insert RunAtLoad -bool false "$restore_plist"; then
        rollback_failed=true
        restore_plist_ready=false
      fi
    fi
    if [[ "$restore_plist_ready" == true ]] \
        && ! launchctl bootstrap "$DOMAIN" "$restore_plist" >/dev/null 2>&1; then
      rollback_failed=true
    fi
  elif [[ "$OLD_AGENT_LOADED" == true ]]; then
    rollback_failed=true
  fi

  if [[ "$rollback_failed" == true ]]; then
    echo "ShotPin installation failed and rollback was incomplete." >&2
    echo "Recovery files were kept at: $INSTALL_DIR" >&2
  else
    [[ -n "$INSTALL_DIR" && -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR"
    echo "ShotPin installation failed; the previous installation was restored." >&2
  fi
  exit "$status"
}

mkdir -p "$HOME/Applications" "$LAUNCH_AGENTS_DIR" "$LOG_DIR"
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
  trap release_install_lock EXIT
  trap 'forward_signal HUP 129' HUP
  trap 'forward_signal INT 130' INT
  trap 'forward_signal TERM 143' TERM
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
trap rollback EXIT
if [[ ( -e "$APP" || -L "$APP" ) && ( ! -d "$APP" || -L "$APP" ) ]]; then
  echo "Refusing to replace non-directory path: $APP" >&2
  exit 1
fi
if [[ -L "$PLIST" || ( -e "$PLIST" && ! -f "$PLIST" ) ]]; then
  echo "Refusing to replace non-regular LaunchAgent plist: $PLIST" >&2
  exit 1
fi
INSTALL_DIR="$(mktemp -d "$HOME/Applications/.ShotPin.install.XXXXXX")"

if [[ -d "$APP" ]]; then
  ditto "$APP" "$INSTALL_DIR/Previous.app"
  OLD_APP_EXISTS=true
fi
if [[ -f "$PLIST" ]]; then
  cp "$PLIST" "$INSTALL_DIR/Previous.plist"
  OLD_PLIST_EXISTS=true
fi
AGENT_STATE="$(launchctl print "$SERVICE" 2>/dev/null || true)"
if [[ -n "$AGENT_STATE" ]]; then
  OLD_AGENT_LOADED=true
  if [[ "$AGENT_STATE" == *"state = running"* ]]; then
    OLD_AGENT_RUNNING=true
  fi
fi
if OLD_THUMBNAIL_VALUE="$(defaults read com.apple.screencapture show-thumbnail 2>/dev/null)"; then
  OLD_THUMBNAIL_EXISTS=true
  case "$OLD_THUMBNAIL_VALUE" in
    1|true|TRUE|yes|YES) OLD_THUMBNAIL_VALUE=true ;;
    0|false|FALSE|no|NO) OLD_THUMBNAIL_VALUE=false ;;
    *)
      echo "Expected com.apple.screencapture show-thumbnail to be a boolean." >&2
      exit 1
      ;;
  esac
fi

ROLLBACK_READY=true
SHOTPIN_INSTALL_LOCK_HELD=1 "$ROOT/build.sh"

NEW_PLIST="$INSTALL_DIR/com.shotpin.agent.plist"
plutil -create xml1 "$NEW_PLIST"
plutil -insert Label -string "$LABEL" "$NEW_PLIST"
plutil -insert ProgramArguments -array "$NEW_PLIST"
plutil -insert ProgramArguments.0 -string "$APP/Contents/MacOS/ShotPin" "$NEW_PLIST"
plutil -insert RunAtLoad -bool true "$NEW_PLIST"
plutil -insert StandardErrorPath -string "$LOG_DIR/shotpin.err.log" "$NEW_PLIST"
plutil -insert StandardOutPath -string "$LOG_DIR/shotpin.out.log" "$NEW_PLIST"
plutil -lint "$NEW_PLIST"

# The native floating thumbnail would sit in the same corner and also delays the
# file write until it expires, so ShotPin replaces it entirely.
THUMBNAIL_CHANGED=true
defaults write com.apple.screencapture show-thumbnail -bool false

if ! unload_agent; then
  echo "Timed out waiting for the existing ShotPin agent to stop." >&2
  exit 1
fi
install -m 644 "$NEW_PLIST" "$PLIST"
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$SERVICE"

INSTALL_COMPLETE=true
printf 'ShotPin installed and running. Take a screenshot to test it.\n' || true
