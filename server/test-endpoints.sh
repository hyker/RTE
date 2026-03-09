#!/bin/bash
# Test suite for custodes endpoints
# Usage: ./test-endpoints.sh <dev|staging>

if [ -z "$1" ]; then
  echo "Usage: $0 <dev|staging>"
  exit 1
fi

case $1 in
  dev)
    PORT=9001
    ;;
  staging)
    PORT=8444
    ;;
  *)
    echo "Usage: $0 <dev|staging>"
    exit 1
    ;;
esac

BASE_URL="https://localhost:$PORT"
FAILED=0

echo "Testing custodes endpoints ($1 - port $PORT)"
echo "========================================="

# Test /tools
echo -n "Testing /tools... "
TOOLS=$(curl -sk "$BASE_URL/tools")
if echo "$TOOLS" | grep -q '"tool_name":"cppcheck"'; then
    echo "OK"
else
    echo "FAILED"
    FAILED=1
fi

# Test /quote
echo -n "Testing /quote... "
QUOTE=$(curl -sk "$BASE_URL/quote")
if echo "$QUOTE" | grep -q '"quote_data":"[A-Za-z0-9+/=]\{100,\}"'; then
    echo "OK"
else
    echo "FAILED"
    FAILED=1
fi

# Test /upload
echo -n "Testing /upload... "
TEST_FILE=$(echo 'int main() { return 0; }' | base64)
UPLOAD=$(curl -sk -X POST "$BASE_URL/upload" \
    -H "Content-Type: application/json" \
    -d '{"toe": {"format": "c", "base64_encoded_toe": "'"$TEST_FILE"'"}, "test": {"tool_name": "cppcheck", "parameters": []}}')
JOB_ID=$(echo "$UPLOAD" | grep -o '"jobID"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
if [ -n "$JOB_ID" ]; then
    echo "OK (jobID: $JOB_ID)"
else
    echo "FAILED"
    FAILED=1
fi

# Test /result (wait for job to complete)
echo -n "Testing /result... "
sleep 2
RESULT=$(curl -sk -X POST "$BASE_URL/result" \
    -H "Content-Type: application/json" \
    -d '{"jobID": "'"$JOB_ID"'"}')
if echo "$RESULT" | grep -q '"status":"done"' && echo "$RESULT" | grep -q '"quote_data"'; then
    echo "OK"
else
    echo "FAILED"
    FAILED=1
fi

echo "========================================="
if [ $FAILED -eq 0 ]; then
    echo "All tests passed"
    exit 0
else
    echo "Some tests failed"
    exit 1
fi
