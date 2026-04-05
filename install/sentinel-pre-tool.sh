#!/usr/bin/env bash

input=$(cat)
tool_name=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name','tool'))" 2>/dev/null || echo "tool")

# Extract a short description of what the tool is doing for display in the mascot
tool_context=$(echo "$input" | python3 -c "
import sys, json
d = json.load(sys.stdin)
inp = d.get('tool_input', {})
name = d.get('tool_name', '')
if name == 'Write':
    print(inp.get('file_path', '?').split('/')[-1])
elif name == 'Edit':
    print(inp.get('file_path', '?').split('/')[-1])
elif name == 'NotebookEdit':
    print(inp.get('notebook_path', '?').split('/')[-1])
else:
    print('')
" 2>/dev/null || echo "")

# Only Write, Edit, NotebookEdit need mascot approval
case "$tool_name" in
  Write|Edit|NotebookEdit)
    DESTRUCTIVE=1
    ;;
  *)
    DESTRUCTIVE=0
    ;;
esac

if [ "$DESTRUCTIVE" -eq 0 ]; then
  curl -s -X POST http://localhost:49152/update \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"claude\",\"name\":\"Claude\",\"status\":\"working\",\"task\":\"Running: $tool_name\"}" > /dev/null
  echo '{"decision":"allow"}'
  exit 0
fi

# Build display task with context
if [ -n "$tool_context" ]; then
  DISPLAY_TASK="$tool_name: $tool_context"
else
  DISPLAY_TASK="$tool_name"
fi

# Set mascot to needs_approval with context
curl -s -X POST http://localhost:49152/update \
  -H 'Content-Type: application/json' \
  -d "{\"id\":\"claude\",\"name\":\"Claude\",\"status\":\"needs_approval\",\"task\":\"$DISPLAY_TASK\"}" > /dev/null

# Start the long-poll
curl -s --max-time 31 "http://localhost:49152/wait-approval?id=claude" > /tmp/sentinel-approval-claude &
CURL_PID=$!

# Try terminal prompt (silent in VS Code)
TERMINAL_INPUT=""
if [ -t 0 ] || [ -e /dev/tty ]; then
  echo "" >&2
  echo "  Sentinel: [$DISPLAY_TASK] — Approve? [Y/n] (or click mascot): " >&2
  read -t 28 -r TERMINAL_INPUT </dev/tty 2>/dev/null || true
fi

if [ -n "$TERMINAL_INPUT" ]; then
  kill $CURL_PID 2>/dev/null
  wait $CURL_PID 2>/dev/null
  if [[ "$TERMINAL_INPUT" =~ ^[Nn] ]]; then
    curl -s -X POST http://localhost:49152/action \
      -H 'Content-Type: application/json' \
      -d '{"id":"claude","action":"deny"}' > /dev/null
    echo '{"decision":"deny","reason":"Denied from terminal."}'
  else
    curl -s -X POST http://localhost:49152/action \
      -H 'Content-Type: application/json' \
      -d '{"id":"claude","action":"approve"}' > /dev/null
    echo '{"decision":"allow"}'
  fi
else
  wait $CURL_PID
  RESULT=$(cat /tmp/sentinel-approval-claude 2>/dev/null)
  rm -f /tmp/sentinel-approval-claude
  MASCOT_ACTION=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('action','timeout'))" 2>/dev/null || echo "timeout")

  if [ "$MASCOT_ACTION" = "approve" ]; then
    echo '{"decision":"allow"}'
  elif [ "$MASCOT_ACTION" = "deny" ]; then
    echo '{"decision":"deny","reason":"Denied from Sentinel."}'
  else
    echo '{"decision":"allow"}'
  fi
fi
