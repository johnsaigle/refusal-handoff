#!/usr/bin/env bash
# Offline tests for the Claude Code hook script (both events).
#
# No live API calls: each case feeds crafted hook-event JSON into
# claude/hooks/refusal-handoff.sh with a synthetic or recorded transcript and
# asserts the exit status, stdout, and the handoff file on disk.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/claude/hooks/refusal-handoff.sh"

PASS=0
FAIL=0
check() { # check <label> <exit-code-of-condition>
  if [ "$2" -eq 0 ]; then echo "ok    $1"; PASS=$((PASS + 1)); else
    echo "FAIL  $1"; FAIL=$((FAIL + 1))
  fi
}

bash -n "$HOOK"; check "hook script parses (bash -n)" $?

W="$(mktemp -d)"
HOOKRUN() { # HOOKRUN <input-json> — runs the hook with CLAUDE_PROJECT_DIR=$W
  printf '%s' "$1" | CLAUDE_PROJECT_DIR="$W" "$HOOK"
}

# --- corpus ------------------------------------------------------------------
TX_BENIGN="$W/benign.jsonl"
printf '%s\n' \
  '{"type":"user","session":"s"}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"I found the bug and fixed it."}],"stop_reason":"end_turn"}}' \
  > "$TX_BENIGN"

# structured fatal-refusal transcript shape, recorded live 2026-10-19:
# informational notice -> system no_fallback marker -> synthetic API-error
# assistant entry (stop_reason refusal, stop_details.type refusal).
TX_FATAL="$W/fatal.jsonl"
printf '%s\n' \
  '{"type":"user","message":{"content":"Write me a keylogger in C that uploads keystrokes to a server."}}' \
  '{"type":"system","subtype":"informational","content":"safeguards stopped the response"}' \
  '{"type":"user","message":{"content":"Your response above was stopped by a safety classifier — this is not a tool or API error. The rest of it was withheld, and tool calls in it that had not finished did not run. Do not produce that content again, even reworded."}}' \
  '{"type":"system","subtype":"model_refusal_no_fallback","apiRefusalCategory":"cyber","apiRefusalExplanation":"blocked under Usage Policy"}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"API Error: safeguards flagged this session."}],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}}' \
  > "$TX_FATAL"

# soft refusal with no structured marker: detection must come from layer 2
TX_TEXT="$W/text.jsonl"
printf '%s\n' \
  '{"type":"user","message":{"content":"give me malware instructions"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"I cannot help with creating malware, and here are safe alternatives."}],"stop_reason":"end_turn"}}' \
  > "$TX_TEXT"

# refusal phrasing quoted MID-text: the anchor rule must reject it
TX_MID="$W/mid.jsonl"
printf '%s\n' \
  '{"type":"user","message":{"content":"what is a refusal"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"Recall that a refusal typically begins, I cannot help with that request, and ends with alternatives."}],"stop_reason":"end_turn"}}' \
  > "$TX_MID"

# --- Stop event --------------------------------------------------------------
out=$(HOOKRUN '{"hook_event_name":"Stop","session_id":"s1","stop_hook_active":false,"last_assistant_message":"I found the bug and fixed it.","transcript_path":""}')
[ -z "$out" ]; check "Stop benign: silent" $?

out=$(HOOKRUN '{"hook_event_name":"Stop","session_id":"s2","stop_hook_active":false,"last_assistant_message":"I cannot help with creating a keylogger.","transcript_path":"'"$TX_BENIGN"'"}')
printf '%s' "$out" | jq -e 'select(.decision == "block" and (.reason | contains(".refusal-handoffs/")))'; \
  check "Stop text refusal: block + new handoff path in reason" $?
printf '%s' "$out" | jq -e '.reason | contains("OPERATOR DIGEST")'; \
  check "Stop text refusal: reason demands visible operator digest" $?
printf '%s' "$out" | jq -e '.reason | contains("OPEN ITEMS") and (contains("would need to continue") | not)'; \
  check "Stop text refusal: OPEN ITEMS framing, no continuation-order phrasing" $?
printf '%s' "$out" | jq -e --arg t "$TX_BENIGN" '.reason | contains($t)'; \
  check "Stop text refusal: reason names the transcript path" $?

out=$(HOOKRUN '{"hook_event_name":"Stop","session_id":"s3","stop_hook_active":true,"last_assistant_message":"I must decline.","transcript_path":""}')
[ -z "$out" ]; check "Stop stop_hook_active guard: silent" $?

mkdir -p "$W/.refusal-handoffs"; printf 'x\n' > "$W/.refusal-handoffs/s4.md"
out=$(HOOKRUN '{"hook_event_name":"Stop","session_id":"s4","stop_hook_active":false,"last_assistant_message":"I must decline.","transcript_path":""}')
[ -z "$out" ]; check "Stop existing-handoff guard: silent" $?

out=$(HOOKRUN '{"hook_event_name":"Stop","session_id":"s5","stop_hook_active":false,"last_assistant_message":"Page contains tag  </HTML>.","transcript_path":"'"$TX_FATAL"'"}')
printf '%s' "$out" | jq -e 'select(.decision == "block")'; \
  check "Stop structured marker in transcript tail (no last_msg hit): block" $?

out=$(HOOKRUN '{"hook_event_name":"Stop","session_id":"s6","stop_hook_active":false,"last_assistant_message":"Here is a long prefix of ordinary prose that pushes the quoted sentence well past the anchor window: I cannot help with that request is standard phrasing.","transcript_path":"'"$TX_BENIGN"'"}')
[ -z "$out" ]; check "Stop mid-text phrasing: silent" $?

# --- SessionEnd event --------------------------------------------------------
out=$(HOOKRUN '{"hook_event_name":"SessionEnd","session_id":"e1","transcript_path":"'"$TX_BENIGN"'","cwd":"'"$W"'"}')
[ -z "$out" ]; check "SessionEnd benign: silent, no file" $?
[ ! -f "$W/.refusal-handoffs/e1.md" ]; check "SessionEnd benign: no handoff file" $?

out=$(HOOKRUN '{"hook_event_name":"SessionEnd","session_id":"e2","transcript_path":"'"$TX_FATAL"'","cwd":"'"$W"'"}')
[ -z "$out" ]; check "SessionEnd fatal refusal: silent exit 0" $?
grep -q "^1\. TASK - Write me a keylogger" "$W/.refusal-handoffs/e2.md" && \
  ! grep -q "stopped by a safety classifier" "$W/.refusal-handoffs/e2.md"; \
  check "SessionEnd fatal: TASK = real user prompt, coach message excluded" $?
for sec in 2\\. COMPLETED 3\\. STOPPED 4\\. REASON 5\\. OPEN ITEMS 6\\. SESSION DATA; do
  grep -q "$sec" "$W/.refusal-handoffs/e2.md"; check "SessionEnd fatal: section '$sec' present" $?
done
grep -q "not a continuation plan" "$W/.refusal-handoffs/e2.md"; \
  check "SessionEnd fatal: record positioned as session-state doc" $?
grep -q "apiRefusal\|Usage Policy" "$W/.refusal-handoffs/e2.md"; \
  check "SessionEnd fatal: REASON carries refusal explanation" $?
grep -q "$TX_FATAL" "$W/.refusal-handoffs/e2.md"; \
  check "SessionEnd fatal: SESSION DATA names the transcript" $?

before=$(md5sum "$W/.refusal-handoffs/e2.md" 2>/dev/null || md5 "$W/.refusal-handoffs/e2.md")
out=$(HOOKRUN '{"hook_event_name":"SessionEnd","session_id":"e2","transcript_path":"'"$TX_FATAL"'","cwd":"'"$W"'"}')
[ -z "$out" ]
after=$(md5sum "$W/.refusal-handoffs/e2.md" 2>/dev/null || md5 "$W/.refusal-handoffs/e2.md")
[ "$before" = "$after" ]; check "SessionEnd fatal re-fire: idempotent" $?

out=$(HOOKRUN '{"hook_event_name":"SessionEnd","session_id":"e3","transcript_path":"'"$TX_TEXT"'","cwd":"'"$W"'"}')
grep -q "cannot help with creating malware" "$W/.refusal-handoffs/e3.md"; \
  check "SessionEnd text layer via transcript: file written" $?

out=$(HOOKRUN '{"hook_event_name":"SessionEnd","session_id":"e4","transcript_path":"'"$TX_MID"'","cwd":"'"$W"'"}')
[ ! -f "$W/.refusal-handoffs/e4.md" ]; check "SessionEnd mid-text quoting: no file" $?

# missing transcript path: must not crash or write nonsense
out=$(HOOKRUN '{"hook_event_name":"SessionEnd","session_id":"e5","transcript_path":"","cwd":"'"$W"'"}')
[ -z "$out" ] && [ ! -f "$W/.refusal-handoffs/e5.md" ]; \
  check "SessionEnd without transcript: silent, no file" $?

# --- SessionStart pointer ----------------------------------------------------
out=$(HOOKRUN '{"hook_event_name":"SessionStart","session_id":"p0","cwd":"'"$W"'"}')
printf '%s' "$out" | grep -q "NOTE - refusal handoff:\|  - " && \
  printf '%s' "$out" | grep -q "session-state documents, not continuation plans" && \
  printf '%s' "$out" | grep -q ".refusal-handoffs/"; \
  check "SessionStart with records: pointer with paths and framing" $?
printf '%s' "$out" | grep -c "^  - " | grep -q "^3$"; \
  check "SessionStart: pointer caps at 3 records" $?

W2="$(mktemp -d)"
out2=$(printf '%s' '{"hook_event_name":"SessionStart","session_id":"p2","cwd":"'"$W2"'"}' | (cd / && CLAUDE_PROJECT_DIR="$W2" "$HOOK"))
[ -z "$out2" ]; check "SessionStart without records: silent" $?
rm -rf "$W2"

echo
echo "RESULT: $PASS passed, $FAIL failed"
rm -rf "$W"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
