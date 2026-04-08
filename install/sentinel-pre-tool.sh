#!/usr/bin/env bash
# Sentinel PreToolUse hook for Claude Code.
#
# Dual approval surface:
#   - VS Code focused → auto-allow (user can see what Claude is doing)
#   - VS Code NOT focused → mascot is the sole approval surface
#
# Safe commands always auto-allow regardless of focus.
# settings.json has Bash(**) so Claude Code never shows its own dialog.

INPUT=$(cat)

# Fast-path: extract tool_name without Python for non-approval tools.
# Only Bash, Write, Edit, NotebookEdit can require mascot approval — everything
# else is auto-allowed. This saves ~150ms of Python startup per safe tool call.
TOOL_NAME=$(printf '%s' "$INPUT" | grep -o '"tool_name":"[^"]*"' | head -1 | sed 's/"tool_name":"//;s/"//')

case "$TOOL_NAME" in
    Bash|Write|Edit|NotebookEdit) ;; # fall through to Python classification below
    *)
        # Auto-allow non-approval tool with fire-and-forget status update
        DISPLAY="${TOOL_NAME:-tool}"
        curl -s --max-time 2 -X POST http://localhost:49152/update \
            -H 'Content-Type: application/json' \
            -d "{\"id\":\"claude\",\"name\":\"Claude\",\"status\":\"working\",\"task\":\"$DISPLAY\"}" \
            > /dev/null 2>&1 &
        echo '{"decision":"allow"}'
        exit 0
        ;;
esac

INPUT_TMP=$(mktemp /tmp/sentinel-input-XXXXXX)
printf '%s' "$INPUT" > "$INPUT_TMP"

PYTHON_OUT=$(python3 - "$INPUT_TMP" << 'PYEOF'
import sys, json, fnmatch, os

input_file = sys.argv[1]
try:
    with open(input_file) as f:
        d = json.load(f)
except:
    print("allow|tool|claude")
    sys.exit()

tool_name  = d.get('tool_name', 'tool')
inp        = d.get('tool_input', {})
session_id = 'claude'  # fixed — all Claude Code hooks use 'claude' as the shared ID

# Only these tools ever need approval — everything else is auto-allowed
APPROVAL_TOOLS = {'Bash', 'Write', 'Edit', 'NotebookEdit'}

if tool_name not in APPROVAL_TOOLS:
    session_safe = session_id.replace('|', '').replace(' ', '_')[:32]
    print(f"allow|{tool_name}|{session_safe}")
    sys.exit()

# Build display string
if tool_name in ('Write', 'Edit', 'NotebookEdit'):
    path = inp.get('file_path', inp.get('notebook_path', ''))
    short = path.split('/')[-1] if path else ''
    display = f'{tool_name}: {short}' if short else tool_name
elif tool_name == 'Bash':
    cmd = inp.get('command', inp.get('cmd', ''))
    display = ('Bash: ' + cmd[:55]) if cmd else 'Bash'
else:
    display = tool_name

# Sanitise for pipe delimiter
display_safe = display.replace('|', '/').replace('\n', ' ').replace('\r', '')
session_safe = session_id.replace('|', '').replace(' ', '_')[:32]

# Safe Bash prefixes — these never need mascot approval.
# NOTE: Destructive ops (rm, kill, chmod, etc.) are intentionally excluded —
# those require mascot approval when VS Code is not focused.
SAFE_BASH = [
    'git ', 'gh ', 'gemini ',
    'node ', 'npx ', 'npm ',
    'python3 ', 'pip3 ', 'pip ',
    'curl ', 'ls ', 'find ', 'grep ',
    'cat ', 'head ', 'tail ', 'wc ',
    'diff ', 'stat ', 'file ', 'type ',
    'which ', 'man ', 'du ', 'df ',
    'lsof ', 'ps ', 'pgrep ',
    'echo ', 'printf ', 'sort ', 'uniq ',
    'cut ', 'tr ', 'xargs ', 'open ',
    'sleep ', 'wait ', 'export ', 'env ',
    'set ', 'true', 'false',
    'bash ', 'timeout ',
    'touch ', 'mkdir ', 'rmdir ', 'ln ',
    'swiftc ', 'make ', 'osascript ',
]
SAFE_BASH_EXACT = {'date', 'whoami', 'id', 'hostname', 'sw_vers', 'true', 'false'}

needs_approval = True
if tool_name == 'Bash':
    cmd_stripped = cmd.strip()
    if cmd_stripped in SAFE_BASH_EXACT:
        needs_approval = False
    else:
        for prefix in SAFE_BASH:
            if cmd_stripped.startswith(prefix):
                needs_approval = False
                break
else:
    # Write, Edit, NotebookEdit — always allow
    needs_approval = False

decision = "approval" if needs_approval else "allow"
print(f"{decision}|{display_safe}|{session_safe}")
PYEOF
)

rm -f "$INPUT_TMP"

# Fallback if python failed entirely
if [ -z "$PYTHON_OUT" ]; then
    echo '{"decision":"allow"}'
    exit 0
fi

DECISION=$(echo "$PYTHON_OUT" | cut -d'|' -f1)
DISPLAY_TASK=$(echo "$PYTHON_OUT" | cut -d'|' -f2)
SESSION_ID=$(echo "$PYTHON_OUT" | cut -d'|' -f3)

SESSION_ID="${SESSION_ID:-claude}"

# --- Safe command: allow and update mascot status ---
if [ "$DECISION" != "approval" ]; then
    curl -s --max-time 2 -X POST http://localhost:49152/update \
      -H 'Content-Type: application/json' \
      -d "{\"id\":\"$SESSION_ID\",\"name\":\"Claude\",\"status\":\"working\",\"task\":\"$DISPLAY_TASK\"}" \
      > /dev/null 2>&1 &
    echo '{"decision":"allow"}'
    exit 0
fi

# --- Dangerous command: check if VS Code is focused ---
# If VS Code (or Cursor/Terminal) is the frontmost app, the user can see
# what Claude is doing — auto-allow and let them monitor directly.
# If another app is focused, the mascot is the sole approval surface.
FRONT_APP=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || echo "")

case "$FRONT_APP" in
    "Code"|"Cursor"|"Terminal"|"iTerm2")
        # User is looking at the IDE/terminal — allow through, update mascot status
        curl -s --max-time 2 -X POST http://localhost:49152/update \
          -H 'Content-Type: application/json' \
          -d "{\"id\":\"$SESSION_ID\",\"name\":\"Claude\",\"status\":\"working\",\"task\":\"$DISPLAY_TASK\"}" \
          > /dev/null 2>&1 &
        echo '{"decision":"allow"}'
        exit 0
        ;;
esac

# --- VS Code not focused: mascot approval ---
curl -s --max-time 2 -X POST http://localhost:49152/update \
  -H 'Content-Type: application/json' \
  -d "{\"id\":\"$SESSION_ID\",\"name\":\"Claude\",\"status\":\"needs_approval\",\"task\":\"$DISPLAY_TASK\"}" \
  > /dev/null 2>&1

# Long-poll — blocks until mascot UI responds or 30s timeout
RESULT=$(curl -s --max-time 31 "http://localhost:49152/wait-approval?id=$SESSION_ID" 2>/dev/null || echo "")

MASCOT_ACTION=$(python3 -c "
import sys, json
try:
    print(json.loads(sys.argv[1]).get('action','deny'))
except:
    print('deny')
" "$RESULT" 2>/dev/null || echo "deny")

if [ "$MASCOT_ACTION" = "approve" ]; then
    echo '{"decision":"allow"}'
else
    echo '{"decision":"block","reason":"Denied from Sentinel."}'
fi
