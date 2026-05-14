import { log } from "./log"
import { TAU_FINAL_BEGIN, TAU_FINAL_END } from "./prompt"

export interface Message {
  role: "system" | "user" | "assistant"
  content: string
}

export interface LLMConfig {
  apiUrl: string
  apiKey: string
  model: string
  temperature?: number
  maxTokens?: number
  topP?: number
}

export interface OpenCodeConfig {
  command?: string
  model?: string
  agent?: string
  dir?: string
  files?: string[]
  extraArgs?: string[]
}

const TIMEOUT_MS = Number(process.env.TAU_TIMEOUT_MS) || 60_000

async function fetchSSE(
  messages: Message[],
  config: LLMConfig
): Promise<{ response: Response; timer: ReturnType<typeof setTimeout> }> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS)

  let response: Response
  try {
    response = await fetch(`${config.apiUrl}/chat/completions`, {
      method: "POST",
      signal: controller.signal,
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${config.apiKey}`,
      },
      body: JSON.stringify({
        model: config.model,
        messages,
        stream: true,
        ...(config.temperature !== undefined && { temperature: config.temperature }),
        ...(config.maxTokens !== undefined && { max_tokens: config.maxTokens }),
        ...(config.topP !== undefined && { top_p: config.topP }),
      }),
    })
  } catch (err) {
    clearTimeout(timer)
    if (err instanceof DOMException && err.name === "AbortError") {
      throw new Error(`LLM request timed out after ${TIMEOUT_MS}ms`)
    }
    throw err
  }

  if (!response.ok) {
    clearTimeout(timer)
    const body = await response.text()
    const truncated = body.length > 200 ? body.slice(0, 200) + "..." : body
    throw new Error(`LLM request failed (${response.status}): ${truncated}`)
  }

  if (!response.body) {
    clearTimeout(timer)
    throw new Error("No response body")
  }

  return { response, timer }
}

function parseSSELines(
  lines: string[],
  onContent: (s: string) => void
): boolean {
  for (const line of lines) {
    const trimmed = line.trim()
    if (!trimmed.startsWith("data:")) continue

    const data = trimmed.slice(5).trim()
    if (data === "[DONE]") return true

    try {
      const parsed = JSON.parse(data)
      const content = parsed?.choices?.[0]?.delta?.content
      if (typeof content === "string" && content.length > 0) {
        onContent(content)
      }
    } catch {
      log(`malformed SSE chunk: ${data}`)
    }
  }
  return false
}

/** Non-generator streaming — for CLI use. */
export async function streamDirect(
  messages: Message[],
  config: LLMConfig,
  write: (s: string) => void
): Promise<void> {
  const { response, timer } = await fetchSSE(messages, config)

  const reader = response.body!.getReader()
  const decoder = new TextDecoder()
  let lineBuffer = ""

  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) {
        log("reader done=true")
        break
      }

      lineBuffer += decoder.decode(value, { stream: true })
      const lines = lineBuffer.split("\n")
      lineBuffer = lines.pop() ?? ""

      if (parseSSELines(lines, write)) {
        log("[DONE] detected, returning")
        return
      }
    }

    // Flush any remaining buffered lines
    if (lineBuffer.trim()) {
      parseSSELines(lineBuffer.split("\n"), write)
    }
    log("loop exited naturally")
  } finally {
    clearTimeout(timer)
    await reader.cancel()
  }
}

function messagesToPrompt(messages: Message[]): string {
  return messages
    .map((message) => {
      const label = message.role === "system" ? "System" : message.role === "user" ? "User" : "Assistant"
      return `[${label}]\n${message.content}`
    })
    .join("\n\n")
}

function sanitizeOpenCodeArgs(args: string[] = []): string[] {
  const sanitized: string[] = []
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]
    if (arg === "--thinking") continue
    if (arg === "--format") {
      i++
      continue
    }
    if (arg.startsWith("--format=")) continue
    sanitized.push(arg)
  }
  return sanitized
}

function parseOpenCodeJsonLine(line: string): string | undefined {
  const trimmed = line.trim()
  if (!trimmed) return undefined

  let event: any
  try {
    event = JSON.parse(trimmed)
  } catch {
    log(`malformed opencode JSONL: ${trimmed}`)
    return undefined
  }

  if (event?.type === "error") {
    const message = event?.error?.data?.message ?? event?.error?.message ?? event?.error?.name ?? "unknown opencode error"
    throw new Error(`opencode error: ${message}`)
  }

  if (event?.type !== "text") return undefined

  const text = event?.part?.text
  return typeof text === "string" ? text : undefined
}

function fallbackStripOpenCodeThinking(text: string): string {
  const lines = text.split("\n")
  const headingIdx = lines.findIndex((line) => /^#{1,6}\s+\S/.test(line))
  if (headingIdx > 0) return lines.slice(headingIdx).join("\n")

  let firstContent = -1
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (
      line.startsWith("Thinking:") ||
      line.startsWith("**Thinking") ||
      line.startsWith("I need ") ||
      line.startsWith("I should ") ||
      line.startsWith("I'll ") ||
      line.startsWith("I’m ") ||
      line.startsWith("I'm ")
    ) {
      continue
    }
    if (line.trim() === "") continue
    firstContent = i
    break
  }
  return firstContent === -1 ? text : lines.slice(firstContent).join("\n")
}

function extractOpenCodeFinalText(text: string): string {
  const begin = text.indexOf(TAU_FINAL_BEGIN)
  if (begin !== -1) {
    const contentStart = begin + TAU_FINAL_BEGIN.length
    const end = text.indexOf(TAU_FINAL_END, contentStart)
    const extracted = end === -1 ? text.slice(contentStart) : text.slice(contentStart, end)
    return extracted.trim()
  }
  return fallbackStripOpenCodeThinking(text).trim()
}

/** Stream through opencode's non-interactive CLI. */
export async function streamOpenCode(
  messages: Message[],
  config: OpenCodeConfig,
  write: (s: string) => void
): Promise<void> {
  const prompt = messagesToPrompt(messages)
  const cmd = config.command ?? "opencode"
  const args = ["run", prompt]

  if (config.model) args.push("--model", config.model)
  if (config.agent) args.push("--agent", config.agent)
  if (config.dir) args.push("--dir", config.dir)
  for (const file of config.files ?? []) {
    args.push("--file", file)
  }
  args.push(...sanitizeOpenCodeArgs(config.extraArgs))
  args.push("--format", "json")

  const proc = Bun.spawn([cmd, ...args], {
    stdout: "pipe",
    stderr: "pipe",
  })

  const decoder = new TextDecoder()
  let stderr = ""
  let lineBuffer = ""
  let textBuffer = ""
  let timedOut = false
  const timer = setTimeout(() => {
    timedOut = true
    proc.kill()
  }, TIMEOUT_MS)

  async function readStdout() {
    const reader = proc.stdout.getReader()
    try {
      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        lineBuffer += decoder.decode(value, { stream: true })
        const lines = lineBuffer.split("\n")
        lineBuffer = lines.pop() ?? ""
        for (const line of lines) {
          const text = parseOpenCodeJsonLine(line)
          if (text) textBuffer += text
        }
      }
      if (lineBuffer.trim()) {
        const text = parseOpenCodeJsonLine(lineBuffer)
        if (text) textBuffer += text
        lineBuffer = ""
      }
    } finally {
      reader.releaseLock()
    }
  }

  async function readStderr() {
    const reader = proc.stderr.getReader()
    try {
      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        stderr += decoder.decode(value, { stream: true })
      }
    } finally {
      reader.releaseLock()
    }
  }

  try {
    await Promise.all([readStdout(), readStderr()])
    const code = await proc.exited
    if (timedOut) {
      throw new Error(`opencode request timed out after ${TIMEOUT_MS}ms`)
    }
    if (code !== 0) {
      const trimmed = stderr.trim()
      throw new Error(`opencode exited with code ${code}${trimmed ? `: ${trimmed}` : ""}`)
    }
    write(extractOpenCodeFinalText(textBuffer))
  } finally {
    clearTimeout(timer)
  }
}

/** Generator streaming — for tests and programmatic use. */
export async function* stream(
  messages: Message[],
  config: LLMConfig
): AsyncGenerator<string> {
  const { response, timer } = await fetchSSE(messages, config)

  const reader = response.body!.getReader()
  const decoder = new TextDecoder()
  let lineBuffer = ""

  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break

      lineBuffer += decoder.decode(value, { stream: true })
      const lines = lineBuffer.split("\n")
      lineBuffer = lines.pop() ?? ""

      const collected: string[] = []
      if (parseSSELines(lines, (s) => collected.push(s))) {
        for (const s of collected) yield s
        return
      }
      for (const s of collected) yield s
    }

    // Flush any remaining buffered lines
    if (lineBuffer.trim()) {
      const collected: string[] = []
      parseSSELines(lineBuffer.split("\n"), (s) => collected.push(s))
      for (const s of collected) yield s
    }
  } finally {
    clearTimeout(timer)
    await reader.cancel()
  }
}
