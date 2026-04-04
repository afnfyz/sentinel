#!/usr/bin/env bash

# Must be synchronous — Gemini exits immediately after this and kills background jobs
RESPONSE=$(curl -s --max-time 3 -X POST http://localhost:49152/session-end)
SHUTDOWN=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('shutdown', False))" 2>/dev/null)

if [ "$SHUTDOWN" = "True" ]; then
  pkill -f "GeminiSentinel" 2>/dev/null || true
fi

echo '{}'
