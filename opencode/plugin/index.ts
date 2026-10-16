// refusal-handoff — OpenCode V2 plugin
//
// Watches native provider HTTP responses (primary agent-loop calls only) for
// deterministic refusal markers and, on a hit, prompts the SAME session to
// write a handoff file for a successor model.
//
// Markers (no model calls, pure string match on the raw wire body):
//   Anthropic : "stop_reason":"refusal"  /  stop_details {type:"refusal"}  /  "category":"cyber"
//   OpenAI    : message.refusal non-null  /  content part {type:"refusal"}
//
// Notes:
// - Structured fields only populate when the provider's safety classifier
//   intervenes. Soft in-text refusals are invisible here by design (the
//   Claude Code variant of this project covers those with a text regex).
// - Response bodies are one-shot streams: we clone() and read the clone in
//   the background so token streaming to the UI is never delayed.
// - Plain object export (no "@opencode/plugin" import) so this loads from any
//   path without a package.json / node_modules.

const COOLDOWN_MS = 30_000

// Per-session dedupe so a quoted marker string in the handoff-writing turn
// (or a retry) can't loop the trigger.
const lastTrigger = new Map<string, number>()

const REFUSAL_MARKERS = new RegExp(
  [
    '"stop_reason"\\s*:\\s*"refusal"', // Anthropic hard refusal
    '"stop_details"\\s*:\\s*\\{[^}]*"refusal"', // Anthropic structured refusal block
    '"category"\\s*:\\s*"cyber"', // Anthropic cyber policy category
    '"type"\\s*:\\s*"refusal"', // OpenAI refusal content part
    '"refusal"\\s*:\\s*"', // OpenAI message.refusal (string value; `null` never matches)
  ].join("|"),
)

const HANDOFF_INSTRUCTION = `Your previous response was refused by a safety classifier. Before anything else, use the write tool to create a complete handoff file at HANDOFF.md in the current project root, containing these sections:

1. TASK - a neutral summary of what the user originally asked for.
2. COMPLETED - every step that was completed before the refusal.
3. STOPPED AT - exactly where things stopped: quote your refused message and the last successful tool call before it.
4. REASON - why the request was refused (quote the refusal notice if you have it).
5. NEXT STEPS - concrete, actionable instructions a successor model would need to continue.

After writing the file, reply with only the file path and stop. Do not attempt the refused task yourself.`

export default {
  id: "refusal-handoff",
  async setup(ctx: any) {
    const registration = await ctx.session.hook("http.response", (event: any) => {
      // Only the agent loop; skip compaction, title, and transient generate calls.
      if (event.kind !== "primary") return
      if (!event.response?.body) return

      const sessionID: string = event.sessionID
      const now = Date.now()
      if (now - (lastTrigger.get(sessionID) ?? 0) < COOLDOWN_MS) return

      // Tap the stream without blocking delivery of the response.
      void event.response
        .clone()
        .text()
        .then((body: string) => {
          if (!REFUSAL_MARKERS.test(body)) return
          lastTrigger.set(sessionID, Date.now())
          // Fire-and-forget: do NOT await inside the hook (the current turn is
          // still finalizing). Prompting the same session queues the handoff
          // turn with the same model.
          void ctx.session
            .prompt({ sessionID, text: HANDOFF_INSTRUCTION })
            .catch((err: unknown) =>
              console.error("[refusal-handoff] failed to prompt session:", err),
            )
        })
        .catch(() => {
          /* stream teardown / aborted requests: nothing to detect */
        })
    })

    return () => registration.dispose()
  },
}
