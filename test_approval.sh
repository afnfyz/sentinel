#!/usr/bin/env bash
# Test: mascot approval flow end-to-end
#
# Reproduces the bug: when needs_approval is posted, the mascot should
# show approval buttons and clicking ALLOW should resolve the /wait-approval
# long-poll. This test automates the "click" by calling /action directly.
#
# PASS: /wait-approval returns {"action":"approve"} within a few seconds
# FAIL: /wait-approval times out (30s) or returns timeout/deny

set -e

SERVER="http://localhost:49152"
SESSION="test-approval-$$"

echo "=== Sentinel Approval Flow Test ==="
echo ""

# 1. Check server is up
echo -n "1. Server reachable... "
STATE=$(curl -s --max-time 2 "$SERVER/state" 2>/dev/null || echo "")
if [ -z "$STATE" ]; then
    echo "FAIL (server not running)"
    exit 1
fi
echo "OK"

# 2. Post needs_approval status
echo -n "2. POST needs_approval... "
RESULT=$(curl -s --max-time 2 -X POST "$SERVER/update" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"$SESSION\",\"name\":\"Test\",\"status\":\"needs_approval\",\"task\":\"Test approval\"}" 2>/dev/null)
if echo "$RESULT" | python3 -c "import sys,json; assert json.load(sys.stdin).get('success')" 2>/dev/null; then
    echo "OK"
else
    echo "FAIL ($RESULT)"
    exit 1
fi

# 3. Verify session is in needs_approval state
echo -n "3. Session state is needs_approval... "
STATE=$(curl -s --max-time 2 "$SERVER/state" 2>/dev/null)
STATUS=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['sessions']['$SESSION']['status'])" 2>/dev/null)
if [ "$STATUS" = "needs_approval" ]; then
    echo "OK"
else
    echo "FAIL (status=$STATUS)"
    exit 1
fi

# 4. Start /wait-approval in background
echo -n "4. Long-poll /wait-approval... "
TMPFILE=$(mktemp)
curl -s --max-time 35 "$SERVER/wait-approval?id=$SESSION" > "$TMPFILE" 2>/dev/null &
WAIT_PID=$!
sleep 1

# 5. Simulate clicking ALLOW by posting /action
echo -n "approve via /action... "
ACTION_RESULT=$(curl -s --max-time 2 -X POST "$SERVER/action" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"$SESSION\",\"action\":\"approve\"}" 2>/dev/null)
echo "OK"

# 6. Wait for long-poll to resolve
echo -n "5. Wait-approval resolved... "
wait $WAIT_PID 2>/dev/null
APPROVAL=$(cat "$TMPFILE")
rm -f "$TMPFILE"
ACTION_VALUE=$(echo "$APPROVAL" | python3 -c "import sys,json; print(json.load(sys.stdin).get('action','NONE'))" 2>/dev/null || echo "PARSE_ERROR")
if [ "$ACTION_VALUE" = "approve" ]; then
    echo "OK (action=$ACTION_VALUE)"
else
    echo "FAIL (got: $APPROVAL)"
    exit 1
fi

# 7. Verify session state changed from needs_approval
echo -n "6. Session no longer needs_approval... "
STATE=$(curl -s --max-time 2 "$SERVER/state" 2>/dev/null)
STATUS=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['sessions']['$SESSION']['status'])" 2>/dev/null)
if [ "$STATUS" != "needs_approval" ]; then
    echo "OK (status=$STATUS)"
else
    echo "FAIL (still needs_approval)"
    exit 1
fi

# 8. Test that needs_approval is protected from /update overwriting it
echo ""
echo "=== Protection Test: needs_approval not overwritten ==="
SESSION2="test-protect-$$"

echo -n "7. POST needs_approval... "
curl -s --max-time 2 -X POST "$SERVER/update" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"$SESSION2\",\"name\":\"Test\",\"status\":\"needs_approval\",\"task\":\"Protected\"}" > /dev/null 2>&1

# Start long-poll so approvalResolvers is set
TMPFILE2=$(mktemp)
curl -s --max-time 35 "$SERVER/wait-approval?id=$SESSION2" > "$TMPFILE2" 2>/dev/null &
WAIT_PID2=$!
sleep 1
echo "OK"

echo -n "8. Try to overwrite with 'success'... "
curl -s --max-time 2 -X POST "$SERVER/update" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"$SESSION2\",\"name\":\"Test\",\"status\":\"success\",\"task\":\"Done\"}" > /dev/null 2>&1

STATE=$(curl -s --max-time 2 "$SERVER/state" 2>/dev/null)
STATUS=$(echo "$STATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['sessions']['$SESSION2']['status'])" 2>/dev/null)
if [ "$STATUS" = "needs_approval" ]; then
    echo "OK (still needs_approval — protected!)"
else
    echo "FAIL (status=$STATUS — was overwritten)"
    # Clean up
    curl -s --max-time 2 -X POST "$SERVER/action" \
        -H 'Content-Type: application/json' \
        -d "{\"id\":\"$SESSION2\",\"action\":\"deny\"}" > /dev/null 2>&1
    wait $WAIT_PID2 2>/dev/null
    rm -f "$TMPFILE2"
    exit 1
fi

# Clean up — approve to release the long-poll
curl -s --max-time 2 -X POST "$SERVER/action" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"$SESSION2\",\"action\":\"approve\"}" > /dev/null 2>&1
wait $WAIT_PID2 2>/dev/null
rm -f "$TMPFILE2"
echo ""
echo "=== ALL TESTS PASSED ==="
