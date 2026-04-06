#!/usr/bin/env bash
# Sentinel PreToolUse hook for Claude Code.
# Approval is handled ONLY by the Sentinel mascot — Claude Code's own permission
# dialog is bypassed because settings.json allow list covers everything.
# The hook decides independently what needs human approval by checking what
# ISN'T in the settings.json allow list (via fnmatch).

INPUT=$(cat)
INPUT_TMP=$(mktemp /tmp/sentinel-input-XXXXXX)
printf '%s' "$INPUT" > "$INPUT_TMP"

# If VS Code is the frontmost app, pass through immediately — Claude Code's own
# chat panel will handle approval. No mascot needed, no double prompt.
FRONTMOST=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || echo "unknown")
if [[ "$FRONTMOST" == *"Code"* ]] || [[ "$FRONTMOST" == *"Electron"* ]] || [[ "$FRONTMOST" == *"cursor"* ]]; then
    rm -f "$INPUT_TMP"
    echo '{"decision":"allow"}'
    exit 0
fi

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

# Build candidate string (matches Claude Code permission format)
if tool_name in ('Write', 'Edit', 'NotebookEdit'):
    path = inp.get('file_path', inp.get('notebook_path', ''))
    short = path.split('/')[-1] if path else ''
    display = f'{tool_name}: {short}' if short else tool_name
    if path.startswith('/'):
        candidate = f'{tool_name}(/{path})'
    elif path:
        candidate = f'{tool_name}({path})'
    else:
        candidate = tool_name
elif tool_name == 'Bash':
    cmd = inp.get('command', inp.get('cmd', ''))
    display = ('Bash: ' + cmd[:55]) if cmd else 'Bash'
    candidate = f'Bash({cmd})'
else:
    display = tool_name
    candidate = tool_name

# Sanitise for pipe delimiter
display_safe = display.replace('|', '/').replace('\n', ' ').replace('\r', '')
session_safe = session_id.replace('|', '').replace(' ', '_')[:32]

# Safe Bash prefixes — these never need mascot approval.
# Everything else (touch, cp, mv, rm, chmod, kill, pkill, swiftc, make, etc.)
# will show the mascot. settings.json has Bash(**) so Claude Code never prompts,
# making the mascot the sole gatekeeper.
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
    # Write, Edit, NotebookEdit — always allow (Claude Code's own permission UI
    # is disabled via the allow list, so we trust these)
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
APPROVAL_TMP="/tmp/sentinel-approval-${SESSION_ID}"

if [ "$DECISION" != "approval" ]; then
    curl -s --max-time 2 -X POST http://localhost:49152/update \
      -H 'Content-Type: application/json' \
      -d "{\"id\":\"$SESSION_ID\",\"name\":\"Claude\",\"status\":\"working\",\"task\":\"$DISPLAY_TASK\"}" \
      > /dev/null 2>&1 &
    echo '{"decision":"allow"}'
    exit 0
fi

# Needs approval — post to mascot and long-poll for response.
# The mascot UI is the SOLE approval surface. No terminal prompt here
# because Claude Code runs inside VSCode where /dev/tty is unreliable.
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
