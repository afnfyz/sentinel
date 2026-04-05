#!/usr/bin/env bash

input=$(cat)
tool_name=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name','tool'))" 2>/dev/null || echo "tool")
tool_input=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); inp=d.get('tool_input',{}); print(str(inp)[:120])" 2>/dev/null || echo "")

# ── Config file: ~/.sentinel/config.json ──────────────────────────────────────
# Controls which tools require approval. Bash/shell are excluded by default.
CONFIG_FILE="$HOME/.sentinel/config.json"

if [ -f "$CONFIG_FILE" ]; then
  DESTRUCTIVE=$(python3 -c "
import sys, json
try:
    cfg = json.load(open('$CONFIG_FILE'))
    tools = cfg.get('destructiveTools', [])
    gate_shell = cfg.get('gateShellCommands', False)
    if gate_shell:
        tools = tools + ['Bash']
    print(' '.join(tools) if tools else 'Write Edit NotebookEdit')
except Exception:
    print('Write Edit NotebookEdit')
" 2>/dev/null || echo "Write Edit NotebookEdit")
else
  # Default: only gate file-mutation tools (not Bash — Claude Code gates that itself)
  DESTRUCTIVE="Write Edit NotebookEdit"
fi

# Log tool call for debugging
LOG_FILE="$HOME/.sentinel/tool.log"
mkdir -p "$HOME/.sentinel"
echo "[$(date '+%H:%M:%S')] [claude] tool=$tool_name input=$tool_input" >> "$LOG_FILE" 2>/dev/null || true

# Check if tool is in the destructive list
IS_DESTRUCTIVE=0
for dt in $DESTRUCTIVE; do
  if [ "$tool_name" = "$dt" ]; then
    IS_DESTRUCTIVE=1
    break
  fi
done

if [ "$IS_DESTRUCTIVE" -eq 0 ]; then
  curl -s -X POST http://localhost:49152/update \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"claude\",\"name\":\"Claude\",\"status\":\"working\",\"task\":\"Running: $tool_name\"}" > /dev/null
  echo '{"decision":"allow"}'
  exit 0
fi

# Set mascot to needs_approval
curl -s -X POST http://localhost:49152/update \
  -H 'Content-Type: application/json' \
  -d "{\"id\":\"claude\",\"name\":\"Claude\",\"status\":\"needs_approval\",\"task\":\"Run: $tool_name?\"}" > /dev/null

# Start the long-poll — server will respond when user clicks in mascot
curl -s --max-time 31 "http://localhost:49152/wait-approval?id=claude" > /tmp/sentinel-approval-claude &
CURL_PID=$!

# Try terminal prompt (will fail silently in VS Code — that's fine)
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
      -d '{"id":"claude","action":"deny"}' > /dev/null
    echo "[$(date '+%H:%M:%S')] [claude] DENIED $tool_name (terminal)" >> "$LOG_FILE" 2>/dev/null || true
    echo '{"decision":"deny","reason":"Denied from terminal."}'
  else
    curl -s -X POST http://localhost:49152/action \
      -H 'Content-Type: application/json' \
      -d '{"id":"claude","action":"approve"}' > /dev/null
    echo "[$(date '+%H:%M:%S')] [claude] APPROVED $tool_name (terminal)" >> "$LOG_FILE" 2>/dev/null || true
    echo '{"decision":"allow"}'
  fi
else
  wait $CURL_PID
  RESULT=$(cat /tmp/sentinel-approval-claude 2>/dev/null)
  rm -f /tmp/sentinel-approval-claude
  MASCOT_ACTION=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('action','timeout'))" 2>/dev/null || echo "timeout")

  if [ "$MASCOT_ACTION" = "approve" ]; then
    echo "[$(date '+%H:%M:%S')] [claude] APPROVED $tool_name (mascot)" >> "$LOG_FILE" 2>/dev/null || true
    echo '{"decision":"allow"}'
  elif [ "$MASCOT_ACTION" = "deny" ]; then
    echo "[$(date '+%H:%M:%S')] [claude] DENIED $tool_name (mascot)" >> "$LOG_FILE" 2>/dev/null || true
    echo '{"decision":"deny","reason":"Denied from Sentinel."}'
  else
    echo "[$(date '+%H:%M:%S')] [claude] TIMEOUT $tool_name (auto-allow)" >> "$LOG_FILE" 2>/dev/null || true
    echo '{"decision":"allow"}'
  fi
fi
