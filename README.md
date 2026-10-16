# refusal-handoff

Deterministic refusal detection for Claude Code and OpenCode. When the model's
response is refused by a provider safety classifier (or matches canonical
refusal phrasing), the **same session** is instructed to write a handoff file:
task summary, completed steps, exactly where it stopped, why, and next steps
for a successor model. No extra model calls anywhere — pure string matching.

## Layout

```
claude/
  hooks/refusal-handoff.sh   Stop hook (installed in ~/.claude/settings.json)
  settings-snippet.json      Reference snippet of the wiring
opencode/
  plugin/index.ts            V2 plugin (installed in ~/.config/opencode/opencode.json)
```

## Detection layers

1. **Structured provider markers** (zero false positives) — verified against
   current API docs:
   - **Anthropic**: response `stop_details: {type: "refusal", category:
     "cyber"|...}` and/or `stop_reason: "refusal"`. Gotcha: a refusal
     `stop_details` block can appear while `stop_reason` is still
     `"end_turn"` — always match on `stop_details`.
   - **OpenAI**: Chat Completions `message.refusal` (string, non-null),
     refusal content part `{type: "refusal"}`.
   - These only populate when the provider's **safety classifier intervenes**.
2. **Canonical refusal phrasing** (text regex, deterministic) — catches soft
   in-text refusals the classifiers didn't flag. High-precision verb list in
   `refusal-handoff.sh` (layer 2); "I can't find/provide X" style false
   positives are deliberately excluded. Tune that list there.

## Same-session handoff trigger

- **Claude Code**: the `Stop` hook returns
  `{decision: "block", reason: "..."}`. The reason is fed back to the same
  Claude as its next instruction: write the handoff file with the Write tool,
  then stop. Handoff lands at
  `$CLAUDE_PROJECT_DIR/.claude/handoffs/<session_id>.md`.
- **OpenCode**: the plugin's `http.response` hook (primary agent-loop calls
  only) taps the response body via `clone()` without blocking streaming, and
  on a match fires `ctx.session.prompt(...)` into the same session. Handoff
  lands at `HANDOFF.md` in the project root.

Both are idempotent and loop-guarded:

- Claude: `stop_hook_active` check + handoff-file-exists check (Claude Code
  also caps stop-hook continuations at 8).
- OpenCode: 30s per-session cooldown; the marker check runs on model response
  bodies only, and the handoff-writing turn is a normal response.

## Install status

Wired on 2026-10-16 (backups: `~/.claude/settings.json.refusal-handoff-backup`,
`~/.config/opencode/opencode.json.refusal-handoff-backup`):

- `~/.claude/settings.json` → `hooks.Stop` → `claude/hooks/refusal-handoff.sh`
  (exec form, absolute path). Takes effect on the next `claude` session.
- `~/.config/opencode/opencode.json` → `"plugins":
  ["/home/psychopomp/coding/refusal-handoff/opencode/plugin"]`. Requires
  OpenCode V2; takes effect after `opencode service restart` (not restarted
  automatically to avoid killing a live session).

## Testing

Hook script (six scenarios, all passing):

```sh
H=~/coding/refusal-handoff/claude/hooks/refusal-handoff.sh
printf '%s' '{"session_id":"t","stop_hook_active":false,"last_assistant_message":"I can'"'"'t help with that request.","transcript_path":""}' \
  | CLAUDE_PROJECT_DIR=/tmp/opencode/rhtest $H   # -> {"decision":"block",...}
```

Plugin regex: 10/10 marker cases (5 match / 5 non-match) verified with
`bun` against the exact construction in `plugin/index.ts`.

## Caveats

- Anthropic's `"category":"cyber"` also fires on **benign cybersecurity
  work** — intended here (any cyber-flagged stop gets a handoff), but it is
  not proof of a "real" refusal.
- Claude Code transcript lag: the docs warn `transcript_path` may not include
  the final turn's messages at Stop time; whether `stop_details` is persisted
  to the JSONL at all should be confirmed on your version. Layer 2 (text
  regex on `last_assistant_message`) covers the miss.
- OpenCode plugin assumes the current V2 hook shapes (`http.response` with
  `event.kind === "primary"`, `ctx.session.prompt`). If an OpenCode update
  changes the plugin API, check
  https://opencode.ai/v2/docs/build/plugins.
- Refusal phrasings drift across model versions — revisit the layer-2 list if
  detection rates drop.
