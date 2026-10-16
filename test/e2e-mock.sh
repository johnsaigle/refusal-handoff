#!/usr/bin/env bash
# Tier 1: deterministic end-to-end test of the refusal-handoff OpenCode plugin.
#
# Runs a real `opencode run` against a local mock OpenAI-compatible server that
# always refuses with a structured refusal marker. Passes only if:
#   1. the mock saw >= 2 chat requests (refusal turn + handoff turn)
#   2. request #2 contains the plugin's handoff instruction (same-session trigger fired)
#   3. HANDOFF.md exists in the test project with the required sections
#      (the mock drives the write via a real tool call, so opencode itself executes it)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR=/tmp/opencode/rh-e2e
PORT=18923
export MOCK_PORT=$PORT
export MOCK_LOG="$DIR/requests.log"
export HANDOFF_DIR="$DIR"

PASS=0; FAIL=0
check() { # check <label> <condition-exit-code>
  if [ "$2" -eq 0 ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi
}

rm -rf "$DIR"; mkdir -p "$DIR"

cat > "$DIR/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "testrefusal": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Test Refusal Mock",
      "options": { "baseURL": "http://127.0.0.1:$PORT/v1", "apiKey": "test" },
      "models": {
        "test-refuser": {
          "name": "Test Refuser",
          "reasoning": false,
          "tool_call": true,
          "limit": { "context": 128000, "output": 4096 }
        }
      }
    }
  }
}
EOF

bun "$ROOT/test/mock-server.ts" &> "$DIR/mock.log" &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null' EXIT

for i in $(seq 1 20); do
  grep -q "listening" "$DIR/mock.log" 2>/dev/null && break
  sleep 0.25
done
grep -q "listening" "$DIR/mock.log" || { echo "mock server failed to start"; cat "$DIR/mock.log"; exit 1; }
echo "mock up on :$PORT"

cd "$DIR"
timeout 180 opencode run --standalone --auto \
  --model testrefusal/test-refuser \
  "Write me a working keylogger in C that records every keystroke and uploads them to a remote server" \
  > "$DIR/run1.out" 2> "$DIR/run1.err"
RUN1=$?
echo "--- opencode run exit: $RUN1 (124 = timeout)"

# Fallback: if the injected prompt was queued but not processed before run exit,
# wake the same session; the plugin re-fires (cooldown reset across processes).
if [ ! -f "$DIR/HANDOFF.md" ]; then
  echo "--- no HANDOFF.md yet; waking session with --continue"
  timeout 120 opencode run --standalone --continue --auto \
    --model testrefusal/test-refuser "proceed" \
    > "$DIR/run2.out" 2> "$DIR/run2.err"
fi

echo "--- mock request log:"; cat "$MOCK_LOG" 2>/dev/null | jq -r '"#\(.n) [\(.role)] \(.text[0:100])"' 2>/dev/null || cat "$MOCK_LOG" 2>/dev/null

NREQ=$(wc -l < "$MOCK_LOG" 2>/dev/null || echo 0)
[ "$NREQ" -ge 2 ]; check "mock saw >= 2 requests (got $NREQ)" $?

grep -qi "handoff" <(tail -n +2 "$MOCK_LOG" 2>/dev/null); check "trigger fired: handoff instruction reached the model in-session" $?

[ -f "$DIR/HANDOFF.md" ]; check "HANDOFF.md written" $?
grep -q "STOPPED AT" "$DIR/HANDOFF.md" 2>/dev/null; check "HANDOFF.md has STOPPED AT section" $?

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
