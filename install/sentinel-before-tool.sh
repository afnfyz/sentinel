#!/usr/bin/env bash

input=$(cat)
tool_name=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name','tool'))" 2>/dev/null || echo "tool")
tool_input=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); inp=d.get('tool_input',{}); print(str(inp)[:120])" 2>/dev/null || echo "")

# ── Config file: ~/.sentinel/config.json ──────────────────────────────────────
# Example:
#   {
#     "destructiveTools": ["write_file","replace","edit_file","delete","move","create","overwrite"],
#     "gateShellCommands": false
#   }
# Default: only gate file-mutation tools; do NOT gate bash/shell commands.
CONFIG_FILE="$HOME/.sentinel/config.json"

if [ -f "$CONFIG_FILE" ]; then
  DESTRUCTIVE_PATTERN=$(python3 -c "
import sys, json, re
try:
    cfg = json.load(open('$CONFIG_FILE'))
    tools = cfg.get('destructiveTools', [])
    gate_shell = cfg.get('gateShellCommands', False)
    if gate_shell:
        tools = tools + ['bash','run_shell_command','execute','computer_use']
    print('|'.join(re.escape(t) for t in tools) if tools else 'NOMATCH_SENTINEL')
except Exception:
    print('write_file|replace|edit_file|delete|move|create|overwrite')
" 2>/dev/null || echo "write_file|replace|edit_file|delete|move|create|overwrite")
else
  # Default: file-mutation tools only — bash and shell commands are NOT gated
  DESTRUCTIVE_PATTERN="write_file|replace|edit_file|delete|move|create|overwrite"
fi

# Log tool call to server.log for debugging — use SENTINEL_DIR if set, else ~/.sentinel/
if [ -n "$SENTINEL_DIR" ] && [ -d "$SENTINEL_DIR" ]; then
  SENTINEL_LOG="$SENTINEL_DIR/server.log"
else
  mkdir -p "$HOME/.sentinel"
  SENTINEL_LOG="$HOME/.sentinel/server.log"
fi
echo "[$(date '+%H:%M:%S')] [gemini] tool=$tool_name input=$tool_input" >> "$SENTINEL_LOG" 2>/dev/null || true

if ! echo "$tool_name" | grep -qiE "^($DESTRUCTIVE_PATTERN)$"; then
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
    echo "[$(date '+%H:%M:%S')] [gemini] DENIED $tool_name (terminal)" >> "$SENTINEL_LOG" 2>/dev/null || true
    echo '{"decision":"deny","reason":"Denied from terminal."}'
  else
    curl -s -X POST http://localhost:49152/action \
      -H 'Content-Type: application/json' \
      -d '{"id":"main","action":"approve"}' > /dev/null
    echo "[$(date '+%H:%M:%S')] [gemini] APPROVED $tool_name (terminal)" >> "$SENTINEL_LOG" 2>/dev/null || true
    echo '{"decision":"allow"}'
  fi
else
  wait $CURL_PID
  RESULT=$(cat /tmp/sentinel-approval-main 2>/dev/null)
  rm -f /tmp/sentinel-approval-main
  MASCOT_ACTION=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('action','timeout'))" 2>/dev/null || echo "timeout")

  if [ "$MASCOT_ACTION" = "approve" ]; then
    echo "[$(date '+%H:%M:%S')] [gemini] APPROVED $tool_name (mascot)" >> "$SENTINEL_LOG" 2>/dev/null || true
    echo '{"decision":"allow"}'
  elif [ "$MASCOT_ACTION" = "deny" ]; then
    echo "[$(date '+%H:%M:%S')] [gemini] DENIED $tool_name (mascot)" >> "$SENTINEL_LOG" 2>/dev/null || true
    echo '{"decision":"deny","reason":"Denied from Sentinel."}'
  else
    echo "[$(date '+%H:%M:%S')] [gemini] TIMEOUT $tool_name (auto-allow)" >> "$SENTINEL_LOG" 2>/dev/null || true
    echo '{"decision":"allow"}'
  fi
fi
