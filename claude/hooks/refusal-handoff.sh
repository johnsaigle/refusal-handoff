#!/usr/bin/env bash
# refusal-handoff — Claude Code Stop + SessionEnd hook.
#
# Stop event: fires when Claude finishes responding. Deterministically checks
# for refusal markers; on a hit, returns {decision: "block", reason} so the
# SAME Claude session continues and writes the handoff file itself. No extra
# model calls.
#
# SessionEnd event: fires when the session terminates. Covers the fatal path
# where the Stop hook never runs: Anthropic safeguards flag the turn,
# Claude Code retries once, and with no fallback model the CLI exits with an
# API-error message (transcript entry "subtype":"model_refusal_no_fallback")
# WITHOUT emitting a Stop event (verified live 2026-10-19: only SessionEnd
# fires on that path). Here the hook writes the handoff file itself,
# deterministically, from the transcript tail.
#
# Layer 1 (structured): provider refusal markers persisted in the transcript
#          JSONL — Anthropic "stop_reason":"refusal" / stop_details refusal /
#          "category":"cyber", OpenAI message.refusal, and the Claude Code
#          "subtype":"model_refusal_fallback" entry (a safeguard flag that
#          switched models mid-turn; the fallback answer is not itself a
#          refusal, so only this marker records the event).
#          Checked against the last 15 transcript lines only, so an old refusal
#          earlier in the session can't retrigger.
# Layer 2 (text): canonical refusal phrasing in last_assistant_message —
#          catches soft refusals the classifiers didn't flag. Tunable below.
#
# Guards: stop_hook_active (already continuing from a stop hook) and
#         handoff-file-exists (idempotence) prevent loops. Claude Code also
#         caps stop-hook continuations at 8.
#
# Handoff path: $CLAUDE_PROJECT_DIR/.refusal-handoffs/<session_id>.md
# (not under .claude/: Claude Code's sensitive-file protection blocks the
# model's Write tool inside .claude/, verified live 2026-10-19 — the model
# replied "couldn't write the handoff file ... marked as a sensitive file"
# and no file was produced. `.refusal-handoffs/` avoids that.)

set -uo pipefail

INPUT=$(cat)

session_id=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
stop_active=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')
last_msg=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // ""')
transcript=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')
event=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // "Stop"')

project_dir="${CLAUDE_PROJECT_DIR:-$(printf '%s' "$INPUT" | jq -r '.cwd // empty')}"
[ -n "$project_dir" ] || project_dir="$PWD"
handoff_file="$project_dir/.refusal-handoffs/${session_id:-unknown}.md"

# --- guards -----------------------------------------------------------------
# stop_hook_active only exists on Stop events.
[ "$event" = "Stop" ] && [ "$stop_active" = "true" ] && exit 0

# --- SessionStart: surface existing handoff records to a new session --------
# SessionStart stdout is added to the new session's context, so a successor
# starting in this project learns of unhandled handoff records without the
# operator copying paths. Pointer only: the hook injects file paths, never a
# continuation plan — what to do is the successor's and operator's decision.
if [ "$event" = "SessionStart" ]; then
  dir="$project_dir/.refusal-handoffs"
  [ -d "$dir" ] || exit 0
  # Skip records older than 30 days: stale artifacts (often in shared
  # scratch dirs) should not surface in fresh sessions forever. Guard the
  # ls call: with zero candidates, ls -t must not fall back to listing the
  # hook process's current directory.
  files=$(find "$dir" -maxdepth 1 -name '*.md' -mtime -30 2>/dev/null)
  [ -n "$files" ] || exit 0
  set --
  for f in $(command ls -t $files); do
    [ -f "$f" ] || continue
    if [ "$#" -lt 3 ]; then set -- "$@" "$f"; fi
  done
  [ "$#" -gt 0 ] || exit 0
  printf 'NOTE - refusal handoff: earlier session(s) in this project ended on a provider safety refusal and left record(s) in .refusal-handoffs/. Newest first:\n'
  for f in "$@"; do printf '  - %s (the session transcript path is inside, section 6)\n' "$f"; done
  printf 'These records describe PAST sessions only. A record matters here only if the current task continues the work it describes. An earlier refusal is history, not a verdict on this session: judge each request in this session on its own terms. Leave the records on disk; deleting them is the operator call, not yours.\n'
  exit 0
fi

[ -f "$handoff_file" ] && exit 0

hit=""

# --- SessionEnd: derive the final assistant text from the transcript ---------
# SessionEnd input carries no last_assistant_message, and the fatal refusal
# path ends the session with the API-error text as the last assistant entry,
# so the text layer must run against the transcript. Tail 200 lines: enough to
# reach the pre-refusal user prompt past this turn's telemetry entries.
tailbuf=""
if [ "$event" = "SessionEnd" ] && [ -n "$transcript" ] && [ -f "$transcript" ]; then
  tailbuf=$(tail -n 200 "$transcript")
  last_msg=$(printf '%s' "$tailbuf" | jq -sr '
    [ .[] | select(.type=="assistant")
      | .message.content[]? | select(.type=="text") | .text ]
    | if length > 0 then .[-1] else "" end' 2>/dev/null)
fi

# --- layer 1: structured provider markers in the transcript -----------------
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # model_refusal_fallback: Claude Code switched models after a safeguard flag
  # (e.g. [cyber]); the flagged turn is recovered by a fallback model, so the
  # final message is NOT a refusal, but the switch still warrants a handoff.
  # Read tail via process substitution, not a pipe: with `set -o pipefail`, a
  # `tail | grep -q` pipeline reports failure when grep matches early and exits,
  # because tail then dies with SIGPIPE (transcript lines are large, so the tail
  # output exceeds the pipe buffer). Process substitution keeps tail out of the
  # pipeline so only grep's own exit status is tested.
  if grep -qE '"stop_reason"[[:space:]]*:[[:space:]]*"refusal"|"stop_details"[^{]*"refusal"|"category"[[:space:]]*:[[:space:]]*"cyber"|"subtype"[[:space:]]*:[[:space:]]*"model_refusal_fallback"|"subtype"[[:space:]]*:[[:space:]]*"model_refusal_no_fallback"|"apiRefusalCategory"' < <(tail -n 15 "$transcript"); then
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

mkdir -p "$(dirname "$handoff_file")"

# --- SessionEnd: no model turn is possible; write the handoff directly -------
if [ "$event" = "SessionEnd" ]; then
  task=$(printf '%s' "$tailbuf" | jq -sr '
    [ .[] | select(.type=="user") | .message.content
      | select(type=="string")
      | select(test("stopped by a safety classifier|Caveat:") | not) ]
    | if length > 0 then .[-1] else "" end' 2>/dev/null)
  explanation=$(printf '%s' "$tailbuf" | jq -sr '
    [ .[] | select(.type=="system") | .apiRefusalExplanation
      | select(type=="string") ] | if length > 0 then .[-1] else "" end' 2>/dev/null)
  category=$(printf '%s' "$tailbuf" | jq -sr '
    [ .[] | select(.type=="system") | .apiRefusalCategory
      | select(type=="string") ] | if length > 0 then .[-1] else "unknown" end' 2>/dev/null)

  trunc() { # trunc <max-chars> — last argument value comes from stdin
    awk -v max="$1" '{ if (length($0) > max) $0 = substr($0, 1, max) " …[truncated]"; print }'
  }

  {
    printf '# Refusal handoff — %s\n\n' "${session_id:-unknown}"
    printf '> Auto-generated by the refusal-handoff SessionEnd hook: the session\n'
    printf '> terminated on this refusal, so no model turn was available to write\n'
    printf '> this summary. All content below is extracted from the session\n'
    printf '> transcript. Read SESSION DATA (section 6) for complete context.\n\n'
    printf '1. TASK - %s\n\n' "$(printf '%s' "$task" | sed 's/\r//g' | trunc 600)"
    printf '2. COMPLETED - not recorded: the refusal ended the session with no\n'
    printf '   surviving turn to summarize. Recover completed work from the\n'
    printf '   transcript (assistant text and tool entries before the refusal).\n\n'
    printf '3. STOPPED AT - the provider safety refusal ended this turn. Final\n'
    printf '   assistant entry:\n\n   > %s\n\n' \
      "$(printf '%s' "$last_msg" | sed 's/^[[:space:]]*//; s/\r//g' | trunc 400 | awk 'NR==1 { printf "%s", $0; next } { printf "\n   > %s", $0 }')"
    printf '4. REASON - category "%s". %s\n\n' "$category" "$(printf '%s' "$explanation" | trunc 400)"
    printf '5. OPEN ITEMS - unanswered questions and pending items, if any, are\n'
    printf '   recoverable from the transcript (section 6). This record documents\n'
    printf '   session state, not a continuation plan: what to run next, and on\n'
    printf '   which model, is the operator'"'"'s and a successor'"'"'s decision.\n\n'
    if [ -n "$transcript" ]; then
      printf '6. SESSION DATA - full transcript for this session (JSONL):\n   %s\n' "$transcript"
    else
      printf '6. SESSION DATA - full transcript is under %s/.claude/projects/ as <session_id>.jsonl.\n' "$HOME"
    fi
  } > "$handoff_file"

  # The session is dead, so no in-window digest is possible here; the file is
  # the operator surface. Opt-in notification so the operator learns the path
  # without scanning for the file.
  if [ "${RH_NOTIFY:-0}" = "1" ] && command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"Refusal handoff for this session is at .refusal-handoffs/${session_id:-unknown}.md in $(basename "$project_dir") — open it for task, stop point, and next steps.\" with title \"Refusal handoff written\"" >/dev/null 2>&1 || true
  fi
  exit 0
fi

# Session data pointer (issue #1): the hook input carries transcript_path, the
# exact JSONL a successor session can read to recover full context. Fall back
# to the projects directory when the path is missing.
if [ -n "$transcript" ]; then
  session_data="6. SESSION DATA - the full transcript for this session is at $transcript (JSONL). Read it to recover the complete context beyond this summary."
else
  session_data="6. SESSION DATA - the full transcript for this session is under $HOME/.claude/projects/ as <session_id>.jsonl. Read it to recover the complete context beyond this summary."
fi

reason="Your previous response was refused (detected via $hit marker). Before anything else, use the Write tool to create a handoff record at $handoff_file. The record documents this session's state; it is NOT a continuation plan for the refused request. Sections:
1. TASK - neutral summary of what the user originally asked for.
2. COMPLETED - what was actually done before this turn ended (say 'nothing yet' if nothing).
3. STOPPED AT - where things stopped: quote your refused message and the last successful tool call.
4. REASON - why the turn ended; quote the refusal notice if you have one.
5. OPEN ITEMS - unanswered user questions and pending items unrelated to the refused request, if any. Do not record instructions for fulfilling the refused request: what happens next is the operator's and a successor's decision, not a plan you write here.
$session_data
Do not argue with the refusal and do not attempt the refused task in this session. After writing the file, reply with a short OPERATOR DIGEST (under 8 lines) the user reads live in the session window: (a) the refused task in one sentence, (b) why the turn ended, (c) the handoff file path, (d) the session transcript path from section 6, (e) what remains unresolved in this session, if anything. Then stop."

jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
