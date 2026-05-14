local context = require("tau.context")
local runner = require("tau.runner")
local ui = require("tau.ui")
local history = require("tau.history")
local picker = require("tau.picker")

local M = {}

--- @type table
local config = {}

local SIGTERM  = 15
local NS_TRACK = vim.api.nvim_create_namespace("tau_track")

--- @type { handle: vim.SystemObj|nil, bufnr: integer, cancelled: boolean, prev_esc: table, mark_start: integer|nil, mark_end: integer|nil } | nil
local _job = nil

--- @type { bufnr: integer, start_line: integer, end_line: integer, new_lines: string[], instruction: string } | nil
local _pending = nil

--- True while a buf-attach listener is watching for in-region edits during pending review.
local _watching = false

--- True while the instruction picker is open, to prevent stacked invocations.
local _picking = false
local _toast_timer = nil
local _toast_win = nil

local function ensure_ready()
  if not config.connector then
    vim.api.nvim_echo({ { "tau: call require('tau').setup() first", "ErrorMsg" } }, false, {})
    return false
  end

  if _job or _picking then
    vim.api.nvim_echo({ { "tau: request already in flight — use :TauCancel first", "WarningMsg" } }, false, {})
    return false
  end

  return true
end

local function current_file(bufnr)
  local raw_name = vim.api.nvim_buf_get_name(bufnr)
  return raw_name ~= "" and vim.fn.fnamemodify(raw_name, ":p") or nil
end

local function with_instruction(bufnr, args, title, callback)
  local instruction = args and args ~= "" and args or nil
  if instruction then
    callback(instruction)
    return
  end

  _picking = true
  picker.open(history.list(), function(choice)
    _picking = false
    if not choice then return end
    callback(choice)
  end, { context_key = config.keys.context, current_file = current_file(bufnr), title = title })
end

local function close_toast()
  if _toast_timer then
    _toast_timer:stop()
    _toast_timer:close()
    _toast_timer = nil
  end
  if _toast_win and vim.api.nvim_win_is_valid(_toast_win) then
    pcall(vim.api.nvim_win_close, _toast_win, true)
  end
  _toast_win = nil
end

local function wrap_text(text, width)
  local wrapped = {}
  for raw_line in text:gmatch("([^\n]*)\n?") do
    if raw_line == "" then
      wrapped[#wrapped + 1] = ""
    else
      local line = raw_line
      while vim.fn.strdisplaywidth(line) > width do
        local cut = width
        while cut > 1 and line:sub(cut, cut) ~= " " do
          cut = cut - 1
        end
        if cut <= 1 then cut = width end
        wrapped[#wrapped + 1] = vim.trim(line:sub(1, cut))
        line = vim.trim(line:sub(cut + 1))
      end
      wrapped[#wrapped + 1] = line
    end
    if raw_line == "" and text:sub(-1) ~= "\n" then break end
  end
  if #wrapped == 0 then wrapped = { text } end
  return wrapped
end

local function toast(msg, level)
  close_toast()

  local width = math.max(28, math.min(64, math.floor(vim.o.columns * 0.36)))
  local lines = wrap_text(msg, width)
  local max_lines = math.max(2, math.min(8, vim.o.lines - 4))
  if #lines > max_lines then
    local clipped = {}
    for i = 1, max_lines do
      clipped[i] = lines[i]
    end
    clipped[max_lines] = vim.trim(clipped[max_lines]):gsub("%s*$", "") .. "..."
    lines = clipped
  end

  local max_width = 0
  for _, line in ipairs(lines) do
    max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
  end

  width = math.min(math.max(max_width, 24), math.max(24, vim.o.columns - 6))
  local height = #lines
  local row = math.max(1, vim.o.lines - height - 4)
  local col = math.max(0, vim.o.columns - width - 3)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local title = level >= vim.log.levels.ERROR and " tau error " or " tau "
  local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    border = "rounded",
    title = title,
    title_pos = "left",
    style = "minimal",
    focusable = false,
    noautocmd = true,
    zindex = 250,
  })

  if not ok then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.api.nvim_echo({ { msg, level >= vim.log.levels.ERROR and "ErrorMsg" or "Comment" } }, false, {})
    return
  end

  _toast_win = win
  _toast_timer = vim.uv.new_timer()
  _toast_timer:start(5000, 0, vim.schedule_wrap(close_toast))
end

local function status(msg, level)
  level = level or vim.log.levels.INFO
  toast(msg, level)
end

--- Clear preview UI unconditionally — safe to call even if _job is nil.
local function _clear_pending()
  if not _pending then return end
  ui.clear_preview(_pending.bufnr)
  pcall(vim.keymap.del, "n", "<CR>", { buffer = _pending.bufnr })
  pcall(vim.keymap.del, "n", "r",    { buffer = _pending.bufnr })
  _pending = nil
end

--- Read current selection boundaries from tracking extmarks.
--- Returns nil, nil if _job is absent or buffer is invalid.
--- @param bufnr integer
--- @return integer|nil, integer|nil  1-indexed start_line, end_line
local function get_tracked_range(bufnr)
  if not _job then return nil, nil end
  if not vim.api.nvim_buf_is_valid(bufnr) then return nil, nil end
  local s = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS_TRACK, _job.mark_start, {})
  local e = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS_TRACK, _job.mark_end,   {})
  if not s or #s == 0 or not e or #e == 0 then return nil, nil end
  return s[1] + 1, e[1] + 1
end

--- Tear down all in-flight state: stop UI, restore <Esc> mapping, unlock buffer.
--- @param bufnr integer
local function _cleanup(bufnr)
  -- Clear preview before the _job guard so ghost extmarks are never left behind
  -- if _job has already been set to nil (e.g. double-accept or cancel race).
  _clear_pending()
  if not _job then return end
  ui.stop()
  pcall(vim.keymap.del, "n", "<Esc>", { buffer = bufnr })
  if _job.prev_esc and _job.prev_esc.lhs and _job.prev_esc.lhs ~= "" then
    if vim.api.nvim_buf_is_valid(bufnr) then
      -- prev_esc is captured before any <Esc> mapping is installed in _execute.
      -- Do not move that capture below any vim.keymap.set call or this restore breaks.
      vim.fn.mapset("n", false, _job.prev_esc)
    end
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, NS_TRACK, 0, -1)
  end
  _watching = false
  _job = nil
end

local function _accept()
  if not _pending then return end
  local p = _pending
  -- Read extmark positions BEFORE _cleanup() clears NS_TRACK
  local cur_start, cur_end = get_tracked_range(p.bufnr)
  local final_start = cur_start or p.start_line
  local final_end   = cur_end   or p.end_line
  -- _cleanup must precede nvim_buf_set_lines: it sets _watching = false so the
  -- buf-attach watcher ignores the programmatic write and does not emit a false cancel.
  _cleanup(p.bufnr)
  if not vim.api.nvim_buf_is_valid(p.bufnr) then
    vim.api.nvim_echo({ { "tau: buffer was closed, replacement lost", "ErrorMsg" } }, false, {})
    return
  end
  local ok, err = pcall(vim.api.nvim_buf_set_lines, p.bufnr, final_start - 1, final_end, false, p.new_lines)
  if not ok then
    vim.api.nvim_echo({ { "tau: failed to apply replacement: " .. tostring(err), "ErrorMsg" } }, false, {})
  end
end

local function _reject()
  if not _pending then return end
  _cleanup(_pending.bufnr)
end

local function _regen()
  if not _pending then return end
  local p = _pending
  local cur_start, cur_end = get_tracked_range(p.bufnr)
  local final_start = cur_start or p.start_line
  local final_end   = cur_end   or p.end_line
  _cleanup(p.bufnr)
  M._execute(p.bufnr, final_start, final_end, p.instruction)
end

--- Configure the plugin. Must be called before using :Tau.
--- @param opts table { connector?: "api"|"opencode", api_url?: string, api_key?: string, model?: string, debug?: boolean, timeout_ms?: number, context_window?: number, context_lines?: number, temperature?: number, max_tokens?: number, top_p?: number, opencode_command?: string, opencode_model?: string, opencode_agent?: string, opencode_dir?: string, opencode_args?: string[], keys?: { context?: string } }
function M.setup(opts)
  vim.validate({
    connector  = { opts.connector, "string", true },
    api_url    = { opts.api_url, "string", true },
    api_key    = { opts.api_key, "string", true },
    model      = { opts.model, "string", true },
    debug      = { opts.debug, "boolean", true },
    timeout_ms      = { opts.timeout_ms, "number", true },
    context_window  = { opts.context_window, "number", true },
    context_lines   = { opts.context_lines, "number", true },
    temperature     = { opts.temperature, "number", true },
    max_tokens      = { opts.max_tokens, "number", true },
    top_p           = { opts.top_p, "number", true },
    opencode_command = { opts.opencode_command, "string", true },
    opencode_model   = { opts.opencode_model, "string", true },
    opencode_agent   = { opts.opencode_agent, "string", true },
    opencode_dir     = { opts.opencode_dir, "string", true },
    opencode_args    = { opts.opencode_args, "table", true },
    keys            = { opts.keys, "table", true },
  })
  opts.connector = opts.connector or "api"
  if opts.connector ~= "api" and opts.connector ~= "opencode" then
    error("tau: connector must be 'api' or 'opencode', got " .. opts.connector)
  end
  if opts.connector == "api" then
    if not opts.api_url or opts.api_url == "" then
      error("tau: api_url is required when connector = 'api'")
    end
    if not opts.api_key or opts.api_key == "" then
      error("tau: api_key is required when connector = 'api'")
    end
  end
  if opts.context_lines ~= nil then
    if opts.context_lines < 1 or opts.context_lines ~= math.floor(opts.context_lines) then
      error("tau: context_lines must be a positive integer, got " .. opts.context_lines)
    end
  end
  if opts.temperature ~= nil and (opts.temperature < 0 or opts.temperature > 2) then
    error("tau: temperature must be between 0 and 2, got " .. opts.temperature)
  end
  if opts.max_tokens ~= nil then
    if opts.max_tokens < 1 or opts.max_tokens ~= math.floor(opts.max_tokens) then
      error("tau: max_tokens must be a positive integer, got " .. opts.max_tokens)
    end
  end
  if opts.top_p ~= nil and (opts.top_p < 0 or opts.top_p > 1) then
    error("tau: top_p must be between 0 and 1, got " .. opts.top_p)
  end
  if opts.opencode_args ~= nil then
    for i, arg in ipairs(opts.opencode_args) do
      if type(arg) ~= "string" then
        error("tau: opencode_args[" .. i .. "] must be a string")
      end
    end
  end
  opts.context_lines = opts.context_lines or 30
  opts.opencode_dir = opts.opencode_dir or vim.fn.getcwd()
  opts.keys = vim.tbl_extend("keep", opts.keys or {}, { context = "<C-t>" })
  config = opts
end

--- Main entry point. Called from the :Tau command.
--- @param opts table vim command opts (line1, line2, args)
function M.run(opts)
  if not ensure_ready() then return end

  local bufnr = vim.api.nvim_get_current_buf()

  -- Capture selection line numbers synchronously before any async call.
  -- opts.line1/line2 are authoritative when the command is called with a range.
  -- Fall back to visual marks otherwise.
  local start_line = opts.line1 or vim.fn.line("'<")
  local end_line = opts.line2 or vim.fn.line("'>")

  if start_line == 0 or end_line == 0 then
    vim.api.nvim_echo({ { "tau: no selection", "WarningMsg" } }, false, {})
    return
  end

  with_instruction(bufnr, opts.args, " Edit ", function(instruction)
    M._execute(bufnr, start_line, end_line, instruction)
  end)
end

--- Ask a question about the active buffer or provided range without applying edits.
--- @param opts table vim command opts (line1?, line2?, range?, args)
function M.ask(opts)
  if not ensure_ready() then return end

  local bufnr = vim.api.nvim_get_current_buf()
  local has_range = opts.range and opts.range > 0
  local start_line = has_range and opts.line1 or vim.fn.line(".")
  local end_line = has_range and opts.line2 or vim.api.nvim_buf_line_count(bufnr)
  local lines = has_range
    and vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
    or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.bo[bufnr].filetype

  with_instruction(bufnr, opts.args, " Ask ", function(question)
    question = vim.trim(question or "")
    if question == "" then return end

    ui.start(bufnr, start_line)

    local accumulated = ""
    local token_meta = nil
    local prev_esc = vim.fn.maparg("<Esc>", "n", false, true)
    _job = { handle = nil, bufnr = bufnr, cancelled = false, prev_esc = prev_esc,
             mark_start = nil, mark_end = nil }

    local handle = runner.run({
      config = config,
      mode = "ask",
      instruction = question,
      selection_text = table.concat(lines, "\n"),
      filepath = filepath,
      filetype = filetype,
      context_files = require("tau.context_files").get(),

      on_meta = function(meta)
        token_meta = meta
        ui.update_meta(meta)
        if meta.warning then
          vim.api.nvim_echo({ { "tau: " .. meta.warning, "WarningMsg" } }, false, {})
        end
      end,

      on_token = function(chunk)
        accumulated = accumulated .. chunk
        vim.schedule(function()
          ui.update_progress(#accumulated)
        end)
      end,

      on_done = function()
        if not _job then return end
        if _job.cancelled then
          _cleanup(bufnr)
          return
        end
        history.add(question)
        _cleanup(bufnr)
        ui.show_answer(question, accumulated, token_meta)
      end,

      on_error = function(msg)
        if not _job then return end
        local was_cancelled = _job.cancelled
        _cleanup(bufnr)
        if was_cancelled then return end
        local ok, err = pcall(function()
          ui.error(bufnr, start_line, msg)
        end)
        if not ok then
          vim.api.nvim_echo({ { "tau: " .. tostring(err), "ErrorMsg" } }, false, {})
        end
      end,
    })

    _job.handle = handle

    vim.keymap.set("n", "<Esc>", function()
      require("tau").cancel()
    end, { buffer = bufnr, noremap = true, silent = true, desc = "tau: cancel request" })
  end)
end

--- Run an opencode prompt in the background and notify on completion.
--- @param opts table vim command opts (line1?, line2?, range?, args)
function M.vibe(opts)
  if not ensure_ready() then return end

  local bufnr = vim.api.nvim_get_current_buf()
  local has_range = opts.range and opts.range > 0
  local start_line = has_range and opts.line1 or 1
  local end_line = has_range and opts.line2 or vim.api.nvim_buf_line_count(bufnr)

  with_instruction(bufnr, opts.args, " Vibe ", function(prompt)
    prompt = vim.trim(prompt or "")
    if prompt == "" then return end

    local filepath = vim.api.nvim_buf_get_name(bufnr)
    local filetype = vim.bo[bufnr].filetype
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
    local start_ms = vim.uv.now()
    local accumulated = ""
    local prev_esc = vim.fn.maparg("<Esc>", "n", false, true)
    local vibe_config = vim.tbl_extend("force", config, { connector = "opencode" })

    _job = { handle = nil, bufnr = bufnr, cancelled = false, prev_esc = prev_esc,
             mark_start = nil, mark_end = nil }

    status("tau: vibe started", vim.log.levels.INFO)

    local handle = runner.run({
      config = vibe_config,
      mode = "vibe",
      instruction = prompt,
      selection_text = table.concat(lines, "\n"),
      filepath = filepath,
      filetype = filetype,
      context_files = require("tau.context_files").get(),

      on_meta = function(meta)
        if meta.warning then
          vim.api.nvim_echo({ { "tau: " .. meta.warning, "WarningMsg" } }, false, {})
        end
      end,

      on_token = function(chunk)
        accumulated = accumulated .. chunk
      end,

      on_done = function()
        if not _job then return end
        if _job.cancelled then
          _cleanup(bufnr)
          return
        end
        history.add(prompt)
        _cleanup(bufnr)
        local elapsed = math.floor((vim.uv.now() - start_ms) / 1000)
        local detail = vim.trim(accumulated):gsub("\n+", " ")
        if #detail > 120 then
          detail = detail:sub(1, 117) .. "..."
        end
        local msg = ("tau: vibe done in %ds"):format(elapsed)
        if detail ~= "" then
          msg = msg .. " - " .. detail
        end
        status(msg, vim.log.levels.INFO)
      end,

      on_error = function(msg)
        if not _job then return end
        local was_cancelled = _job.cancelled
        _cleanup(bufnr)
        if was_cancelled then return end
        status("tau: vibe failed - " .. msg:gsub("\n+", " "), vim.log.levels.ERROR)
      end,
    })

    _job.handle = handle

    vim.keymap.set("n", "<Esc>", function()
      require("tau").cancel()
    end, { buffer = bufnr, noremap = true, silent = true, desc = "tau: cancel request" })
  end)
end

--- Internal: execute the LLM replacement after instruction is known.
--- @param bufnr integer
--- @param start_line integer 1-indexed
--- @param end_line integer 1-indexed
--- @param instruction string
function M._execute(bufnr, start_line, end_line, instruction)
  if _job then
    vim.api.nvim_echo({ { "tau: request already in flight", "WarningMsg" } }, false, {})
    return
  end

  local ctx = context.get(bufnr, start_line, end_line, config.context_lines)

  -- Place tracking extmarks to follow selection boundaries as user edits outside the region
  local mark_start = vim.api.nvim_buf_set_extmark(bufnr, NS_TRACK, start_line - 1, 0, {
    right_gravity = false,
  })
  local mark_end = vim.api.nvim_buf_set_extmark(bufnr, NS_TRACK, end_line - 1, 0, {
    right_gravity = true,
  })

  -- Start UI: spinner
  ui.start(bufnr, start_line)

  local accumulated = ""
  local token_meta = nil

  -- Pre-assign _job so callbacks always see a non-nil sentinel even if the
  -- process exits before vim.system returns on this tick. handle is filled in
  -- below after runner.run() returns.
  local prev_esc = vim.fn.maparg("<Esc>", "n", false, true)
  _job = { handle = nil, bufnr = bufnr, cancelled = false, prev_esc = prev_esc,
           mark_start = mark_start, mark_end = mark_end }

  local handle = runner.run({
    config = config,
    instruction = instruction,
    selection_text = ctx.selection.text,
    context_above = ctx.above,
    context_below = ctx.below,
    filepath = ctx.filepath,
    filetype = ctx.filetype,
    context_files = require("tau.context_files").get(),

    on_meta = function(meta)
      token_meta = meta
      ui.update_meta(meta)
      if meta.warning then
        vim.api.nvim_echo({ { "tau: " .. meta.warning, "WarningMsg" } }, false, {})
      end
    end,

    on_token = function(chunk)
      accumulated = accumulated .. chunk
      vim.schedule(function()
        ui.update_progress(#accumulated)
      end)
    end,

    on_done = function()
      if not _job then return end
      if _job.cancelled then
        _cleanup(bufnr)
        return
      end

      history.add(instruction)

      -- Stop spinner; defer full cleanup until accept/reject
      ui.stop()

      local ok, err = pcall(function()
        -- Strip markdown code fences the model may wrap output in
        local text = accumulated:gsub("^%s*```[%w]*%s*\n", ""):gsub("\n%s*```%s*$", "")
        -- Remove only trailing whitespace, preserve leading indentation
        text = text:gsub("%s+$", "")

        local new_lines = vim.split(text, "\n", { plain = true })

        local cur_start, cur_end = get_tracked_range(bufnr)
        local final_start = cur_start or start_line
        local final_end   = cur_end   or end_line

        _pending = { bufnr = bufnr, start_line = final_start, end_line = final_end, new_lines = new_lines, instruction = instruction }

        -- Close over stable mark IDs so the callback has no dependency on _job,
        -- which may be nil if _cleanup races with a scheduled on_lines delivery.
        local watch_mark_start = _job.mark_start
        local watch_mark_end   = _job.mark_end
        _watching = vim.api.nvim_buf_attach(bufnr, false, {
          on_lines = function(_, _, _, firstline, lastline)
            if not _watching then return true end  -- detach
            local s = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS_TRACK, watch_mark_start, {})
            local e = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS_TRACK, watch_mark_end,   {})
            if not s or #s == 0 or not e or #e == 0 then return true end
            -- extmark rows are 0-indexed; convert to half-open [sel_start, sel_end) to match on_lines ranges
            local sel_start = s[1]
            local sel_end   = e[1] + 1  -- mark_end sits on last selected row; +1 makes upper bound exclusive
            -- [firstline, lastline) ∩ [sel_start, sel_end) ≠ ∅  ↔  firstline < sel_end and lastline > sel_start
            if firstline < sel_end and lastline > sel_start then
              vim.schedule(function()
                if not _pending then return end
                _cleanup(bufnr)
                vim.api.nvim_echo(
                  { { "tau: selection modified — review cancelled", "WarningMsg" } },
                  false, {}
                )
              end)
              return true  -- detach
            end
          end,
        })

        ui.show_preview(bufnr, final_start, final_end, new_lines, instruction, token_meta)

        -- <Esc> now rejects instead of cancels; <CR> accepts
        vim.keymap.set("n", "<Esc>", _reject,
          { buffer = bufnr, noremap = true, silent = true, desc = "tau: reject replacement" })
        vim.keymap.set("n", "<CR>", _accept,
          { buffer = bufnr, noremap = true, silent = true, desc = "tau: accept replacement" })
        vim.keymap.set("n", "r", _regen,
          { buffer = bufnr, noremap = true, silent = true, desc = "tau: regen replacement" })
      end)
      if not ok then
        _cleanup(bufnr)
        vim.api.nvim_echo({ { "tau: " .. tostring(err), "ErrorMsg" } }, false, {})
      end
    end,

    on_error = function(msg)
      if not _job then return end
      local was_cancelled = _job.cancelled
      _cleanup(bufnr)

      if was_cancelled then return end

      local ok, err = pcall(function()
        ui.error(bufnr, start_line, msg)
      end)
      if not ok then
        vim.api.nvim_echo({ { "tau: " .. tostring(err), "ErrorMsg" } }, false, {})
      end
    end,
  })

  _job.handle = handle

  vim.keymap.set("n", "<Esc>", function()
    require("tau").cancel()
  end, { buffer = bufnr, noremap = true, silent = true, desc = "tau: cancel request" })
end

--- Cancel the in-flight request, if any.
function M.cancel()
  if not _job then
    vim.api.nvim_echo({ { "tau: no request in flight", "Comment" } }, false, {})
    return
  end

  local j = _job
  j.cancelled = true          -- set before kill so the exit callback sees it
  if j.handle then
    j.handle:kill(SIGTERM)    -- process may exit 0 or non-zero; cancelled flag handles both
  end
  _cleanup(j.bufnr)           -- immediate UI teardown; don't wait for the callback

  vim.api.nvim_echo({ { "tau: cancelled", "Comment" } }, false, {})
end

return M
