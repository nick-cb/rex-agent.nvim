---Passive live editor state tracker.
---Writes the active Neovim buffer, cursor position, and visual selection to a
---per-PID JSON file so external CLI hooks (agy PreInvocation, claude UserPromptSubmit)
---always know what file and lines you are looking at.
local M = {}

local uv = vim.uv or vim.loop

local AUGROUP = "AgentBridgeState"

local internal = {
  enabled = false,
  cfg = nil,
  state_path = nil,
  timer = nil,
  last_state = nil,
  held_selection = nil,
  cursor_at_flush = nil,
  visual_entry_tick = nil,
  visual_entry_buf = nil,
}

---@param mode string
---@return boolean
local function is_visual_mode(mode)
  return mode == "v" or mode == "V" or mode == "\22"
end

---@param bufnr integer
---@param cfg table
---@return boolean
local function should_track_buffer(bufnr, cfg)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.bo[bufnr].buftype ~= "" then
    return false
  end
  local ft = vim.bo[bufnr].filetype
  if cfg and cfg.ignore_filetypes and cfg.ignore_filetypes[ft] then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name or name == "" then
    return false
  end
  return true
end

---@param abs_path string
---@param cwd string
---@return string
local function to_relative(abs_path, cwd)
  if cwd and cwd ~= "" then
    local prefix = cwd:sub(-1) == "/" and cwd or (cwd .. "/")
    if abs_path:sub(1, #prefix) == prefix then
      return abs_path:sub(#prefix + 1)
    end
  end
  return abs_path
end

---@param bufnr integer
---@param mode string
---@param max_bytes integer
---@return table|nil
local function capture_visual_selection(bufnr, mode, max_bytes)
  local anchor = vim.fn.getpos("v")
  local cursor = vim.fn.getpos(".")
  if not anchor or not cursor or anchor[2] == 0 or cursor[2] == 0 then
    return nil
  end

  local l1, c1 = anchor[2], anchor[3]
  local l2, c2 = cursor[2], cursor[3]
  if l1 > l2 or (l1 == l2 and c1 > c2) then
    l1, c1, l2, c2 = l2, c2, l1, c1
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, l1 - 1, l2, false)
  if #lines == 0 then
    return nil
  end

  if mode == "v" then
    if l1 == l2 then
      lines[1] = lines[1]:sub(c1, c2)
    else
      lines[1] = lines[1]:sub(c1)
      lines[#lines] = lines[#lines]:sub(1, c2)
    end
  end

  local text = table.concat(lines, "\n")
  if #text > max_bytes then
    return {
      startLine = l1,
      endLine = l2,
      text = nil,
      truncated = true,
    }
  end

  return {
    startLine = l1,
    endLine = l2,
    text = text,
    truncated = false,
  }
end

---@param bufnr integer
---@param max_bytes integer
---@return table|nil
local function capture_marks_selection(bufnr, max_bytes)
  local l1 = vim.fn.line("'<")
  local l2 = vim.fn.line("'>")
  if l1 <= 0 or l2 <= 0 then
    return nil
  end
  if l1 > l2 then
    l1, l2 = l2, l1
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, l1 - 1, l2, false)
  if #lines == 0 then
    return nil
  end

  local text = table.concat(lines, "\n")
  if #text > max_bytes then
    return {
      startLine = l1,
      endLine = l2,
      text = nil,
      truncated = true,
    }
  end

  return {
    startLine = l1,
    endLine = l2,
    text = text,
    truncated = false,
  }
end

---@param path string
---@param data string
local function write_atomic(path, data)
  local tmp = path .. ".tmp." .. tostring(uv.hrtime())
  local fd = uv.fs_open(tmp, "w", tonumber("600", 8))
  if not fd then
    return
  end
  local ok = pcall(function()
    uv.fs_write(fd, data, 0)
  end)
  pcall(uv.fs_close, fd)
  if ok then
    pcall(uv.fs_rename, tmp, path)
  else
    pcall(uv.fs_unlink, tmp)
  end
end

---@param bufnr integer
---@return boolean
local function cursor_unmoved_since_flush(bufnr)
  local caf = internal.cursor_at_flush
  if not caf or caf.bufnr ~= bufnr then
    return false
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  return pos[1] == caf.pos[1] and pos[2] == caf.pos[2]
end

---Capture current editor state and write it to the JSON file.
function M.flush_now()
  if not internal.enabled or not internal.state_path then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  if not should_track_buffer(bufnr, internal.cfg) then
    return
  end

  local abs_file = vim.api.nvim_buf_get_name(bufnr)
  local cwd = vim.fn.getcwd()
  local pos = vim.api.nvim_win_get_cursor(0)
  local mode = vim.fn.mode(1):sub(1, 1)
  local max_bytes = (internal.cfg and internal.cfg.max_selection_bytes) or 8192

  local selection = nil
  if is_visual_mode(mode) then
    selection = capture_visual_selection(bufnr, mode, max_bytes)
    internal.held_selection = selection
    internal.cursor_at_flush = nil
  elseif internal.held_selection and cursor_unmoved_since_flush(bufnr) then
    selection = internal.held_selection
  else
    internal.held_selection = nil
    internal.cursor_at_flush = nil
  end

  local snapshot = {
    pid = vim.fn.getpid(),
    cwd = cwd,
    file = to_relative(abs_file, cwd),
    absFile = abs_file,
    filetype = vim.bo[bufnr].filetype,
    line = pos[1],
    col = pos[2] + 1,
    selection = selection,
    updatedAt = os.time(),
  }

  internal.last_state = snapshot
  local ok, encoded = pcall(vim.json.encode, snapshot)
  if ok and encoded then
    write_atomic(internal.state_path, encoded)
  end
end

local function schedule_flush()
  if not internal.enabled then
    return
  end
  if internal.timer then
    internal.timer:stop()
    internal.timer:close()
    internal.timer = nil
  end
  local delay = (internal.cfg and internal.cfg.debounce_ms) or 80
  local timer = uv.new_timer()
  internal.timer = timer
  timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      if internal.timer == timer then
        internal.timer = nil
      end
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
      M.flush_now()
    end)
  )
end

---@return string
function M.path()
  if not internal.state_path then
    local base = uv.os_tmpdir() or "/tmp"
    internal.state_path = string.format("%s/nvim-agentbridge-%d.json", base, vim.fn.getpid())
  end
  return internal.state_path
end

---@return table|nil
function M.get_state()
  return internal.last_state
end

---@param cfg table
function M.enable(cfg)
  internal.cfg = cfg or {}
  internal.enabled = true
  M.path()

  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "CursorMoved", "CursorMovedI", "TextChanged" }, {
    group = group,
    callback = function()
      schedule_flush()
    end,
  })

  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    callback = function(ev)
      local old_mode, new_mode = ev.match:match("^([^:]+):(.+)$")
      old_mode = old_mode and old_mode:sub(1, 1) or ""
      new_mode = new_mode and new_mode:sub(1, 1) or ""

      local bufnr = vim.api.nvim_get_current_buf()
      if not is_visual_mode(old_mode) and is_visual_mode(new_mode) then
        internal.visual_entry_buf = bufnr
        internal.visual_entry_tick = vim.api.nvim_buf_get_changedtick(bufnr)
      elseif is_visual_mode(old_mode) and not is_visual_mode(new_mode) then
        -- Hold the selection if the buffer was not mutated by an operator (d/c/x).
        local mutated = (internal.visual_entry_buf == bufnr)
          and (vim.api.nvim_buf_get_changedtick(bufnr) ~= internal.visual_entry_tick)
        if not mutated and should_track_buffer(bufnr, internal.cfg) then
          local max_bytes = (internal.cfg and internal.cfg.max_selection_bytes) or 8192
          internal.held_selection = capture_marks_selection(bufnr, max_bytes)
          internal.cursor_at_flush = {
            bufnr = bufnr,
            pos = vim.api.nvim_win_get_cursor(0),
          }
        else
          internal.held_selection = nil
          internal.cursor_at_flush = nil
        end
      end

      schedule_flush()
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.cleanup()
    end,
  })

  -- Initial snapshot if a real file buffer is already open
  vim.schedule(function()
    M.flush_now()
  end)
end

function M.cleanup()
  if internal.timer then
    internal.timer:stop()
    internal.timer:close()
    internal.timer = nil
  end
  if internal.state_path then
    pcall(uv.fs_unlink, internal.state_path)
  end
end

function M.disable()
  internal.enabled = false
  pcall(vim.api.nvim_clear_autocmds, { group = AUGROUP })
  M.cleanup()
end

return M
