# tau.nvim

A minimal Neovim plugin for applying LLM edits to a visual selection or range.

Tau sends your instruction, selected code, nearby context, and optional context files to an OpenAI-compatible `/chat/completions` API, then streams the proposed edit back into Neovim for review.

<img width="4108" height="2392" alt="image" src="https://github.com/user-attachments/assets/83c013fc-b5d3-46bf-ad74-ea5b6f2f2632" />

## Install

Requirements: Neovim 0.10+, [Bun](https://bun.sh), and an OpenAI-compatible API endpoint.

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "timothyckl/tau.nvim",
  lazy = false,
  build = "cd cli && bun run build",
  config = function()
    require("tau").setup({
      api_url = "https://api.openai.com/v1", -- Tau appends /chat/completions
      api_key = vim.env.OPENAI_API_KEY,
      model = "gpt-4o",
    })
  end,
  keys = {
    { "<leader>t", ":Tau<CR>", mode = "v", desc = "Tau: edit selection" },
    { "<leader>ta", ":TauAsk<CR>", mode = "n", desc = "Tau: ask about file" },
    { "<leader>tv", ":TauVibe<CR>", mode = "n", desc = "Tau: vibe with opencode" },
    { "<C-t>", ":TauContext<CR>", mode = "n", desc = "Tau: context files" },
  },
}
```

Using `vim.pack`:

`tau.nvim` requires [Bun](https://bun.sh) to build the CLI binary at `cli/tau`.
The plugin is not usable until that build has completed, because `:Tau`,
`:TauAsk`, `:TauContext`, and `:TauCancel` all rely on the compiled CLI being
present.

Minimal install:

```lua
vim.pack.add({
  {
    src = "https://github.com/timothyckl/tau.nvim"
  },
})
```

Complete example with automatic rebuilds on install and update:

```lua
-- Define this before vim.pack.add() so fresh installs also build cli/tau.
vim.api.nvim_create_autocmd("PackChanged", {
  callback = function(ev)
    local data = ev.data
    if data.spec.name ~= "tau.nvim" then
      return
    end
    if data.kind ~= "install" and data.kind ~= "update" then
      return
    end

    local result = vim.system({ "bun", "run", "build" }, {
      cwd = data.path .. "/cli",
      text = true,
    }):wait()

    if result.code ~= 0 then
      local output = vim.trim(
        (result.stderr and result.stderr ~= "") and result.stderr or (result.stdout or "")
      )
      if output == "" then
        output = ("bun run build exited with code %d"):format(result.code)
      end
      vim.notify(
        ("tau.nvim: failed to build cli/tau\n%s"):format(output),
        vim.log.levels.ERROR
      )
    end
  end,
})

vim.pack.add({
  { src = "https://github.com/timothyckl/tau.nvim" },
})

require("tau").setup({
  api_url = "https://api.openai.com/v1", -- Tau appends /chat/completions
  api_key = vim.env.OPENAI_API_KEY,
  model = "gpt-4o",
})

vim.keymap.set("v", "<leader>t", ":Tau<CR>", { desc = "Tau: edit selection" })
vim.keymap.set("n", "<leader>ta", ":TauAsk<CR>", { desc = "Tau: ask about file" })
vim.keymap.set("n", "<leader>tv", ":TauVibe<CR>", { desc = "Tau: vibe with opencode" })
vim.keymap.set("n", "<C-t>", ":TauContext<CR>", { desc = "Tau: context files" })
vim.keymap.set("n", "<leader>T", ":TauCancel<CR>", { desc = "Tau: cancel request" })
```

The `PackChanged` hook rebuilds `cli/tau` after every install and update, and
`vim.system(...):wait()` keeps the build synchronous so the CLI is present
before first use.

If you hit `ENOENT: no such file or directory ... /cli/tau`, the CLI was not
built yet. Rebuild it manually with:

```sh
cd <plugin>/cli && bun run build
```

For Ollama-compatible local servers:

```lua
require("tau").setup({
  connector = "api",
  api_url = "http://localhost:11434/v1",
  api_key = "ollama",
  model = "qwen2.5-coder:7b",
})
```

To use [opencode](https://opencode.ai/) instead of the OpenAI-compatible API
connector:

```lua
require("tau").setup({
  connector = "opencode",

  -- optional
  opencode_model = "anthropic/claude-sonnet-4-5",
  opencode_agent = "build",
  opencode_args = {},
})
```

Tau runs `opencode run` with the active file and selected context files attached
via `--file` and parses `--format json` output so only the final assistant text
is shown in Tau. The opencode prompt uses internal `TAU_FINAL_BEGIN` /
`TAU_FINAL_END` markers to discard thinking text before rendering. Ask mode can
use opencode's project context and tools, while edit mode still asks opencode to
return replacement text for Tau's review UI.

## Usage

Select code in visual mode, then run:

```vim
:Tau rewrite this to be simpler
```

Or run `:Tau` without an instruction to open the instruction picker. While reviewing a streamed proposal:

| Key | Action |
| --- | --- |
| `<CR>` | Accept edit |
| `<Esc>` | Reject edit |
| `r` | Regenerate edit |

Tau automatically includes nearby lines from the active file. To add more files as context, press `<C-t>` in the instruction picker or run `:TauContext`.

To ask a question without editing the buffer, run:

```vim
:TauAsk what does this file do?
```

Ask mode sends the active buffer as context, includes any selected context files, and opens the answer in a scratch split.

To run opencode in the background and get notified when it finishes, run:

```vim
:TauVibe update the tests for this change
```

Vibe mode always uses opencode, sends the active buffer and selected context files, and reports completion with a small bottom-right toast that wraps, auto-closes, and does not take focus.

In the context picker:

| Key / Symbol | Meaning |
| --- | --- |
| `<Space>` | Toggle file under cursor |
| `<Esc>` / `q` | Close picker |
| `◎` | Active file, always included |
| `●` | Selected context file |

Selected context files persist for the current Neovim session.

## Configuration

```lua
require("tau").setup({
  connector = "api",
  api_url = "https://api.openai.com/v1",
  api_key = vim.env.OPENAI_API_KEY,
  model = "gpt-4o",

  -- optional
  context_lines = 30,
  timeout_ms = 60000,
  context_window = 128000,
  temperature = 0.2,
  max_tokens = 4096,
  top_p = 1,
  opencode_command = "opencode",
  opencode_model = "anthropic/claude-sonnet-4-5",
  opencode_agent = "build",
  opencode_dir = vim.fn.getcwd(),
  opencode_args = {},
  debug = false,
  keys = { context = "<C-t>" },
})
```

| Option | Default | Description |
| --- | --- | --- |
| `connector` | `"api"` | Connector to use: `"api"` or `"opencode"` |
| `api_url` | required for `api` | OpenAI-compatible API base URL |
| `api_key` | required for `api` | API key; prefer environment variables |
| `model` | `gpt-4o` | Model name |
| `context_lines` | `30` | Lines above and below the selection to include |
| `timeout_ms` | `60000` | Request timeout in milliseconds |
| `context_window` | unset | Model context window, used for token estimates |
| `temperature` | unset | Sampling temperature, `0` to `2` |
| `max_tokens` | unset | Maximum response tokens |
| `top_p` | unset | Nucleus sampling value, `0` to `1` |
| `opencode_command` | `"opencode"` | opencode executable to run when `connector = "opencode"` |
| `opencode_model` | unset | opencode model in `provider/model` format |
| `opencode_agent` | unset | opencode agent to use |
| `opencode_dir` | current working directory at setup | Directory passed to `opencode run --dir` |
| `opencode_args` | `{}` | Extra arguments passed to `opencode run`; Tau controls `--format` and suppresses `--thinking` |
| `debug` | `false` | Write diagnostics to `~/.local/state/tau/diag.log` |
| `keys.context` | `<C-t>` | Open context picker from the instruction picker |

Commands: `:Tau [instruction]`, `:TauAsk [question]`, `:TauVibe [prompt]`, `:TauCancel`, `:TauContext`.

## License

MIT
