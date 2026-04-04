#!/usr/bin/env bash

input=$(cat)
tool_name=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name','tool'))" 2>/dev/null || echo "tool")
tool_input=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); inp=d.get('tool_input',{}); print(str(inp)[:120])" 2>/dev/null || echo "")

# Only intercept destructive/write tools — let read-only ones through silently
DESTRUCTIVE_TOOLS="write_file|replace|edit_file|run_shell_command|bash|delete|move|create|overwrite|execute|computer_use"
if ! echo "$tool_name" | grep -qiE "$DESTRUCTIVE_TOOLS"; then
  curl -s -X POST http://localhost:49152/update \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"main\",\"name\":\"Gemini\",\"status\":\"working\",\"task\":\"Running: $tool_name\"}" > /dev/null
  echo '{"decision":"allow"}'
  exit 0
fi

# Update mascot to needs_approval
curl -s -X POST http://localhost:49152/update \
  -H 'Content-Type: application/json' \
  -d "{\"id\":\"main\",\"name\":\"Gemini\",\"status\":\"needs_approval\",\"task\":\"Run: $tool_name?\"}" > /dev/null

# Start waiting for mascot approval in background
curl -s "http://localhost:49152/wait-approval?id=main" > /tmp/sentinel-approval-main &
CURL_PID=$!

# Also prompt in terminal
echo "" >&2
echo "  [$tool_name] $tool_input" >&2
echo "  Approve? [Y/n]: " >&2

# Race: read terminal input vs wait for mascot
read -t 30 -r TERMINAL_INPUT <>/dev/tty

if [ -n "$TERMINAL_INPUT" ]; then
  # Terminal responded first — kill the mascot wait
  kill $CURL_PID 2>/dev/null
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
  # Timeout or mascot responded — read mascot result
  wait $CURL_PID
  MASCOT_ACTION=$(cat /tmp/sentinel-approval-main | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('action','timeout'))" 2>/dev/null || echo "timeout")
  rm -f /tmp/sentinel-approval-main

  if [ "$MASCOT_ACTION" = "approve" ]; then
    echo '{"decision":"allow"}'
  elif [ "$MASCOT_ACTION" = "deny" ]; then
    echo '{"decision":"deny","reason":"Denied from Sentinel."}'
  else
    # Timed out — allow by default
    curl -s -X POST http://localhost:49152/update \
      -H 'Content-Type: application/json' \
      -d "{\"id\":\"main\",\"name\":\"Gemini\",\"status\":\"working\",\"task\":\"Running: $tool_name\"}" > /dev/null
    echo '{"decision":"allow"}'
  fi
fi
