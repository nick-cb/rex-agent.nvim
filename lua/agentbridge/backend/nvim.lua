---Fallback in-Neovim terminal split backend (used when $REX_BLOCK is unset).
local M = {}

---@type table<string, { bufnr: integer, winid?: integer, job_id: integer }>
local sessions = {}

---@return boolean
function M.is_available()
  return true
end

---@param bufnr integer|nil
---@return integer|nil
local function find_win_for_buf(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

---@param provider_name string
---@return boolean
function M.is_alive(provider_name)
  local s = sessions[provider_name]
  if not s or not s.bufnr or not vim.api.nvim_buf_is_valid(s.bufnr) then
    sessions[provider_name] = nil
    return false
  end
  local status = vim.fn.jobwait({ s.job_id }, 0)[1]
  if status ~= -1 then
    sessions[provider_name] = nil
    return false
  end
  return true
end

---@param provider_name string
---@param cfg table
---@return boolean ok
---@return string|nil err
function M.focus(provider_name, cfg)
  if not M.is_alive(provider_name) then
    return false, "No running Neovim terminal for provider '" .. provider_name .. "'"
  end
  local s = sessions[provider_name]
  local win = find_win_for_buf(s.bufnr)
  if not win then
    local side = (cfg.nvim and cfg.nvim.split_side == "left") and "topleft" or "botright"
    local width = math.floor(vim.o.columns * ((cfg.nvim and cfg.nvim.split_width_percentage) or 0.40))
    vim.cmd(string.format("%s %dvsplit", side, width))
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, s.bufnr)
    s.winid = win
  else
    vim.api.nvim_set_current_win(win)
  end
  if not cfg.nvim or cfg.nvim.auto_insert ~= false then
    vim.cmd("startinsert")
  end
  return true, nil
end

---@param provider_name string
---@param _provider_cfg AgentBridgeProvider
---@param argv_cmd string[]
---@param env table<string, string>
---@param cwd string
---@param cfg table
---@param opts? { force_new?: boolean, focus?: boolean }
---@return boolean ok
---@return boolean spawned
---@return string|nil err
function M.open(provider_name, _provider_cfg, argv_cmd, env, cwd, cfg, opts)
  opts = opts or {}
  if not opts.force_new and M.is_alive(provider_name) then
    if opts.focus ~= false then
      M.focus(provider_name, cfg)
    end
    return true, false, nil
  end

  local prev_win = vim.api.nvim_get_current_win()
  local side = (cfg.nvim and cfg.nvim.split_side == "left") and "topleft" or "botright"
  local width = math.floor(vim.o.columns * ((cfg.nvim and cfg.nvim.split_width_percentage) or 0.40))

  vim.cmd(string.format("%s %dvnew", side, width))
  local win = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()

  local job_id = vim.fn.termopen(argv_cmd, {
    cwd = cwd,
    env = env,
    on_exit = function()
      vim.schedule(function()
        if sessions[provider_name] and sessions[provider_name].bufnr == bufnr then
          sessions[provider_name] = nil
        end
      end)
    end,
  })

  if not job_id or job_id <= 0 then
    pcall(vim.api.nvim_win_close, win, true)
    return false, false, "Failed to start terminal job"
  end

  vim.bo[bufnr].bufhidden = "hide"
  sessions[provider_name] = { bufnr = bufnr, winid = win, job_id = job_id }

  if opts.focus == false and vim.api.nvim_win_is_valid(prev_win) then
    vim.api.nvim_set_current_win(prev_win)
  elseif not cfg.nvim or cfg.nvim.auto_insert ~= false then
    vim.cmd("startinsert")
  end

  return true, true, nil
end

---@param provider_name string
---@param text string
---@param cfg table
---@param opts? { submit?: boolean, focus?: boolean }
---@return boolean ok
---@return string|nil err
function M.send_text(provider_name, text, cfg, opts)
  opts = opts or {}
  if not M.is_alive(provider_name) then
    return false, "No running Neovim terminal for provider '" .. provider_name .. "'"
  end

  local s = sessions[provider_name]
  local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local payload = normalized
  if normalized:find("\n", 1, true) then
    payload = "\27[200~" .. normalized .. "\27[201~"
  end
  if opts.submit then
    payload = payload .. "\r"
  end

  local ok, written = pcall(vim.fn.chansend, s.job_id, payload)
  if not ok or written == 0 then
    return false, "Terminal channel is closed"
  end

  local should_focus = opts.focus
  if should_focus == nil then
    should_focus = cfg.nvim and cfg.nvim.focus_on_send == true
  end
  if should_focus then
    M.focus(provider_name, cfg)
  end

  return true, nil
end

---@param provider_name string
function M.forget(provider_name)
  local s = sessions[provider_name]
  if s and s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
    pcall(vim.api.nvim_buf_delete, s.bufnr, { force = true })
  end
  sessions[provider_name] = nil
end

---@param cfg table
---@return { provider: string, label: string, block_id: string, is_tracked: boolean }[]
function M.list_open(cfg)
  local results = {}
  for name, s in pairs(sessions) do
    if M.is_alive(name) then
      local pcfg = cfg.providers and cfg.providers[name]
      table.insert(results, {
        provider = name,
        label = (pcfg and pcfg.label) or name,
        block_id = "buf:" .. tostring(s.bufnr),
        is_tracked = true,
      })
    end
  end
  table.sort(results, function(a, b)
    return a.provider < b.provider
  end)
  return results
end

---@return table
function M.get_sessions()
  return vim.deepcopy(sessions)
end

return M
