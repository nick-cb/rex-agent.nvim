---Rex terminal multiplexer backend.
---Spawns per-provider Rex split panes via `rex split --json`, tracks their
---block_id, focuses them via `rex focus`, and injects text via `rex send` (stdin).
local M = {}

---@type table<string, { block_id: string, session: string, label: string }>
local sessions = {}

---@param stdout string|nil
---@return string|nil
local function parse_block_id(stdout)
  if not stdout or stdout == "" then
    return nil
  end
  local trimmed = vim.trim(stdout)
  if trimmed == "" then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, trimmed)
  if ok and type(decoded) == "table" then
    if type(decoded.block_id) == "string" and decoded.block_id ~= "" then
      return decoded.block_id
    end
    if type(decoded.id) == "string" and decoded.id ~= "" then
      return decoded.id
    end
    if type(decoded.block) == "table" and type(decoded.block.id) == "string" then
      return decoded.block.id
    end
    if type(decoded.block_ids) == "table" and type(decoded.block_ids[1]) == "string" then
      -- If Rex returns multiple IDs (e.g. anchor + new), pick the one that isn't $REX_BLOCK
      for _, id in ipairs(decoded.block_ids) do
        if id ~= vim.env.REX_BLOCK then
          return id
        end
      end
      return decoded.block_ids[1]
    end
  end

  -- Plain-text fallback (single token block id)
  if not trimmed:find("%s") then
    return trimmed
  end

  return nil
end

---@return boolean
function M.is_available()
  return vim.env.REX_BLOCK ~= nil and vim.env.REX_BLOCK ~= ""
end

---@param cfg table
---@param session string
---@param block_id string
---@return boolean
function M.block_exists(cfg, session, block_id)
  local bin = (cfg.rex and cfg.rex.bin) or "rex"
  -- `rex block inspect [BLOCK] [flags]` takes BLOCK as a positional argument
  local argv = { bin, "block", "inspect", block_id }
  if session and session ~= "" then
    vim.list_extend(argv, { "-s", session })
  end

  local res = vim.system(argv, { text = true }):wait()
  return res.code == 0
end

---@param cfg table
---@return table[]|nil blocks
---@return string|nil my_window
---@return string|nil session
local function list_session_blocks(cfg)
  local session = vim.env.REX_SESSION
  local my_block = vim.env.REX_BLOCK
  if not session or session == "" or not my_block or my_block == "" then
    return nil, nil, nil
  end

  local bin = (cfg.rex and cfg.rex.bin) or "rex"
  local res = vim.system({ bin, "block", "ls", "-s", session, "--json" }, { text = true }):wait()
  if res.code ~= 0 or not res.stdout or res.stdout == "" then
    return nil, nil, nil
  end

  local ok, decoded = pcall(vim.json.decode, res.stdout)
  if not ok or type(decoded) ~= "table" or type(decoded.blocks) ~= "table" then
    return nil, nil, nil
  end

  local my_window = nil
  for _, blk in ipairs(decoded.blocks) do
    if blk.block_id == my_block then
      my_window = blk.window_id
      break
    end
  end

  return decoded.blocks, my_window, session
end

---Find an existing placed block in Neovim's current Rex window matching `label`.
---@param cfg table
---@param label string
---@return string|nil block_id
---@return string|nil session
local function discover_block_in_window(cfg, label)
  if not label or label == "" then
    return nil, nil
  end
  local blocks, my_window, session = list_session_blocks(cfg)
  if not blocks or not my_window then
    return nil, nil
  end

  local my_block = vim.env.REX_BLOCK
  for _, blk in ipairs(blocks) do
    if
      blk.block_id ~= my_block
      and blk.window_id == my_window
      and blk.label == label
      and (blk.placement == nil or blk.placement == "placed")
    then
      return blk.block_id, session
    end
  end

  return nil, nil
end

---List all open Rex blocks in Neovim's current window (excluding Neovim itself),
---matched to configured providers when labels match.
---@param cfg table
---@return { provider: string|nil, label: string, block_id: string, session: string, is_tracked: boolean }[]
function M.list_open(cfg)
  local blocks, my_window, session = list_session_blocks(cfg)
  if not blocks or not my_window then
    return {}
  end

  -- Map provider labels -> provider names
  local label_to_provider = {}
  for name, pcfg in pairs(cfg.providers or {}) do
    local lbl = pcfg.label or name
    label_to_provider[lbl] = name
  end

  -- Map tracked block_ids -> provider names
  local tracked_by_block = {}
  for pname, s in pairs(sessions) do
    if s and s.block_id then
      tracked_by_block[s.block_id] = pname
    end
  end

  local my_block = vim.env.REX_BLOCK
  local results = {}
  for _, blk in ipairs(blocks) do
    if
      blk.block_id ~= my_block
      and blk.window_id == my_window
      and (blk.placement == nil or blk.placement == "placed")
    then
      local pname = tracked_by_block[blk.block_id] or label_to_provider[blk.label or ""]
      table.insert(results, {
        provider = pname,
        label = blk.label or blk.block_id,
        block_id = blk.block_id,
        session = session or "",
        is_tracked = tracked_by_block[blk.block_id] ~= nil,
      })
    end
  end

  return results
end

---Bind a provider (or custom target) to a specific open Rex block_id.
---@param provider_name string
---@param block_id string
---@param label? string
---@param session? string
function M.bind(provider_name, block_id, label, session)
  sessions[provider_name] = {
    block_id = block_id,
    session = session or vim.env.REX_SESSION or "",
    label = label or provider_name,
  }
end

---@param provider_name string
---@param cfg table
---@param provider_cfg? AgentBridgeProvider
---@return boolean
function M.is_alive(provider_name, cfg, provider_cfg)
  local s = sessions[provider_name]
  if s and s.block_id then
    if M.block_exists(cfg, s.session, s.block_id) then
      return true
    end
    sessions[provider_name] = nil
  end

  local label = (provider_cfg and provider_cfg.label) or (cfg.providers and cfg.providers[provider_name] and cfg.providers[provider_name].label)
  if label then
    local found_id, found_sess = discover_block_in_window(cfg, label)
    if found_id then
      sessions[provider_name] = {
        block_id = found_id,
        session = found_sess or "",
        label = label,
      }
      return true
    end
  end

  return false
end

---@param provider_name string
---@param cfg table
---@return boolean ok
---@return string|nil err
function M.focus(provider_name, cfg)
  local s = sessions[provider_name]
  if not s or not s.block_id then
    return false, "No open Rex pane for provider '" .. provider_name .. "'"
  end
  local bin = (cfg.rex and cfg.rex.bin) or "rex"
  -- `rex block focus [BLOCK] [flags]` takes BLOCK as a positional argument
  local argv = { bin, "block", "focus", s.block_id }
  if s.session and s.session ~= "" then
    vim.list_extend(argv, { "-s", s.session })
  end

  local res = vim.system(argv, { text = true }):wait()
  if res.code ~= 0 then
    sessions[provider_name] = nil
    return false, vim.trim(res.stderr or "rex block focus failed")
  end
  return true, nil
end

---Open (or focus if already alive) a Rex split pane for a provider.
---@param provider_name string
---@param provider_cfg AgentBridgeProvider
---@param argv_cmd string[] Full command argv to run in the pane
---@param env table<string, string> Environment variables to inject via `env`
---@param cwd string Working directory for the new pane
---@param cfg table Full plugin config
---@param opts? { force_new?: boolean, focus?: boolean }
---@return boolean ok
---@return boolean spawned True if a new pane was created, false if an existing one was reused
---@return string|nil err
function M.open(provider_name, provider_cfg, argv_cmd, env, cwd, cfg, opts)
  opts = opts or {}
  local rex_cfg = cfg.rex or {}
  local bin = rex_cfg.bin or "rex"
  local session = vim.env.REX_SESSION or ""
  local anchor_block = vim.env.REX_BLOCK

  if not anchor_block or anchor_block == "" then
    return false, false, "REX_BLOCK is not set (not running inside Rex)"
  end

  if not opts.force_new and M.is_alive(provider_name, cfg, provider_cfg) then
    if opts.focus ~= false then
      M.focus(provider_name, cfg)
    end
    return true, false, nil
  end

  local split_dir = rex_cfg.split or "right"
  local ratio = tostring(rex_cfg.ratio or 40)
  local label = provider_cfg.label or provider_name
  local should_focus = opts.focus
  if should_focus == nil then
    should_focus = rex_cfg.focus_on_open ~= false
  end

  local argv = {
    bin,
    "split",
  }
  if session ~= "" then
    vim.list_extend(argv, { "-s", session })
  end
  vim.list_extend(argv, {
    "-b",
    anchor_block,
    "--split=" .. split_dir,
    "--ratio",
    ratio,
    "-c",
    cwd,
    "--label",
    label,
    "--json",
  })
  if not should_focus then
    table.insert(argv, "--focus=false")
  end

  table.insert(argv, "--")
  table.insert(argv, "env")

  local effective_env = vim.deepcopy(env or {})
  if not effective_env.PATH and vim.env.PATH and vim.env.PATH ~= "" then
    effective_env.PATH = vim.env.PATH
  end

  local resolved_cmd = vim.deepcopy(argv_cmd)
  if resolved_cmd[1] and not resolved_cmd[1]:find("/", 1, true) then
    local exe = vim.fn.exepath(resolved_cmd[1])
    if exe and exe ~= "" then
      resolved_cmd[1] = exe
    end
  end

  local env_keys = vim.tbl_keys(effective_env)
  table.sort(env_keys)
  for _, k in ipairs(env_keys) do
    table.insert(argv, k .. "=" .. tostring(effective_env[k]))
  end
  vim.list_extend(argv, resolved_cmd)

  local res = vim.system(argv, { text = true }):wait()
  if res.code ~= 0 then
    return false, false, vim.trim(res.stderr ~= "" and res.stderr or res.stdout or "rex split failed")
  end

  local block_id = parse_block_id(res.stdout)
  if not block_id then
    return false, false, "rex split succeeded but could not parse block_id from output: " .. vim.trim(res.stdout or "")
  end

  sessions[provider_name] = {
    block_id = block_id,
    session = session,
    label = label,
  }
  return true, true, nil
end

---Send text into the provider's Rex pane over stdin.
---@param provider_name string
---@param text string
---@param cfg table
---@param opts? { submit?: boolean, focus?: boolean }
---@return boolean ok
---@return string|nil err
function M.send_text(provider_name, text, cfg, opts)
  opts = opts or {}
  local s = sessions[provider_name]
  if not s or not s.block_id then
    return false, "No open Rex pane for provider '" .. provider_name .. "'"
  end

  local bin = (cfg.rex and cfg.rex.bin) or "rex"
  local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local payload = normalized
  if normalized:find("\n", 1, true) then
    -- Bracketed paste prevents embedded newlines from prematurely submitting
    payload = "\27[200~" .. normalized .. "\27[201~"
  end

  local send_argv = { bin, "send" }
  if s.session and s.session ~= "" then
    vim.list_extend(send_argv, { "-s", s.session })
  end
  vim.list_extend(send_argv, { "-b", s.block_id })

  local res = vim.system(send_argv, { stdin = payload, text = false }):wait()
  if res.code ~= 0 then
    sessions[provider_name] = nil
    return false, vim.trim(res.stderr or "rex send failed")
  end

  if opts.submit then
    local key_argv = { bin, "send-key" }
    if s.session and s.session ~= "" then
      vim.list_extend(key_argv, { "-s", s.session })
    end
    vim.list_extend(key_argv, { "-b", s.block_id, "enter" })
    vim.system(key_argv, { text = true }):wait()
  end

  local should_focus = opts.focus
  if should_focus == nil then
    should_focus = cfg.rex and cfg.rex.focus_on_send == true
  end
  if should_focus then
    M.focus(provider_name, cfg)
  end

  return true, nil
end

---@param provider_name string
function M.forget(provider_name)
  sessions[provider_name] = nil
end

---@return table<string, { block_id: string, session: string, label: string }>
function M.get_sessions()
  return vim.deepcopy(sessions)
end

return M
