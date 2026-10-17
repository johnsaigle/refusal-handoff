// refusal-handoff — OpenCode V2 plugin
//
// When the model's response is a refusal, prompts the SAME session to write a
// handoff file for a successor model. No model calls — deterministic only.
//
// Two detection layers, two transports:
//
// Layer 1 (structured, zero false positives) — http.response hook, HTTP-native
//   providers only (Anthropic, openai-compatible). Parses the wire payload
//   (SSE or plain JSON) and matches refusal at FIELD level:
//   - Anthropic: stop_reason "refusal" / stop_details {type:"refusal"} / refusal block
//   - OpenAI chat: message.refusal / refusal content part / finish_reason "content_filter"
//   - OpenAI Responses API: refusal content parts / response.refusal.* events
//   Field-level parsing is what prevents self-triggering on prose that merely
//   quotes these markers (that really happened — hence the parser).
//   NOTE: transports that bypass native HTTP (e.g. Codex over WebSocket) never
//   reach this hook — that is what the event layer is for.
//
// Layer 2 (lead-anchored text match) — ctx.event.subscribe(), fires for EVERY
//   provider transport. On session.text.ended, test the START of the assistant
//   text for canonical refusal phrasings. Refusals lead with the phrase;
//   discussion of refusals mentions it mid-text and must not match.
//   (This layer caught the real gpt-5.6 case: refusal in plain text with
//   message.refusal === null.)
//
// Both layers share a per-session cooldown. Response bodies are one-shot
// streams: clone() and read in the background so streaming is never delayed.

const COOLDOWN_MS = 30_000
// Layer 2 only fires when the refusal phrasing begins the assistant text.
const MAX_LEAD_CHARS = 30
const TEXT_ANCHOR_CHARS = 400

// Per-session dedupe so a retry can't loop the trigger.
const lastTrigger = new Map<string, number>()

const normalizeApostrophes = (s: string) => s.replace(/[\u2018\u2019]/g, "'")

// Layer 2 list — same as the Claude Code hook in this repo. Keep high-precision.
const TEXT_REFUSAL =
  /I (can't|cannot|can not) (help|assist)(?!\s+but)\b|I'm unable to (help|assist)|I am unable to (help|assist)|I won't be able to (help|assist)|I must decline|I can't comply|I cannot comply|conflicts with .{0,40}Usage Policy|request was declined/i

// The handoff prompt is a function of sessionID so the SESSION DATA section
// can name the exact on-disk locations of this session's full context
// (issue #1): message parts live one JSON file per message, and the session
// metadata JSON sits in a project-hash directory under storage/session/.
const handoffInstruction = (sessionID: string) => `Your previous response was refused by a safety classifier. Before anything else, use the write tool to create a complete handoff file at HANDOFF.md in the current project root, containing these sections:

1. TASK - a neutral summary of what the user originally asked for.
2. COMPLETED - every step that was completed before the refusal.
3. STOPPED AT - exactly where things stopped: quote your refused message and the last successful tool call before it.
4. REASON - why the request was refused (quote the refusal notice if you have it).
5. NEXT STEPS - concrete, actionable instructions a successor model would need to continue.
6. SESSION DATA - where to recover the full conversation context for this session:
   - Messages: ~/.local/share/opencode/storage/message/${sessionID}/ (one JSON file per message)
   - Session metadata: ~/.local/share/opencode/storage/session/*/${sessionID}.json
   A successor can read those files directly to reconstruct the complete context beyond this summary.

After writing the file, reply with only the file path and stop. Do not attempt the refused task yourself.`

// Debug goes to a file: opencode captures/routes plugin console output, so
// stderr is not reliable. Set RH_DEBUG=1 and read /tmp/rh-debug.log.
import { appendFileSync } from "node:fs"

function debug(...args: unknown[]) {
  if (!process.env.RH_DEBUG) return
  try {
    appendFileSync("/tmp/rh-debug.log", args.map(String).join(" ") + "\n")
  } catch {
    /* ignore */
  }
}

interface InspectResult {
  structured: boolean
  textStart: string
}

// Parse the wire body — plain JSON or SSE — and inspect payloads at field level.
// Anything that fails JSON.parse (prose, markdown, logs) is ignored entirely.
function inspectBody(body: string): InspectResult {
  let structured = false
  const texts: string[] = []

  const lines = body.split("\n")
  const chunks = lines.some((l) => l.startsWith("data:"))
    ? lines.filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trim())
    : [body]

  for (const chunk of chunks) {
    if (!chunk || chunk === "[DONE]") continue
    let obj: any
    try {
      obj = JSON.parse(chunk)
    } catch {
      continue
    }

    // --- Anthropic (non-streaming message + message_delta events) ---
    if (obj.stop_reason === "refusal" || obj.delta?.stop_reason === "refusal")
      structured = true
    const stopDetails = obj.stop_details ?? obj.delta?.stop_details
    if (stopDetails?.type === "refusal") structured = true

    const blocks = Array.isArray(obj.content) ? obj.content : []
    if (blocks.some((b: any) => b?.type === "refusal")) structured = true
    for (const b of blocks) if (typeof b?.text === "string") texts.push(b.text)
    // Anthropic streaming: content_block_delta carries delta.text
    if (typeof obj.delta?.text === "string") texts.push(obj.delta.text)

    // --- OpenAI Responses API (non-streaming output[], events, item/part done) ---
    const outputItems = [
      ...(Array.isArray(obj.output) ? obj.output : []),
      ...(Array.isArray(obj.response?.output) ? obj.response.output : []),
      ...(obj.item ? [obj.item] : []),
      ...(obj.part ? [obj.part] : []),
    ]
    for (const item of outputItems) {
      const parts = Array.isArray(item?.content) ? item.content : [item]
      for (const p of parts) {
        if (p?.type === "refusal") structured = true
        if (p?.type === "output_text" && typeof p.text === "string")
          texts.push(p.text)
      }
    }
    // Responses API streaming: text + refusal deltas
    if (obj.type === "response.output_text.delta" && typeof obj.delta === "string")
      texts.push(obj.delta)
    if (obj.type === "response.refusal.delta" || obj.type === "response.refusal.done")
      structured = true

    // --- OpenAI chat completions (non-streaming + streaming deltas) ---
    for (const choice of Array.isArray(obj.choices) ? obj.choices : []) {
      if (choice.finish_reason === "content_filter") structured = true
      const msg = choice.message ?? choice.delta ?? {}
      if (typeof msg.refusal === "string" && msg.refusal.length > 0)
        structured = true
      const parts = Array.isArray(msg.content) ? msg.content : []
      if (parts.some((p: any) => p?.type === "refusal")) structured = true
      if (typeof msg.content === "string") texts.push(msg.content)
    }
  }

  return {
    structured,
    textStart: normalizeApostrophes(texts.join("")).slice(0, TEXT_ANCHOR_CHARS),
  }
}

function textIsRefusal(text: string): boolean {
  const lead = TEXT_REFUSAL.exec(normalizeApostrophes(text).slice(0, TEXT_ANCHOR_CHARS))
  return !!(lead && lead.index <= MAX_LEAD_CHARS)
}

// Exported for the detector test suite (test/detector-test.ts).
export const _inspectBody = inspectBody
export const _TEXT_REFUSAL = TEXT_REFUSAL

export default {
  id: "refusal-handoff",
  async setup(ctx: any) {
    const controller = new AbortController()

    const triggerHandoff = (sessionID: string, source: string) => {
      const now = Date.now()
      if (now - (lastTrigger.get(sessionID) ?? 0) < COOLDOWN_MS) return
      lastTrigger.set(sessionID, now)
      debug("[refusal-handoff] TRIGGER via", source, `session=${sessionID.slice(0, 8)}`)
      // Fire-and-forget: do NOT await (a turn is finalizing). Prompting the
      // same session queues the handoff turn at the next turn boundary.
      void ctx.session
        .prompt({ sessionID, text: handoffInstruction(sessionID) })
        .catch((err: unknown) =>
          debug("[refusal-handoff] prompt failed:", String(err)),
        )
    }

    // --- Layer 2: event stream (all provider transports) ---
    void (async () => {
      try {
        for await (const ev of ctx.event.subscribe({ signal: controller.signal })) {
          if (process.env.RH_DEBUG && ev?.type === "session.text.ended") {
            debug(
              "[refusal-handoff] text.ended:",
              JSON.stringify(ev?.data).slice(0, 200),
            )
          }
          if (ev?.type !== "session.text.ended") continue
          const sessionID: unknown = ev.data?.sessionID
          const text: unknown = ev.data?.text
          if (typeof sessionID !== "string" || typeof text !== "string" || !text)
            continue
          if (textIsRefusal(text)) triggerHandoff(sessionID, "event:text.ended")
        }
      } catch (e) {
        debug("[refusal-handoff] event subscribe ended:", String(e))
      }
    })()

    // --- Layer 1: native HTTP responses (HTTP-native providers only) ---
    const registration = await ctx.session.hook("http.response", (event: any) => {
      debug(
        "[refusal-handoff] http.response event",
        `kind=${event.kind} keys=${Object.keys(event).join(",")}`,
      )
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
          const { structured, textStart } = inspectBody(body)
          if (process.env.RH_DEBUG) {
            debug(
              "[refusal-handoff] inspect",
              `session=${String(sessionID).slice(0, 8)}`,
              `structured=${structured} textStart=${JSON.stringify(textStart.slice(0, 80))}`,
            )
          }
          if (structured) triggerHandoff(sessionID, "http:structured")
          else if (textIsRefusal(textStart))
            triggerHandoff(sessionID, "http:text")
        })
        .catch(() => {
          /* stream teardown / aborted requests: nothing to detect */
        })
    })

    return () => {
      controller.abort()
      void registration.dispose()
    }
  },
}
