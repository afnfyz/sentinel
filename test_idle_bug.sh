#!/usr/bin/env bash
# Test: Claude session must NOT reset to idle when work resumes after a Stop event.
#
# BUG: The Stop hook (async) posts status="success" which starts an 8s auto-clear
# timer. If the success POST arrives AFTER the next PreToolUse "working" POST
# (race condition because Stop is async), the session goes success → timer → idle
# even though Claude is actively working.
#
# Test A: Normal order (working → success → working) — timer should be stale
# Test B: Race condition (working → success arrives AFTER next working) — the
#         "success" overwrites "working" and timer resets to idle
#
# PASS: Both tests end with status == "working"
# FAIL: status == "idle" or "success"

set -e

SERVER="http://localhost:49152"

post() {
    curl -s --max-time 2 -X POST "$SERVER/update" \
        -H 'Content-Type: application/json' \
        -d "$1" 2>/dev/null
}

get_status() {
    local sid="$1"
    curl -s --max-time 2 "$SERVER/state" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['sessions'].get('$sid',{}).get('status','GONE'))" 2>/dev/null
}

echo "=== Test A: Normal ordering (should already pass) ==="
echo "Sequence: thinking → working → success → working"
echo ""

echo -n "A1. thinking... "
post '{"id":"claude","name":"Claude","status":"thinking","task":"Thinking..."}'  > /dev/null
echo "OK"

echo -n "A2. working (tool 1)... "
post '{"id":"claude","name":"Claude","status":"working","task":"Read: server.js"}' > /dev/null
echo "OK"

echo -n "A3. success (Stop hook)... "
post '{"id":"claude","name":"Claude","status":"success","task":"Done"}' > /dev/null
echo "OK"

sleep 0.5

echo -n "A4. working (tool 2)... "
post '{"id":"claude","name":"Claude","status":"working","task":"Edit: server.js"}' > /dev/null
echo "OK"

echo -n "A5. Wait 10s... "
sleep 10
echo "done"

STATUS=$(get_status claude)
echo -n "A6. Status should be 'working'... "
if [ "$STATUS" = "working" ]; then
    echo "PASS"
else
    echo "FAIL (status=$STATUS)"
fi

echo ""
echo "=== Test B: Race condition (Stop async arrives LATE) ==="
echo "Sequence: thinking → working → working (tool 2) → success (late Stop)"
echo ""

echo -n "B1. thinking... "
post '{"id":"claude","name":"Claude","status":"thinking","task":"Thinking..."}'  > /dev/null
echo "OK"

echo -n "B2. working (tool 1)... "
post '{"id":"claude","name":"Claude","status":"working","task":"Read: server.js"}' > /dev/null
echo "OK"

echo -n "B3. working (tool 2 — PreToolUse fires before async Stop lands)... "
post '{"id":"claude","name":"Claude","status":"working","task":"Edit: server.js"}' > /dev/null
echo "OK"

sleep 0.2

echo -n "B4. success (LATE async Stop arrives after next working)... "
post '{"id":"claude","name":"Claude","status":"success","task":"Done"}' > /dev/null
echo "OK"

echo -n "B5. Wait 10s for auto-clear timer... "
sleep 10
echo "done"

STATUS=$(get_status claude)
echo -n "B6. Status should be 'working'... "
if [ "$STATUS" = "working" ]; then
    echo "PASS"
else
    echo "FAIL (status=$STATUS — BUG: late async Stop overwrote active state)"
    exit 1
fi

echo ""
echo "=== ALL TESTS PASSED ==="
