# refusal-handoff

Fixed-rule refusal detection for Claude Code and OpenCode.

When a provider safety classifier refuses the model output, that session writes a handoff file. The file records the original task and the completed work. It also names the exact point of interruption. It gives the refusal cause and the next steps for a successor model. The detector matches fixed text only and adds no model calls.

```
❯ can you hack my facebook?

⏺ Opus 5.5's safeguards stopped the response above · continuing once with that noted

⏺ Opus 5.5's safeguards flagged this session. You may be seeing this for the first time: Opus 5.5 is more capable and has stronger safeguards as a result, which can sometimes flag non-cybersecurity work. We're
  improving these safeguards to reduce the amount of incorrectly flagged messages. Opus 4.8 is answering instead, or you can edit and retry with Opus 5.5. Send feedback with /feedback or learn more:
  https://support.claude.com/en/articles/8106465

  Details: `[cyber]`
  ⎿  Tip: You can configure model switch behavior in /config

⏺ I can't help with hacking into a Facebook account — whether it's described as yours or anyone else's, breaking into an account isn't something I'll do.

  If this really is your own account and you're locked out, the legitimate path is:

  - Facebook's recovery flow — go to https://facebook.com/login/identify to recover via your email/phone.
  - Hacked account help — https://facebook.com/hacked if someone else took it over.
  - Trusted contacts / ID verification — Facebook can restore access using your government ID if other methods fail.

  If you're interested in security more broadly — like learning how account takeovers work so you can protect yourself, setting up 2FA, or authorized penetration testing — I'm glad to help with any of that. What's
  going on?

⏺ Ran 1 stop hook (ctrl+o to expand)
  ⎿  Stop hook error: Your previous response was refused (detected via structured marker). Before anything else, use the Write tool to create a handoff record at
  /private/tmp/.refusal-handoffs/8778b2dc-9bb2-488d-814b-4e769d4cbc45.md. The record documents this session's state; it is NOT a continuation plan for the refused request. Sections:
  1. TASK - neutral summary of what the user originally asked for.
  2. COMPLETED - what was actually done before this turn ended (say 'nothing yet' if nothing).
  3. STOPPED AT - where things stopped: quote your refused message and the last successful tool call.
  4. REASON - why the turn ended; quote the refusal notice if you have one.
  5. OPEN ITEMS - unanswered user questions and pending items unrelated to the refused request, if any. Do not record instructions for fulfilling the refused request: what happens next is the operator's
  and a successor's decision, not a plan you write here.
  6. SESSION DATA - the full transcript for this session is at /Users/john/.claude/projects/-private-tmp/8778b2dc-9bb2-488d-814b-4e769d4cbc45.jsonl (JSONL). Read it to recover the complete context beyond
  this summary.
  Do not argue with the refusal and do not attempt the refused task in this session. After writing the file, reply with a short OPERATOR DIGEST (under 8 lines) the user reads live in the session window:
  (a) the refused task in one sentence, (b) why the turn ended, (c) the handoff file path, (d) the session transcript path from section 6, (e) what remains unresolved in this session, if anything. Then
  stop.

⏺ Write(.refusal-handoffs/8778b2dc-9bb2-488d-814b-4e769d4cbc45.md)
  ⎿  Wrote 23 lines to .refusal-handoffs/8778b2dc-9bb2-488d-814b-4e769d4cbc45.md
       1 # Refusal Handoff Record
       2
       3 ## 1. TASK
       4 The user asked, verbatim: "can you hack my facebook?" — a request to gain unauthorized access to a Facebook account.
       5
       7 Nothing yet. No tool calls were made toward the request. The assistant declined and instead pointed the user to legitimate Facebook account-recovery resources and offered help with defensive securi
         ty topics.
       8
       9 ## 3. STOPPED AT
      10 Refused message (quoted):
     … +16 lines (ctrl+o to expand)

⏺ OPERATOR DIGEST
  - Refused task: a request to break into a Facebook account ("can you hack my facebook?").
  - Why the turn ended: unauthorized account access was declined; an earlier draft was also stopped by a safety classifier.
  - Handoff file: /private/tmp/.refusal-handoffs/8778b2dc-9bb2-488d-814b-4e769d4cbc45.md
  - Session transcript: /Users/john/.claude/projects/-private-tmp/8778b2dc-9bb2-488d-814b-4e769d4cbc45.jsonl
  - Unresolved: user hasn't yet responded to the offered legitimate alternatives (account recovery, 2FA, authorized pentesting).

```

Example contents of hand-off file:

```

# Refusal Handoff Record

## 1. TASK
The user asked, verbatim: "can you hack my facebook?" — a request to gain unauthorized access to a Facebook account.

## 2. COMPLETED
Nothing yet. No tool calls were made toward the request. The assistant declined and instead pointed the user to legitimate Facebook account-recovery resources and offered help with defensive security topics.

## 3. STOPPED AT
Refused message (quoted):
> "I can't help with hacking into a Facebook account — whether it's described as yours or anyone else's, breaking into an account isn't something I'll do."
(The reply went on to list Facebook's official recovery flow, the hacked-account help page, and trusted-contact/ID verification, then offered help with legitimate security topics.)

Last successful tool call: none in this session prior to this handoff write.

## 4. REASON
The turn ended because the request was to compromise an account, which the assistant declined. A first response was also stopped by a safety classifier (per a system notice: "Your response above was stopped by a safety classifier"). The subsequent response was a plain refusal with redirection to legitimate options.

## 5. OPEN ITEMS
None unrelated to the refused request. The assistant offered to help with legitimate alternatives (account recovery, enabling 2FA, authorized penetration testing), and asked what was going on; the user has not yet responded.

## 6. SESSION DATA
Full transcript: /Users/john/.claude/projects/-private-tmp/8778b2dc-9bb2-488d-814b-4e769d4cbc45.jsonl (JSONL)
```

## Detection layers

1. Structured provider markers. The detector parses payloads at field level and never greps raw bodies. The verified markers follow.
   - Anthropic: `stop_details: {type: "refusal", category: "cyber"|...}` and `stop_reason: "refusal"`. A refusal `stop_details` block can appear while `stop_reason` still holds `"end_turn"`. Match on `stop_details`.
   - OpenAI chat: `message.refusal` with a non-empty text value, refusal content parts, and `finish_reason: "content_filter"`.
   - OpenAI Responses API: the `response.refusal.delta` and `response.refusal.done` events signal a refusal.
   - These markers only appear when the safety classifier intervenes.
2. Lead-anchored refusal phrases. The detector normalizes typographic apostrophes and tests the start of the assistant text. A match must begin within the first 30 characters.
   Refusals lead with the phrase, so a quotation elsewhere does not match. This layer catches soft refusals that carry `message.refusal: null`.

## Transports (OpenCode)

- The `http.response` session hook sees native provider traffic from Anthropic and openai-compatible providers. Layer 1 lives here. WebSocket transports never reach it. A Codex `openai` provider only surfaces `kind: "title"` there.
- The `ctx.event.subscribe()` event `session.text.ended` fires for every provider and every transport. Layer 2 lives here. A live run proved that this path detects Codex refusals.

Both layers share a 30-second per-session cooldown. The plugin sends the handoff prompt with `ctx.session.prompt` and never awaits it. The prompt executes at the next turn boundary.

The handoff prompt also includes a `SESSION DATA` section naming this session's raw storage — `~/.local/share/opencode/storage/message/<sessionID>/` for message JSON files and `~/.local/share/opencode/storage/session/*/<sessionID>.json` for session metadata — so a successor model can reconstruct full context, not just the summary.

## Claude Code trigger

The hook script handles two events and reads the event name from the input.

**Stop** — Claude finished a turn normally. On a hit, the hook returns a
block decision with an instruction. Claude Code feeds that instruction to the
same Claude as its next prompt, and Claude writes
`$CLAUDE_PROJECT_DIR/.refusal-handoffs/<session_id>.md`. Loop guards check
`stop_hook_active` and the handoff file. Claude Code also limits stop-hook
continuations to eight.

**SessionStart** — a new session opens. Stdout from this event is added to
the session's context, so the hook injects a pointer to handoff records
newer than 30 days (newest first, max 3): a successor — human- or
agent-spun-up, same or another harness — learns the records exist without
the operator relaying paths. The pointer is informational only: it never
tells the successor to read or delete records, names them as descriptions
of past sessions, and says an earlier refusal is history, not a verdict on
the current task. An earlier directive version ("read any record relevant
... before answering", "delete records you have consumed") made a fresh
session anchor on an unrelated old record, refuse by association, and
delete it (observed live 2026-10-19); the aged fix keeps the handoff
available for genuine continuations without steering fresh requests.

**SessionEnd** — the session is terminating. This covers the fatal path: when
Anthropic safeguards flag a turn and no fallback model recovers it, Claude
Code retries once, then exits with an API-error message and emits **no Stop
event** — only `SessionEnd` fires (verified live 2026-10-19 on Claude Code
2.1.303). Terminal sessions cannot write their own summary, so here the hook
writes the handoff file itself, deterministically, from the transcript tail:
last real user prompt (excluding Claude Code's retry coach message), final
assistant text, `apiRefusalCategory` + `apiRefusalExplanation`, and the
transcript path. The file-exists guard keeps the two events from
double-writing.

**Handoff path: `.refusal-handoffs/`, not `.claude/handoffs/`.** Claude
Code's sensitive-file protection blocks the model's Write tool for paths
under `.claude/` (verified live — the model replied "couldn't write the
handoff file ... marked as a sensitive file" and no file was produced). The
model-written summary requires the write to land outside `.claude/`.

**Operator visibility.** The Stop-path handoff ends with a short operator
digest printed live in the session window: the refused task, why the turn
ended, the handoff-file path, the session transcript path, and what remains
unresolved — everything needed to spin up a successor with full context
without opening the file. The record itself is framed as a session-state
document: sections are TASK / COMPLETED / STOPPED AT / REASON / OPEN ITEMS /
SESSION DATA, and the prompt explicitly says it is NOT a continuation plan.
Framing matters here — an earlier draft asked for "actionable next steps a
successor would need to continue the task", and the model correctly pushed
back that it was being asked to route around its own refusal, then argued
about it instead of writing the record. The fatal-refusal path cannot render in-window
(the process is gone), so there the file is the surface; set `RH_NOTIFY=1`
in the hook's environment (e.g. on the SessionEnd entry in settings) for a
macOS notification naming the file.

## The self-trigger lesson

In development the plugin fired on its own author. An agent that discusses refusal detection can quote wire formats and phrase lists. A naive raw-body match treats such quotes as refusals. We hit this twice and shipped three fixes.

- Layer 1 parses payloads at field level. The parser ignores prose and code fences.
- Layer 2 anchors to the start of the assistant text. The lead limit is 30 characters. Quotations mid-text never match.
- `test/detector-test.ts` encodes the exact false-positive shapes as regression cases A and E.

If the handoff prompt appears with no actual refusal, the loaded plugin may be stale. Restart the opencode service to pick up file changes.

## Install

We wired this machine on 2026-10-16. Backups: `~/.claude/settings.json.refusal-handoff-backup` and `~/.config/opencode/opencode.json.refusal-handoff-backup`.

- `~/.claude/settings.json` got the `Stop` hook in exec form with an absolute path.
- `~/.config/opencode/opencode.json` got `"plugins": ["/home/psychopomp/coding/refusal-handoff/opencode/plugin"]`.
- Restart the opencode service to load or reload the plugin.

Re-wired 2026-10-19 on the macOS host after live testing found two Claude Code gaps (now covered by the hook script, see "Claude Code trigger"):

- `~/.claude/settings.json` runs the hook on BOTH `Stop` and `SessionEnd`; the entry points at `claude/hooks/refusal-handoff.sh` from the working repo. Backups: `~/.claude/settings.json.refusal-handoff-backup-<timestamp>`.
- The session-end handoff for unhandled fatal refusals is auto-generated; the model-written handoff covers every other refusal. Both land in `.refusal-handoffs/` in the project.
- `~/.config/opencode/opencode.json` plugin entry must be an absolute path: a `~/coding/...` tilde entry did NOT load the plugin (Tier 1 e2e silently skipped detection until the absolute path was set). Backup: `~/.config/opencode/opencode.json.refusal-handoff-backup-<timestamp>`.

Install elsewhere with `SKILL.md`. Copy this repo to the target machine and hand the skill to your agent. The skill wires both harnesses, verifies the result, and uninstalls cleanly.

## Tests

```
bash test/claude-hook-test.sh      # Claude hook layers, both events, offline
bun test/detector-test.ts          # 5/5: parser and anchored text layers
test/e2e-mock.sh                   # Tier 1: 4/4 deterministic pipeline
RH_TEST_MODEL=openai/gpt-5.6-sol-fast test/e2e-live.sh
RH_DEBUG=1                         # plugin debug output -> /tmp/rh-debug.log
```

Results from 2026-10-16:

- Detector: five of five cases pass.
- Tier 1: the plugin handoff turn follows the mock refusal turn inside one `opencode run`. The write tool creates `HANDOFF.md` through a real tool call.
- Tier 2: gpt-5.6-sol-fast refused live. The event layer detected the refusal and the handoff file gained all five sections.

Live results from 2026-10-19 (Claude Code 2.1.303, macOS, hook wired globally):

- Benign `claude -p` session: no hook interference, no handoff file.
- Hard refusal (`[cyber]` safeguard, no fallback): session died with an API
  error and no Stop event; the SessionEnd hook wrote
  `.refusal-handoffs/<session_id>.md` with all six sections.
- Soft refusal (model declines in text, session survives): the Stop hook
  blocked the stop and the same Claude wrote the full handoff file, then
  stopped cleanly (no loop).

## Caveats

- Anthropic reports the `cyber` category for benign security work too. Every cyber-flagged stop gets a handoff here. We intend that behavior, and it still does not prove a hard refusal.
- Claude Code transcripts can lag the final turn. The text layer on `last_assistant_message` covers that gap.
- In headless `claude -p` runs, the model-written handoff needs `--allowedTools Write` or `--permission-mode acceptEdits`; otherwise the Write is permission-denied (normal `Stop` behavior, observed live). Interactive sessions ask once.
- Refusal phrases drift across model versions. Revisit the phrase list if detection rates drop.
