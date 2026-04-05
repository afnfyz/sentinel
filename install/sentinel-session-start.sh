#!/usr/bin/env bash

echo '{}'

# Resolve project dir from this script's installed location.
# Installed hooks live at: ~/.gemini/hooks/sentinel-session-start.sh
# The project root is stored in SENTINEL_DIR env var, or we fall back to
# looking alongside the script for a server.js file.
if [ -z "$SENTINEL_DIR" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  # Walk up from script location looking for server.js
  # (handles both running from project dir and from ~/.gemini/hooks/)
  if [ -f "$SCRIPT_DIR/server.js" ]; then
    SENTINEL_DIR="$SCRIPT_DIR"
  elif [ -f "$SCRIPT_DIR/../../server.js" ]; then
    SENTINEL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
  else
    echo "[sentinel-session-start] ERROR: Cannot find server.js. Set SENTINEL_DIR env var to your sentinel project path." >&2
    exit 1
  fi
fi

(
  # Start server if not running
  if ! curl -s http://localhost:49152/state > /dev/null 2>&1; then
    node "$SENTINEL_DIR/server.js" >> "$SENTINEL_DIR/server.log" 2>&1 &
    for i in $(seq 1 20); do
      curl -s http://localhost:49152/state > /dev/null 2>&1 && break
      sleep 0.3
    done
  fi

  # Launch mascot if not running
  if ! pgrep -f "GeminiSentinel" > /dev/null 2>&1; then
    open "$SENTINEL_DIR/GeminiSentinel.app"
  fi

  curl -s -X POST http://localhost:49152/session-start > /dev/null
) &
