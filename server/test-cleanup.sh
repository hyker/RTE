#!/bin/bash
# Test TOE cleanup behavior.
# Prerequisites:
#   - Dev VM booted with --dev (SSH on port 2223)
#   - custodes built with test timing (MaxTOEAge=30s, sweepInterval=10s)
#
# Usage: ./test-cleanup.sh <password> [ssh-port]
#   password: root password set during --debug build
#   Default ssh-port: 2223

set -uo pipefail

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <password> [ssh-port]"
  exit 1
fi

SSH_PASS="$1"
SSH_PORT="${2:-2223}"
SSH="sshpass -p $SSH_PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p $SSH_PORT root@localhost"
TOE_DIR="/var/tmp/custodes/toes"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== TOE Cleanup Tests ==="
echo "SSH port: $SSH_PORT"
echo ""

# Verify SSH connectivity
echo "Checking SSH connectivity..."
if ! $SSH "echo ok" >/dev/null 2>&1; then
  echo "ERROR: Cannot SSH into VM on port $SSH_PORT"
  echo "Make sure the dev VM is booted (./boot.sh --dev) and SSH is available."
  exit 1
fi
echo "SSH connected."
echo ""

# Helper: create fake TOE files for a given job ID and state
# Usage: create_toe <jobID> <state>
#   state: "done"    -> .input .suite .output
#          "failed"  -> .input .suite .failed
#          "running" -> .input .suite .running
create_toe() {
  local id="$1" state="$2"
  $SSH "echo 'fake-input' > $TOE_DIR/$id.input && echo '{\"tool_name\":\"cppcheck\"}' > $TOE_DIR/$id.suite"
  case $state in
    done)    $SSH "echo '{\"results\":\"ok\"}' > $TOE_DIR/$id.output" ;;
    failed)  $SSH "echo '{\"tool_name\":\"cppcheck\"}' > $TOE_DIR/$id.failed" ;;
    running) $SSH "touch $TOE_DIR/$id.running" ;;
  esac
}

# Helper: check if a file exists in the VM
file_exists() {
  $SSH "test -f $TOE_DIR/$1" 2>/dev/null
}

# Helper: curl /result from inside the VM
get_result() {
  $SSH "curl -sk -X POST https://localhost:9000/result -H 'Content-Type: application/json' -d '{\"jobID\": \"$1\"}'"
}

# -------------------------------------------------------
# Test 1: not_found for non-existent job
# -------------------------------------------------------
echo "--- Test 1: not_found response for bogus job ID ---"
RESP=$(get_result "BOGUS_NONEXISTENT_ID")
if echo "$RESP" | grep -q '"reason":"not_found"'; then
  pass "got reason=not_found"
else
  fail "expected reason=not_found, got: $RESP"
fi
echo ""

# -------------------------------------------------------
# Test 2: successful result download cleans up files
# -------------------------------------------------------
echo "--- Test 2: cleanup after successful result download ---"
TEST2_ID="test_cleanup_done"
create_toe "$TEST2_ID" "done"

# Verify files exist
if file_exists "$TEST2_ID.input" && file_exists "$TEST2_ID.output"; then
  pass "TOE files created"
else
  fail "TOE files not created"
fi

# Fetch result
RESP=$(get_result "$TEST2_ID")
if echo "$RESP" | grep -q '"status":"done"'; then
  pass "got status=done"
else
  fail "expected status=done, got: $RESP"
fi

# Verify files are cleaned up
sleep 0.5
if ! file_exists "$TEST2_ID.input" && ! file_exists "$TEST2_ID.output" && ! file_exists "$TEST2_ID.suite"; then
  pass "files deleted after download"
else
  fail "files still exist after download"
fi

# Verify no expired marker (cleanup-on-download should not leave one)
if ! file_exists "$TEST2_ID.expired"; then
  pass "no .expired marker (correct for download cleanup)"
else
  fail ".expired marker should not exist for download cleanup"
fi

# Second fetch should return not_found
RESP=$(get_result "$TEST2_ID")
if echo "$RESP" | grep -q '"reason":"not_found"'; then
  pass "second fetch returns not_found"
else
  fail "expected not_found on second fetch, got: $RESP"
fi
echo ""

# -------------------------------------------------------
# Test 3: error result download cleans up files
# -------------------------------------------------------
echo "--- Test 3: cleanup after error result download ---"
TEST3_ID="test_cleanup_fail"
create_toe "$TEST3_ID" "failed"

RESP=$(get_result "$TEST3_ID")
if echo "$RESP" | grep -q '"reason":"processing_failed"'; then
  pass "got reason=processing_failed"
else
  fail "expected reason=processing_failed, got: $RESP"
fi

sleep 0.5
if ! file_exists "$TEST3_ID.input" && ! file_exists "$TEST3_ID.failed" && ! file_exists "$TEST3_ID.suite"; then
  pass "files deleted after error download"
else
  fail "files still exist after error download"
fi
echo ""

# -------------------------------------------------------
# Test 4: pending job (running) is not cleaned up
# -------------------------------------------------------
echo "--- Test 4: pending job stays intact ---"
TEST4_ID="test_cleanup_run"
create_toe "$TEST4_ID" "running"

RESP=$(get_result "$TEST4_ID")
if echo "$RESP" | grep -q '"status":"pending"'; then
  pass "got status=pending"
else
  fail "expected status=pending, got: $RESP"
fi

if file_exists "$TEST4_ID.input" && file_exists "$TEST4_ID.running"; then
  pass "running job files still intact"
else
  fail "running job files were incorrectly deleted"
fi

# Clean up this one manually
$SSH "rm -f $TOE_DIR/$TEST4_ID.*"
echo ""

# -------------------------------------------------------
# Test 5: stale sweeper cleans up old files + leaves .expired
# -------------------------------------------------------
echo "--- Test 5: stale sweeper (wait ~45s) ---"
TEST5_ID="test_sweeper_stale"
create_toe "$TEST5_ID" "done"

# Backdate files to be older than MaxTOEAge (30s for testing)
$SSH "touch -d '2 minutes ago' $TOE_DIR/$TEST5_ID.*"

if file_exists "$TEST5_ID.input"; then
  pass "stale TOE files created and backdated"
else
  fail "failed to create stale TOE files"
fi

echo "  Waiting for sweeper to run (up to 45s)..."
SWEPT=false
for i in $(seq 1 9); do
  sleep 5
  if ! file_exists "$TEST5_ID.input"; then
    SWEPT=true
    break
  fi
  echo "  ... still waiting (${i}0s)"
done

if $SWEPT; then
  pass "sweeper deleted stale files"
else
  fail "sweeper did not delete stale files within 45s"
fi

# Check .expired marker
if file_exists "$TEST5_ID.expired"; then
  pass ".expired marker left behind"
else
  fail ".expired marker not found"
fi

# Fetch result — should get "expired"
RESP=$(get_result "$TEST5_ID")
if echo "$RESP" | grep -q '"reason":"expired"'; then
  pass "got reason=expired for swept job"
else
  fail "expected reason=expired, got: $RESP"
fi

# Clean up marker
$SSH "rm -f $TOE_DIR/$TEST5_ID.*"
echo ""

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -eq 0 ]; then
  echo "All tests passed!"
  exit 0
else
  echo "Some tests failed."
  exit 1
fi
