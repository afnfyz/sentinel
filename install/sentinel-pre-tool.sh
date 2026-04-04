#!/usr/bin/env bash
input=$(cat)
echo '{}'
(
  tool_name=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name','tool'))" 2>/dev/null || echo "tool")
  curl -s -X POST http://localhost:49152/update \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"claude\",\"name\":\"Claude\",\"status\":\"working\",\"task\":\"Running: $tool_name\"}" > /dev/null
) &
