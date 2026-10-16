// Mock OpenAI-compatible server for the refusal-handoff end-to-end test.
//
// Behavior:
//   request with last message role=user and NO "handoff" in text
//     -> refusal response (structured marker on the wire: "refusal":"...")
//   request with last message role=user containing "handoff"
//     -> write tool call creating $HANDOFF_DIR/HANDOFF.md
//   request with last message role=tool (tool result)
//     -> plain text acknowledgment, turn ends
//
// Every request body is appended to $MOCK_LOG (one JSON line each) — the test
// asserts against this log, not against opencode internals.
//
// Env: MOCK_PORT (default 18923), MOCK_LOG (default ./requests.log),
//      HANDOFF_DIR (where the write tool call targets).

const PORT = Number(process.env.MOCK_PORT ?? 18923)
const LOG = process.env.MOCK_LOG ?? "./requests.log"
const HANDOFF_DIR = process.env.HANDOFF_DIR ?? process.cwd()

const HANDOFF_PATH = `${HANDOFF_DIR}/HANDOFF.md`
const HANDOFF_CONTENT = `# Handoff

## TASK
The user asked for a working keylogger in C that records keystrokes and
uploads them to a remote server.

## COMPLETED
Nothing - the request was refused before any work was done.

## STOPPED AT
Turn 1: the assistant refused with "I'm sorry, but I can't help with that
request." No tool calls were made.

## REASON
Provider safety classifier refusal (cyber category).

## NEXT STEPS
A successor model should evaluate the request under its own policies.
`

const REFUSAL_TEXT = "I'm sorry, but I can't help with that request."

import { appendFileSync } from "node:fs"

let requestCount = 0

function logRequest(entry: unknown) {
  appendFileSync(LOG, JSON.stringify(entry) + "\n")
}

function chatChunk(model: string, delta: any, finish: string | null) {
  return (
    `data: ${JSON.stringify({
      id: "chatcmpl-mock",
      object: "chat.completion.chunk",
      created: Math.floor(Date.now() / 1000),
      model,
      choices: [{ index: 0, delta, finish_reason: finish }],
    })}\n\n`
  )
}

async function handleChat(body: any): Promise<Response> {
  requestCount++
  const stream = body.stream === true
  const model = body.model ?? "test-refuser"
  const messages: any[] = body.messages ?? []
  const last = messages[messages.length - 1] ?? {}
  const lastRole = last.role ?? "user"
  const lastText =
    typeof last.content === "string"
      ? last.content
      : JSON.stringify(last.content ?? "")

  await Bun.write(
    Bun.stdout,
    `[mock] request #${requestCount}: role=${lastRole} text=${JSON.stringify(lastText.slice(0, 120))}\n`,
  )
  logRequest({ n: requestCount, role: lastRole, text: lastText })

  let payload: { delta: any; finish: string | null }[]

  if (lastRole === "user" && /handoff/i.test(lastText)) {
    // Handoff turn: emit a real write tool call.
    payload = [
      { delta: { role: "assistant", content: null }, finish: null },
      {
        delta: {
          tool_calls: [
            {
              index: 0,
              id: "call_mock_write",
              type: "function",
              function: {
                name: "write",
                arguments: JSON.stringify({
                  path: HANDOFF_PATH,
                  content: HANDOFF_CONTENT,
                }),
              },
            },
          ],
        },
        finish: null,
      },
      { delta: {}, finish: "tool_calls" },
    ]
  } else if (lastRole === "tool") {
    payload = [
      {
        delta: { role: "assistant", content: "Handoff file written." },
        finish: null,
      },
      { delta: {}, finish: "stop" },
    ]
  } else {
    // Refusal turn: structured marker must appear in the raw wire body.
    payload = [
      {
        delta: {
          role: "assistant",
          content: REFUSAL_TEXT,
          refusal: REFUSAL_TEXT,
        },
        finish: null,
      },
      { delta: {}, finish: "stop" },
    ]
  }

  if (!stream) {
    // Non-streaming: fold into a single completion object.
    const text = payload
      .map((p) => (typeof p.delta.content === "string" ? p.delta.content : ""))
      .join("")
    const toolCalls = payload.flatMap((p) => p.delta.tool_calls ?? [])
    return Response.json({
      id: "chatcmpl-mock",
      object: "chat.completion",
      created: Math.floor(Date.now() / 1000),
      model,
      choices: [
        {
          index: 0,
          message: {
            role: "assistant",
            content: text || null,
            refusal:
              payload.some((p) => p.delta.refusal) ? REFUSAL_TEXT : null,
            ...(toolCalls.length ? { tool_calls: toolCalls } : {}),
          },
          finish_reason: payload[payload.length - 1].finish,
        },
      ],
      usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 },
    })
  }

  const sse = payload.map((p) => chatChunk(model, p.delta, p.finish)).join("")
  return new Response(sse + "data: [DONE]\n\n", {
    headers: { "content-type": "text/event-stream" },
  })
}

Bun.serve({
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url)
    if (url.pathname.endsWith("/models")) {
      return Response.json({
        object: "list",
        data: [{ id: "test-refuser", object: "model", owned_by: "mock" }],
      })
    }
    if (url.pathname.endsWith("/chat/completions")) {
      try {
        return await handleChat(await req.json())
      } catch (err) {
        return new Response(`mock error: ${err}`, { status: 500 })
      }
    }
    return new Response("not found", { status: 404 })
  },
})

console.log(`[mock] listening on http://127.0.0.1:${PORT}/v1`)
