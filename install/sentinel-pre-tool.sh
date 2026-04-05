#!/usr/bin/env bash
# Sentinel PreToolUse hook.
# - Always returns allow (never blocks Claude Code).
# - Shows "needs_approval" on mascot when Claude Code will prompt the user,
#   so the mascot reflects what VS Code is showing.
# - Shows "working" for pre-approved tools.

input=$(cat)
tool_name=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name','tool'))" 2>/dev/null || echo "tool")
tool_context=$(echo "$input" | python3 -c "
import sys, json
d = json.load(sys.stdin)
inp = d.get('tool_input', {})
name = d.get('tool_name', '')
if name in ('Write', 'Edit'):
    print(inp.get('file_path', '').split('/')[-1])
elif name == 'Bash':
    print(inp.get('command', '')[:50])
elif name == 'NotebookEdit':
    print(inp.get('notebook_path', '').split('/')[-1])
else:
    print('')
" 2>/dev/null || echo "")

DISPLAY_TASK="${tool_name}${tool_context:+: $tool_context}"

# Read Claude Code's allow list to check if this tool needs user approval.
# If it's NOT pre-approved, Claude Code will show a VS Code dialog — mirror that on mascot.
NEEDS_APPROVAL=$(python3 - "$tool_name" "$tool_context" << 'PYEOF'
import sys, json, re

tool_name = sys.argv[1]
tool_context = sys.argv[2] if len(sys.argv) > 2 else ''

try:
    with open('/Users/afnan_dfx/.claude/settings.json') as f:
        settings = json.load(f)
    allow = settings.get('permissions', {}).get('allow', [])
except:
    print('0')
    sys.exit()

# Build the full command string Claude Code would match against
if tool_name == 'Bash':
    candidate = f'Bash({tool_context})'
else:
    candidate = tool_name

def matches(pattern, candidate):
    # Claude Code uses glob-style: Bash(git *) matches Bash(git push origin main)
    p = re.escape(pattern).replace(r'\*', '.*')
    return bool(re.fullmatch(p, candidate))

for rule in allow:
    if matches(rule, candidate):
        print('0')
        sys.exit()

print('1')
PYEOF
)

if [ "$NEEDS_APPROVAL" = "1" ]; then
  STATUS="needs_approval"
else
  STATUS="working"
fi

curl -s -X POST http://localhost:49152/update \
  -H 'Content-Type: application/json' \
  -d "{\"id\":\"claude\",\"name\":\"Claude\",\"status\":\"$STATUS\",\"task\":\"$DISPLAY_TASK\"}" > /dev/null &

echo '{"decision":"allow"}'
