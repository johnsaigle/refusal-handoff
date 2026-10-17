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

Wire a `Stop` hook (exec form, absolute path) into `~/.claude/settings.json`:

```sh
REPO=<absolute path to this directory>
cp ~/.claude/settings.json ~/.claude/settings.json.refusal-handoff-backup
jq --arg cmd "$REPO/claude/hooks/refusal-handoff.sh" \
  '.hooks.Stop = ((.hooks.Stop // [])
    | (if any(.[]; .hooks[]?.command == $cmd) then .
       else . + [ { hooks: [ { type: "command", command: $cmd, args: [], timeout: 15 } ] } ] end))' \
  ~/.claude/settings.json > /tmp/rh-settings.new && mv /tmp/rh-settings.new ~/.claude/settings.json
chmod +x "$REPO/claude/hooks/refusal-handoff.sh"
```

The merge is idempotent (safe to re-run; existing wired entries are kept).
The hook needs no config: it reads the Stop event JSON on stdin, checks two
deterministic layers (structured provider markers in the transcript tail,
lead-anchored refusal phrasing in `last_assistant_message`), and on a hit
returns `{decision: "block", reason}` so the same Claude writes
`$CLAUDE_PROJECT_DIR/.claude/handoffs/<session_id>.md`.

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
bun "$REPO/test/detector-test.ts"   # 5/5 — parser + anchored text layers
bash -n "$REPO/claude/hooks/refusal-handoff.sh"
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

## Uninstall

- Claude: remove the `Stop` entry with
  `jq 'del(.hooks.Stop)' ~/.claude/settings.json` (or restore the backup) and
  delete `.claude/handoffs/` if unwanted.
- OpenCode: remove the plugin path from `.plugins` and restart the service.
