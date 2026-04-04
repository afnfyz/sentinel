#!/usr/bin/env bash

input=$(cat)
tool_name=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name','tool'))" 2>/dev/null || echo "tool")
tool_input=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); inp=d.get('tool_input',{}); print(str(inp)[:120])" 2>/dev/null || echo "")

# Let read-only tools through immediately
DESTRUCTIVE="write_file|replace|edit_file|run_shell_command|bash|delete|move|create|overwrite|execute|computer_use"
if ! echo "$tool_name" | grep -qiE "$DESTRUCTIVE"; then
  curl -s -X POST http://localhost:49152/update \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"main\",\"name\":\"Gemini\",\"status\":\"working\",\"task\":\"Running: $tool_name\"}" > /dev/null
  echo '{"decision":"allow"}'
  exit 0
fi

# Set mascot to needs_approval
curl -s -X POST http://localhost:49152/update \
  -H 'Content-Type: application/json' \
  -d "{\"id\":\"main\",\"name\":\"Gemini\",\"status\":\"needs_approval\",\"task\":\"Run: $tool_name?\"}" > /dev/null

# Start the long-poll
curl -s --max-time 31 "http://localhost:49152/wait-approval?id=main" > /tmp/sentinel-approval-main &
CURL_PID=$!

# Try terminal prompt (fails silently if no tty)
TERMINAL_INPUT=""
if [ -t 0 ] || [ -e /dev/tty ]; then
  echo "" >&2
  echo "  Sentinel: [$tool_name] — Approve? [Y/n] (or click mascot): " >&2
  read -t 28 -r TERMINAL_INPUT </dev/tty 2>/dev/null || true
fi

if [ -n "$TERMINAL_INPUT" ]; then
  kill $CURL_PID 2>/dev/null
  wait $CURL_PID 2>/dev/null
  if [[ "$TERMINAL_INPUT" =~ ^[Nn] ]]; then
    curl -s -X POST http://localhost:49152/action \
      -H 'Content-Type: application/json' \
      -d '{"id":"main","action":"deny"}' > /dev/null
    echo '{"decision":"deny","reason":"Denied from terminal."}'
  else
    curl -s -X POST http://localhost:49152/action \
      -H 'Content-Type: application/json' \
      -d '{"id":"main","action":"approve"}' > /dev/null
    echo '{"decision":"allow"}'
  fi
else
  wait $CURL_PID
  RESULT=$(cat /tmp/sentinel-approval-main 2>/dev/null)
  rm -f /tmp/sentinel-approval-main
  MASCOT_ACTION=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('action','timeout'))" 2>/dev/null || echo "timeout")

  if [ "$MASCOT_ACTION" = "approve" ]; then
    echo '{"decision":"allow"}'
  elif [ "$MASCOT_ACTION" = "deny" ]; then
    echo '{"decision":"deny","reason":"Denied from Sentinel."}'
  else
    echo '{"decision":"allow"}'
  fi
fi
