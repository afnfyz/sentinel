#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"

# Kill any existing instances
pkill -f "node.*server.js" 2>/dev/null || true
pkill -f "GeminiSentinel" 2>/dev/null || true
sleep 0.5

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
