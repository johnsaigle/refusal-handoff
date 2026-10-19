# refusal-handoff

Refusal detection and session handoff for Claude Code and OpenCode.

When a safety classifier or the model itself refuses, the session writes a handoff record. The record lists the task, the completed work, the stop point, the refusal reason, open items, and the transcript path. Detection uses fixed text rules and adds no extra model calls.

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
  ⎿  Stop hook error: Your previous response was refused (detected via structured marker). Before anything else, use the Write tool to create a handoff record at
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
  ⎿  Wrote 23 lines to .refusal-handoffs/8778b2dc-9bb2-488d-814b-4e769d4cbc45.md
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

## Install

Prerequisites: `jq`. Tests also need `bun`. Use Claude Code, OpenCode v2, or both.

### Claude Code

```sh
REPO=/absolute/path/to/refusal-handoff
cp ~/.claude/settings.json ~/.claude/settings.json.refusal-handoff-backup
for EVT in Stop SessionEnd SessionStart; do
jq --arg cmd "$REPO/claude/hooks/refusal-handoff.sh" --arg evt "$EVT" \
  '.hooks[$evt] = ((.hooks[$evt] // [])
    | (if any(.[]; .hooks[]?.command == $cmd) then .
       else . + [ { hooks: [ { type: "command", command: $cmd, args: [], timeout: 15 } ] } ] end))' \
  ~/.claude/settings.json > /tmp/rh-settings.new && mv /tmp/rh-settings.new ~/.claude/settings.json
done
chmod +x "$REPO/claude/hooks/refusal-handoff.sh"
```

The merge is idempotent. New sessions pick it up automatically. Keep the repo at that path: settings invoke the script there.

### OpenCode

```sh
REPO=/absolute/path/to/refusal-handoff
cp ~/.config/opencode/opencode.json ~/.config/opencode/opencode.json.refusal-handoff-backup
jq --arg p "$REPO/opencode/plugin" \
  '.plugins = ((.plugins // []) | (if index($p) then . else . + [$p] end))' \
  ~/.config/opencode/opencode.json > /tmp/rh-oc.new && mv /tmp/rh-oc.new ~/.config/opencode/opencode.json
opencode service restart
```

The path must be absolute: a `~/` entry does not load the plugin. Plugin file changes also need a service restart.

### Install somewhere else

Copy this repo to the target machine and hand the agent `SKILL.md` from the copy. The skill wires one or both harnesses, verifies the result, and uninstalls cleanly.

## How it works

Two detection layers. Both match fixed text:

1. Structured provider markers, parsed at field level. The parser inspects payload fields and never raw bodies:
   - Anthropic: `stop_reason: "refusal"` and `stop_details: {type: "refusal", ...}`
   - OpenAI chat: a non-empty `message.refusal` field
   - OpenAI chat: refusal parts, or `finish_reason: "content_filter"`
   - OpenAI Responses API: `response.refusal.*` events
   - A session transcript entry with the `model_refusal_fallback` subtype, or with `model_refusal_no_fallback`
2. Lead-anchored refusal phrases at the start of the assistant text. The match must begin within the first 30 characters, so text that only quotes a refusal never matches. Typographic apostrophes get normalized first. Cases A and E of `test/detector-test.ts` pin the quoted shapes that once caused self-triggers.

### Claude Code events

- Stop: Claude finished a turn and a marker hit. Claude Code feeds the hook instruction to the same Claude. Claude writes `.refusal-handoffs/<session_id>.md` and then prints a short OPERATOR DIGEST in the session window. The digest lists the refused task, why the turn ended, the record path, the transcript path, and unresolved items.
- Guards: `stop_hook_active` plus a record file already on disk. Claude Code also limits such continuations to eight.
- SessionEnd: the hard refusal path kills the session with an API error and emits no Stop event. Only SessionEnd fires then. The hook writes the record itself from the transcript tail. No in-window digest is possible because the process is gone. Set `RH_NOTIFY=1` for an opt-in macOS notification that names the file.
- SessionStart: the hook injects an informational pointer into a new session's context. The pointer lists records newer than 30 days, newest first, three maximum. It never directs a successor to read or delete records. An earlier directive version made a fresh session anchor on an old refusal as a verdict on a new task.
- Records live in `.refusal-handoffs/` inside the project. Claude Code marks paths under `.claude/` as sensitive and rejects the model Write there.

### OpenCode

- The `http.response` session hook parses native Anthropic and OpenAI-compatible traffic (layer 1). WebSocket transports never reach it.
- The `session.text.ended` event fires for every provider and every transport. It runs the anchored text layer (layer 2).
- Both share a 30-second per-session cooldown. The handoff prompt runs at the next turn boundary and writes `HANDOFF.md` in the project root. Set `RH_DEBUG=1` for plugin diagnostics in `/tmp/rh-debug.log`.

## Operator notes

- Claude records land in `<project>/.refusal-handoffs/<session_id>.md`. OpenCode writes `HANDOFF.md` in the project root.
- Each record names the session transcript. A successor in any harness can rebuild full context from it.
- Old records do not steer new sessions. The SessionStart pointer is informational. The operator decides record deletion.
- Headless `claude -p` runs need `--allowedTools Write` or `--permission-mode acceptEdits` for the model-written record. Interactive sessions ask once.

## Tests

```sh
bash test/claude-hook-test.sh                               # 37/37 offline hook cases, all three events
bun test/detector-test.ts                                   # 5/5 parser + anchored text layer
test/e2e-mock.sh                                            # OpenCode pipeline vs a local refusing mock, 4/4
RH_TEST_MODEL=openai/gpt-5.6-sol-fast test/e2e-live.sh      # live OpenAI run, nondeterministic
```

All green as of 2026-10-19 on Claude Code 2.1.303 (macOS). Live checks that day covered three cases. A benign session left neither output nor a record. A hard cyber-flag refusal killed the session, and the SessionEnd hook produced a record with all six sections. A soft refusal produced a model-written record plus the operator digest with no loop.

## Uninstall

- Claude: restore `settings.json` from the backup, or delete only this hook's entries with jq. Remove unwanted `.refusal-handoffs/` folders in projects afterwards.
- OpenCode: remove the plugin path from `.plugins`. Then run `opencode service restart`.

## Caveats

- Anthropic tags benign security work as `cyber` too. A cyber-flagged stop always produces a record here. That flag alone does not prove a hard refusal.
- Claude Code transcripts can lag the final turn. The text layer on `last_assistant_message` covers that gap.
- Refusal phrase lists drift across model versions. Revisit the phrase list if detection rates drop.
