#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v node > /dev/null 2>&1; then
  echo "Error: node not found in PATH" >&2
  exit 1
fi

# Kill any existing instances and wait for them to actually die
pkill -f "node.*server.js" 2>/dev/null || true
pkill -f "GeminiSentinel" 2>/dev/null || true
for i in $(seq 1 10); do
  pgrep -f "node.*server.js" > /dev/null 2>&1 || break
  sleep 0.2
done

# Start the server
node "$DIR/server.js" >> "$DIR/server.log" 2>&1 &
SERVER_PID=$!

# Wait until the server is actually accepting connections
for i in $(seq 1 20); do
  if curl -s http://localhost:49152/state > /dev/null 2>&1; then
    break
  fi
  sleep 0.3
done

# Launch the floating window
"$DIR/GeminiSentinel" &

echo "Gemini Sentinel running (server PID: $SERVER_PID)"
