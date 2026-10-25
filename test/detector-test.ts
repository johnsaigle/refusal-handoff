// Detector test for the refusal-handoff plugin's inspectBody.
// Corpus strings are built via concatenation so this file (which gets echoed
// into agent transcripts) never contains raw trigger literals.
import { readFileSync } from "node:fs"
import {
  _inspectBody as inspectBody,
  _TEXT_REFUSAL as TEXT_REFUSAL,
  _POLICY_FLAG as POLICY_FLAG,
} from "../opencode/plugin/index.ts"

const APOS = String.fromCharCode(8217) // ’
const detect = (body: string) => {
  const { structured, textStart } = inspectBody(body)
  if (structured) return true
  const lead = TEXT_REFUSAL.exec(textStart)
  return !!(lead && lead.index <= 30)
}

// --- corpus A: the meta-discussion content that caused BOTH self-triggers ---
// (quoted JSON example + regex sources embedded in prose; the exact shape the
//  old raw-grep plugin matched on)
const quotedJsonExample =
  '{ "role": "assistant", "content": "...", ' +
  '"refusal"' +
  ': ' +
  '"I' + APOS + 'm sorry, I cannot assist with that request." }'
const corpusA = `## Detection layers

The structured marker for OpenAI looks like this on the wire:

\`\`\`json
${quotedJsonExample}
\`\`\`

And the layer-2 regex is \`I (can't|cannot|can not) (help|assist) (with|you)\` —
note the regex source contains phrases but should never be *matched as prose*.
Discussion: models sometimes write refusal phrasings mid-message when quoting
policies, e.g. a handoff file quoting "the assistant said: I
${APOS}m sorry, but I can't help with that request." — mid-text, not at start.
`

// --- corpus B: real structured refusal (OpenAI streaming delta) ---
const corpusB =
  'data: {"id":"c1","choices":[{"index":0,"delta":{"role":"assistant","content":null,' +
  '"refusal"' +
  ': ' +
  '"I' + APOS + 'm sorry, but I can' + APOS + 't help with that request."},"finish_reason":null}]}'

// --- corpus C: real soft refusal — plain text starting with the phrasing ---
const corpusC =
  'data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"I' +
  APOS +
  'm sorry, but I can' + APOS + 't help create or conceal a keylogger."},"finish_reason":null}]}'

// --- corpus D: benign ---
const corpusD =
  'data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"I found the bug and fixed it."},"finish_reason":null}]}'

// --- corpus E: refusal phrasing MID-text (must not match: anchored layer) ---
const corpusE =
  'data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"Recall that a refusal typically begins, I can' + APOS + 't help with that request, and ends with alternatives."},"finish_reason":null}]}'

// --- corpus F: policy-flag ERROR terminating a stream (real gpt-6.1-sol
//     cyber_policy case: legit prose streamed, then the API error event) ---
const corpusF =
  'data: {"type":"error","error":{"message":"This content was ' +
  'flagged for possible cybersecurity' +
  ' risk.","type":"invalid_request","param":null,' +
  '"code":"cyber' +
  '_policy"},"status":400,"sequence_number":54}'

// --- corpus G: benign provider error (must NOT trigger) ---
const corpusG =
  'data: {"type":"error","error":{"message":"Incorrect API key provided.","type":"invalid_request","param":null,"code":"invalid_api_key"},"status":401}'

// --- corpus H: opencode session.error-shaped payload (Layer 3 fields) ---
const sessionErrorCyber = {
  type: "session.error",
  data: {
    sessionID: "ses_test",
    error: {
      type: "provider.invalid-request",
      message: "cyber" + "_policy: This content was " + "flagged for possible cybersecurity" + " risk.",
    },
  },
}
const sessionErrorBenign = {
  type: "session.error",
  data: {
    sessionID: "ses_test",
    error: { type: "provider.rate-limited", message: "Rate limit exceeded. Try again in 20 seconds." },
  },
}

let fail = 0
const expect = (label: string, got: boolean, want: boolean) => {
  if (got !== want) fail++
  console.log(`${got === want ? "ok  " : "FAIL"} ${label}: got ${got}, want ${want}`)
}

expect("A meta-discussion quotes (no trigger)", detect(corpusA), false)
expect("B structured refusal delta (trigger)", detect(corpusB), true)
expect("C soft refusal at text start (trigger)", detect(corpusC), true)
expect("D benign (no trigger)", detect(corpusD), false)
expect("E refusal phrasing mid-text (no trigger)", detect(corpusE), false)
expect("F policy-flag error event (trigger)", detect(corpusF), true)
expect("G benign provider error (no trigger)", detect(corpusG), false)
expect(
  "H session.error policy-flag message (Layer 3 regex)",
  POLICY_FLAG.test(sessionErrorCyber.data.error.message),
  true,
)
expect(
  "H session.error benign message (Layer 3 regex)",
  POLICY_FLAG.test(sessionErrorBenign.data.error.message),
  false,
)

console.log(fail === 0 ? "ALL PASS" : `FAILURES: ${fail}`)
process.exit(fail === 0 ? 0 : 1)
