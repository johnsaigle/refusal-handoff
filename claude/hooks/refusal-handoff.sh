#!/usr/bin/env bash
# refusal-handoff — Claude Code Stop hook.
#
# Fires when Claude finishes responding. Deterministically checks for refusal
# markers; on a hit, returns {decision: "block", reason} so the SAME Claude
# session continues and writes the handoff file itself. No extra model calls.
#
# Layer 1 (structured): provider refusal markers persisted in the transcript
#          JSONL — Anthropic "stop_reason":"refusal" / stop_details refusal /
#          "category":"cyber", OpenAI message.refusal.
#          Checked against the last 5 transcript lines only, so an old refusal
#          earlier in the session can't retrigger.
# Layer 2 (text): canonical refusal phrasing in last_assistant_message —
#          catches soft refusals the classifiers didn't flag. Tunable below.
#
# Guards: stop_hook_active (already continuing from a stop hook) and
#         handoff-file-exists (idempotence) prevent loops. Claude Code also
#         caps stop-hook continuations at 8.
#
# Handoff path: $CLAUDE_PROJECT_DIR/.claude/handoffs/<session_id>.md

set -uo pipefail

INPUT=$(cat)

session_id=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
stop_active=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')
last_msg=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // ""')
transcript=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')

project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
handoff_file="$project_dir/.claude/handoffs/${session_id:-unknown}.md"

# --- guards -----------------------------------------------------------------
[ "$stop_active" = "true" ] && exit 0
[ -f "$handoff_file" ] && exit 0

hit=""

# --- layer 1: structured provider markers in the transcript -----------------
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  if tail -n 5 "$transcript" | grep -qE '"stop_reason"[[:space:]]*:[[:space:]]*"refusal"|"stop_details"[^{]*"refusal"|"category"[[:space:]]*:[[:space:]]*"cyber"'; then
    hit="structured"
  fi
fi

# --- layer 2: canonical refusal phrasing at the START of the final message ---
# Refusals lead with the phrase; discussion of refusal phrasings mentions them
# mid-body and must not match. Normalize typographic apostrophes first (models
# emit U+2019), then require the match to begin within the first 30 chars.
# Keep high-precision: "I can't find X" / "I can't provide X (missing file)"
# are NOT refusals and deliberately do not match.
if [ -z "$hit" ] && [ -n "$last_msg" ]; then
  msg_start=$(printf '%s' "$last_msg" | sed "s/’/'/g" | head -c 300)
  lead=$(printf '%s' "$msg_start" | grep -iobE \
    "I (can't|cannot|can not) (help|assist)|I'm unable to (help|assist)|I am unable to (help|assist)|I won't be able to (help|assist)|I must decline|I can't comply|I cannot comply|conflicts with .{0,40}Usage Policy|request was declined" \
    2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$lead" ] && [ "$lead" -le 30 ]; then
    hit="text"
  fi
fi

[ -z "$hit" ] && exit 0

# --- trigger the in-session handoff -----------------------------------------
mkdir -p "$(dirname "$handoff_file")"

reason="Your previous response was refused (detected via $hit marker). Before anything else, use the Write tool to create a complete handoff file at $handoff_file containing these sections:
1. TASK - a neutral summary of what the user originally asked for.
2. COMPLETED - every step that was completed before the refusal.
3. STOPPED AT - exactly where things stopped: quote your refused message and the last successful tool call before it.
4. REASON - why the request was refused (quote the refusal notice if you have it).
5. NEXT STEPS - concrete, actionable instructions a successor model would need to continue.
After writing the file, reply with only the file path and stop. Do not attempt the refused task yourself."

jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
