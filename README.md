# refusal-handoff

Deterministic refusal detection for Claude Code and OpenCode. When the model's
response is refused by a provider safety classifier (or leads with canonical
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
test/
  detector-test.ts           Unit test: parser + text layers (bun)
  mock-server.ts             OpenAI-compatible mock that always refuses
  e2e-mock.sh                Tier 1: deterministic end-to-end via the mock
  e2e-live.sh                Tier 2: real OpenAI run (nondeterministic)
```

## Detection layers

1. **Structured provider markers** (zero false positives) — verified against
   current API docs; matched at *field level* on parsed payloads, never by
   raw-body grep:
   - **Anthropic**: `stop_details: {type: "refusal", category: "cyber"|...}`,
     `stop_reason: "refusal"`. Gotcha: a refusal `stop_details` block can
     appear while `stop_reason` is still `"end_turn"` — match `stop_details`.
   - **OpenAI chat**: `message.refusal` (non-empty string), refusal content
     part, `finish_reason: "content_filter"`.
   - **OpenAI Responses API**: refusal content parts,
     `response.refusal.delta`/`.done` events.
   These only populate when the provider's **safety classifier intervenes**.
2. **Lead-anchored refusal phrasing** (deterministic text match) — catches
   soft refusals the classifiers don't flag (`message.refusal === null`).
   Refusals *lead* with the phrase, so the match must start within the first
   30 chars of the assistant text; mid-text mentions of refusal phrasings
   (and quoted examples — see "self-trigger" below) never match. Typographic
   apostrophes (U+2019) are normalized first — models emit them constantly.

## Transports (OpenCode)

- **`http.response` session hook** — sees native provider HTTP traffic
  (Anthropic, openai-compatible). Layer 1 lives here. **WebSocket-backed
  transports never reach it** (documented limitation); e.g. a
  Codex/ChatGPT-account `openai` provider only surfaces `kind: "title"`.
- **`ctx.event.subscribe()` → `session.text.ended`** — server-side assistant
  text events; fire for every provider regardless of transport. Layer 2 lives
  here. This is the path that catches Codex-transport refusals (verified live
  with `openai/gpt-5.6-sol-fast`).

Both layers share a 30s per-session cooldown and fire-and-forget the handoff
prompt (`ctx.session.prompt`) into the same session; it executes at the next
turn boundary.

## Same-session handoff trigger (Claude Code)

The `Stop` hook returns `{decision: "block", reason: "..."}`; the reason is
fed back to the same Claude as its next instruction: write the handoff file
with the Write tool, then stop. Lands at
`$CLAUDE_PROJECT_DIR/.claude/handoffs/<session_id>.md`. Loop-guarded by
`stop_hook_active` + handoff-file-exists (Claude Code caps stop-hook
continuations at 8).

## The self-trigger lesson

While developing this, the plugin repeatedly fired on its own author's
messages: an agent that *discusses* refusal detection (quoting wire formats
and phrase lists) matches naive detection. Fixes baked in:

- Field-level parsing for layer 1 (markdown/prose fails `JSON.parse` → ignored).
- Layer 2 anchored to the start of the assistant text with a 30-char lead
  threshold — mid-text quotations don't match (`test/detector-test.ts`
  corpus A/E encode the exact false-positive shapes that bit us).

If you ever see the handoff prompt appear as a user message with no actual
refusal, check the loaded plugin version is current (`opencode service restart`
picks up file changes).

## Install status

Install into a new machine/harness with [`SKILL.md`](SKILL.md) — copy this
repo to the target, hand the skill to your agent (or follow it manually), and
it wires both harnesses idempotently, verifies, and uninstalls cleanly.

Wired on this machine on 2026-10-16 (backups: `~/.claude/settings.json.refusal-handoff-backup`,
`~/.config/opencode/opencode.json.refusal-handoff-backup`):

- `~/.claude/settings.json` → `hooks.Stop` → `claude/hooks/refusal-handoff.sh`
  (exec form, absolute path).
- `~/.config/opencode/opencode.json` → `"plugins":
  ["/home/psychopomp/coding/refusal-handoff/opencode/plugin"]`.
- Restart the opencode service to load/reload the plugin.

## Tests

```sh
bun test/detector-test.ts          # 5/5: parser + anchored text layers
test/e2e-mock.sh                   # Tier 1: 4/4 deterministic pipeline
RH_TEST_MODEL=openai/gpt-5.6-sol-fast test/e2e-live.sh   # Tier 2: real run
RH_DEBUG=1                         # anywhere: plugin debug -> /tmp/rh-debug.log
```

Tier 1 (2026-10-16): the mock's refusal turn is followed in the SAME
`opencode run` by the plugin's handoff turn, and `HANDOFF.md` is written via a
real tool call. Tier 2 (2026-10-16): live refusal from gpt-5.6-sol-fast,
detected via the event layer, handoff written with TASK/COMPLETED/
STOPPED AT/REASON/NEXT STEPS.

## Caveats

- Anthropic's `"category":"cyber"` also fires on **benign cybersecurity
  work** — intended here (any cyber-flagged stop gets a handoff), but it is
  not proof of a "real" refusal.
- Claude Code transcript lag: `transcript_path` may not include the final
  turn at Stop time; whether `stop_details` persists to the JSONL is
  version-dependent. The lead-anchored text layer on `last_assistant_message`
  covers the miss.
- Refusal phrasings drift across model versions — revisit the layer-2 list
  if detection rates drop.
