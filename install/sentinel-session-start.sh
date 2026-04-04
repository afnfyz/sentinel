#!/usr/bin/env bash

echo '{}'

SENTINEL_DIR="/Users/afnan_dfx/projects/gemini-sentinel"

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
