---
name: refusal-handoff
description: Install, update, verify, or remove the refusal-handoff integration for Claude Code and/or OpenCode. USE WHEN the user wants automatic refusal detection with same-session handoff file generation in either harness, asks to wire this repo into their setup, or reports that the handoff did or did not trigger.
---

# refusal-handoff installer

Deterministic refusal detection for Claude Code and OpenCode. When a model
response is refused by a provider safety classifier (or leads with canonical
refusal phrasing), the **same session** is instructed to write a handoff file:
task summary, completed steps, exactly where it stopped, why, next steps
for a successor model, and the on-disk location of the session's full
transcript so a successor can recover complete context. No extra model
calls — pure string matching.

**All paths below are relative to the directory containing this SKILL.md**
(the cloned repo). Resolve it first and use absolute paths everywhere.

## Prerequisites

- `jq` on PATH (Claude hook + config merging)
- `bun` on PATH (plugin runtime dependency is none, but tests need it)
- Claude Code CLI and/or OpenCode **v2** (plugin API is V2-only)

Ask the user which harnesses to install into if they did not say. The two
steps below are independent — one can fail without affecting the other.

## 1. Claude Code

Wire a `Stop` hook (exec form, absolute path) into `~/.claude/settings.json`.
Wire the SAME script under `SessionEnd` and `SessionStart` too:

- `SessionEnd` is the only event that fires when a hard refusal kills the
  session (see below).
- `SessionStart` is the successor-pickup path: its stdout lands in a new
  session's context. The hook injects a short informational pointer to
  records newer than 30 days (newest first, max 3). The pointer never
  directs the successor to read a record or delete it — an earlier probe
  with "read any record relevant ... before answering" made the model
  anchor on an old refusal and treat it as a verdict on a fresh request,
  then delete the record (seen live 2026-10-19). The pointer now states
  that records describe past sessions only and deletion is the operator's
  call.

```sh
REPO=<absolute path to this directory>
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

The merge is idempotent (safe to re-run; existing wired entries are kept).
The hook needs no config. Both events run the same two deterministic layers
(structured provider markers in the transcript tail, lead-anchored refusal
phrasing in the final assistant message):

- **Stop**: on a hit, returns `{decision: "block", reason}` so the same Claude
  writes `$CLAUDE_PROJECT_DIR/.refusal-handoffs/<session_id>.md` and then
  prints a short OPERATOR DIGEST in the session window (task, why the turn
  ended, handoff-file path, transcript path, what remains unresolved) before
  stopping. The record is framed as a session-state document, not a
  continuation plan: asking for successor "next steps" made the model argue
  that it was being told to route around its own refusal (seen live 2026-10-19).
- **SessionEnd**: covers the fatal path where Stop never fires. When Anthropic
  safeguards flag a turn and no fallback model recovers it, Claude Code exits
  with an API-error message and emits NO Stop event (verified live); only
  `SessionEnd` fires. The hook then writes the handoff file itself,
  deterministically, from the transcript tail. File exists → skips, so the
  two events never double-write. In-window output is impossible on this path
  (the process is gone); set `RH_NOTIFY=1` for an opt-in macOS notification
  naming the handoff file.

**Handoff path is `.refusal-handoffs/`, NOT `.claude/handoffs/`:** Claude
Code's sensitive-file protection blocks the model's Write tool inside
`.claude/` (verified live — the model replied "couldn't write the handoff
file ... marked as a sensitive file" and produced nothing). Maintaining the
model-written summary requires the write to be outside `.claude/`. In
headless `claude -p` runs also pass `--allowedTools Write` (or run
interactively and approve the one prompt).

New sessions pick it up automatically; verify with the test below.

## 2. OpenCode (V2 only)

Add the plugin directory to the global config:

```sh
REPO=<absolute path to this directory>
cp ~/.config/opencode/opencode.json ~/.config/opencode/opencode.json.refusal-handoff-backup
jq --arg p "$REPO/opencode/plugin" \
  '.plugins = ((.plugins // []) | (if index($p) then . else . + [$p] end))' \
  ~/.config/opencode/opencode.json > /tmp/rh-oc.new && mv /tmp/rh-oc.new ~/.config/opencode/opencode.json
```

The plugin (`opencode/plugin/index.ts`) self-loads from that path — no
package.json needed. Then **restart the background service**; config and
plugin files are read at startup:

```sh
opencode service restart && opencode service status
```

Two detection transports are wired inside the plugin:

- `http.response` session hook (Anthropic, openai-compatible): parses native
  payloads at field level — Anthropic `stop_details`/`stop_reason`,
  OpenAI `message.refusal`, refusal content parts, `finish_reason:
  "content_filter"`, Responses-API `response.refusal.*` events.
- `ctx.event.subscribe()` → `session.text.ended`: fires for **every**
  provider transport, including WebSocket-backed ones (e.g. a Codex/ChatGPT
  `openai` provider, which never reaches the HTTP hook). Applies the
  lead-anchored phrase layer.

On detection it prompts the same session to write `HANDOFF.md` in the project
root; the prompt executes at the next turn boundary.

## Verify

```sh
bash "$REPO/test/claude-hook-test.sh"  # hook layers for both events, offline
bash -n "$REPO/claude/hooks/refusal-handoff.sh"
bun "$REPO/test/detector-test.ts"   # 5/5 — parser + anchored text layers
printf '%s' '{"session_id":"smoke","stop_hook_active":false,"last_assistant_message":"I found the bug and fixed it.","transcript_path":""}' \
  | CLAUDE_PROJECT_DIR=/tmp/rh-smoke "$REPO/claude/hooks/refusal-handoff.sh"
# expect: no output, exit 0 (benign turn must stay silent)
```

Optional full pipeline (spawns a real `opencode run` against a local mock
that always refuses; asserts the handoff turn and `HANDOFF.md`):

```sh
"$REPO/test/e2e-mock.sh"
```

Live check against a real OpenAI subscription (nondeterministic — the model
must actually refuse; use a supported model for the account):

```sh
RH_TEST_MODEL=openai/gpt-5.6-sol-fast "$REPO/test/e2e-live.sh"
```

For plugin diagnostics set `RH_DEBUG=1` and read `/tmp/rh-debug.log`.

## Tuning and gotchas

- The phrase list lives in two places that must stay in sync:
  `claude/hooks/refusal-handoff.sh` (layer 2) and
  `opencode/plugin/index.ts` (`TEXT_REFUSAL`). Keep the lead-anchor rule
  (match must start within the first 30 chars) — it is what prevents the
  detector firing on text that merely *quotes* refusals.
- Anthropic `"category":"cyber"` also fires on benign cybersecurity work —
  intentional here.
- Claude Code transcripts may lag the final turn; the text layer on
  `last_assistant_message` covers that.
- If the OpenCode handoff prompt appears with no actual refusal, the loaded
  plugin may be stale — restart the service.
- SessionEnd fires for every session exit. The hook only acts when the
  transcript tail carries an unhandled refusal marker AND no handoff file
  exists yet, so benign exits are silent.

## Uninstall

- Claude: remove both entries with
  `jq '.hooks |= del(.Stop, .SessionEnd)' ~/.claude/settings.json` (or
  restore the backup) and delete `.refusal-handoffs/` dirs in projects if
  unwanted.
- OpenCode: remove the plugin path from `.plugins` and restart the service.
