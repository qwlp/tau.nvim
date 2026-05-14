import { describe, test, expect } from "bun:test"
import { stream, streamOpenCode } from "../src/llm"
import { mkdtempSync, writeFileSync, chmodSync, rmSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"

function sseChunks(tokens: string[]): string {
  return (
    tokens
      .map((t) => `data: ${JSON.stringify({ choices: [{ delta: { content: t } }] })}`)
      .join("\n") +
    "\ndata: [DONE]\n"
  )
}

async function collectStream(
  tokens: string[],
  splitAt?: number // split the SSE payload at this byte offset to simulate chunk boundaries
): Promise<string> {
  const payload = sseChunks(tokens)

  const server = Bun.serve({
    port: 0,
    fetch() {
      if (splitAt !== undefined) {
        // Stream in two chunks split at splitAt to test boundary handling
        const encoder = new TextEncoder()
        const bytes = encoder.encode(payload)
        const part1 = bytes.slice(0, splitAt)
        const part2 = bytes.slice(splitAt)
        const body = new ReadableStream({
          start(controller) {
            controller.enqueue(part1)
            controller.enqueue(part2)
            controller.close()
          },
        })
        return new Response(body, {
          headers: { "Content-Type": "text/event-stream" },
        })
      }
      return new Response(payload, {
        headers: { "Content-Type": "text/event-stream" },
      })
    },
  })

  const url = `http://localhost:${server.port}`
  let result = ""
  try {
    for await (const token of stream(
      [{ role: "user", content: "test" }],
      { apiUrl: url, apiKey: "test", model: "test-model" }
    )) {
      result += token
    }
  } finally {
    server.stop()
  }
  return result
}

describe("stream", () => {
  test("collects tokens from SSE response", async () => {
    const result = await collectStream(["async ", "def ", "foo():"])
    expect(result).toBe("async def foo():")
  })

  test("handles chunk boundary mid-event", async () => {
    // Split the SSE payload mid-way through the first event line
    const result = await collectStream(["hello ", "world"], 20)
    expect(result).toBe("hello world")
  })

  test("handles single-token response", async () => {
    const result = await collectStream(["done"])
    expect(result).toBe("done")
  })

  test("throws on non-200 response", async () => {
    const server = Bun.serve({
      port: 0,
      fetch() {
        return new Response("internal error", { status: 500 })
      },
    })

    const url = `http://localhost:${server.port}`
    let threw = false
    try {
      for await (const _ of stream(
        [{ role: "user", content: "test" }],
        { apiUrl: url, apiKey: "test", model: "test-model" }
      )) {
        // should not reach here
      }
    } catch (err) {
      threw = true
      expect(String(err)).toContain("500")
    } finally {
      server.stop()
    }
    expect(threw).toBe(true)
  })
})

describe("streamOpenCode", () => {
  test("streams stdout from an opencode-compatible command", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tau-opencode-test-"))
    const script = join(dir, "fake-opencode")
    writeFileSync(script, [
      "#!/bin/sh",
      "printf '%s\\n' '{\"type\":\"step_start\",\"part\":{\"type\":\"step-start\"}}'",
      "printf '%s\\n' '{\"type\":\"tool_use\",\"part\":{\"type\":\"tool\",\"state\":{\"output\":\"ignored\"}}}'",
      "printf '%s\\n' '{\"type\":\"text\",\"part\":{\"type\":\"text\",\"text\":\"Thinking: ignored\\nTAU_FINAL_BEGIN\\nanswer from \"}}'",
      "printf '%s\\n' '{\"type\":\"text\",\"part\":{\"type\":\"text\",\"text\":\"opencode\\nTAU_FINAL_END\"}}'",
      "",
    ].join("\n"))
    chmodSync(script, 0o755)

    let result = ""
    try {
      await streamOpenCode(
        [{ role: "user", content: "test" }],
        { command: script },
        (token) => { result += token }
      )
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }

    expect(result).toBe("answer from opencode")
  })

  test("strips leading thinking text when final markers are missing", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tau-opencode-test-"))
    const script = join(dir, "fake-opencode")
    writeFileSync(script, [
      "#!/bin/sh",
      "printf '%s\\n' '{\"type\":\"text\",\"part\":{\"type\":\"text\",\"text\":\"Thinking: **Crafting**\\n\\nI need to explain this.\\n## Summary\\nFinal answer\"}}'",
      "",
    ].join("\n"))
    chmodSync(script, 0o755)

    let result = ""
    try {
      await streamOpenCode(
        [{ role: "user", content: "test" }],
        { command: script },
        (token) => { result += token }
      )
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }

    expect(result).toBe("## Summary\nFinal answer")
  })

  test("forces JSON format and removes thinking flag", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tau-opencode-test-"))
    const script = join(dir, "fake-opencode")
    const argsFile = join(dir, "args.txt")
    writeFileSync(script, [
      "#!/bin/sh",
      `printf '%s\\n' "$*" > '${argsFile}'`,
      "printf '%s\\n' '{\"type\":\"text\",\"part\":{\"type\":\"text\",\"text\":\"TAU_FINAL_BEGIN\\nok\\nTAU_FINAL_END\"}}'",
      "",
    ].join("\n"))
    chmodSync(script, 0o755)

    try {
      await streamOpenCode(
        [{ role: "user", content: "test" }],
        { command: script, extraArgs: ["--thinking", "--format", "default"] },
        () => {}
      )
      const proc = Bun.spawnSync(["cat", argsFile])
      const args = new TextDecoder().decode(proc.stdout)
      expect(args).not.toContain("--thinking")
      expect(args).not.toContain("default")
      expect(args).toContain("--format json")
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test("throws when opencode command fails", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tau-opencode-test-"))
    const script = join(dir, "fake-opencode")
    writeFileSync(script, "#!/bin/sh\nprintf 'bad config' >&2\nexit 7\n")
    chmodSync(script, 0o755)

    let threw = false
    try {
      await streamOpenCode(
        [{ role: "user", content: "test" }],
        { command: script },
        () => {}
      )
    } catch (err) {
      threw = true
      expect(String(err)).toContain("code 7")
      expect(String(err)).toContain("bad config")
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }

    expect(threw).toBe(true)
  })
})
