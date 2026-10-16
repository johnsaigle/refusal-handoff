# refusal-handoff

Fixed-rule refusal detection for Claude Code and OpenCode.

When a provider safety classifier refuses the model output, that session writes a handoff file. The file records the original task and the completed work. It also names the exact point of interruption. It gives the refusal cause and the next steps for a successor model. The detector matches fixed text only and adds no model calls.

## Layout

```
claude/
  hooks/refusal-handoff.sh   Stop hook (installed in ~/.claude/settings.json)
  settings-snippet.json      Reference snippet of the wiring
opencode/
  plugin/index.ts            V2 plugin (installed in ~/.config/opencode/opencode.json)
test/
  detector-test.ts           Unit test for the parser and the text layer
  mock-server.ts             OpenAI-compatible mock that always refuses
  e2e-mock.sh                Tier 1: deterministic end-to-end test via the mock
  e2e-live.sh                Tier 2: real OpenAI run (nondeterministic)
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

## Claude Code trigger

The `Stop` hook returns a block decision with an instruction. Claude Code feeds that instruction to the same Claude as its next prompt. The instruction names the handoff path: `$CLAUDE_PROJECT_DIR/.claude/handoffs/<session_id>.md`. Loop guards check `stop_hook_active` and the handoff file. Claude Code also limits stop-hook continuations to eight.

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

Install elsewhere with `SKILL.md`. Copy this repo to the target machine and hand the skill to your agent. The skill wires both harnesses, verifies the result, and uninstalls cleanly.

## Tests

```
bun test/detector-test.ts          # 5/5: parser and anchored text layers
test/e2e-mock.sh                   # Tier 1: 4/4 deterministic pipeline
RH_TEST_MODEL=openai/gpt-5.6-sol-fast test/e2e-live.sh
RH_DEBUG=1                         # plugin debug output -> /tmp/rh-debug.log
```

Results from 2026-10-16:

- Detector: five of five cases pass.
- Tier 1: the plugin handoff turn follows the mock refusal turn inside one `opencode run`. The write tool creates `HANDOFF.md` through a real tool call.
- Tier 2: gpt-5.6-sol-fast refused live. The event layer detected the refusal and the handoff file gained all five sections.

## Caveats

- Anthropic reports the `cyber` category for benign security work too. Every cyber-flagged stop gets a handoff here. We intend that behavior, and it still does not prove a hard refusal.
- Claude Code transcripts can lag the final turn. The text layer on `last_assistant_message` covers that gap.
- Refusal phrases drift across model versions. Revisit the phrase list if detection rates drop.
