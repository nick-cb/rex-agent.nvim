---@module 'agentbridge'
---Multi-provider Neovim bridge for TUI coding agents (Antigravity `agy`, Claude Code, etc.)
---with Rex pane automation and passive live cursor/file/selection tracking via hooks.
local config_mod = require("agentbridge.config")
local extract = require("agentbridge.extract")
local state_mod = require("agentbridge.state")

local M = {}

local uv = vim.uv or vim.loop

M.state = {
  config = config_mod.apply(),
  active_provider = "agy",
  initialized = false,
  claude_settings_path = nil,
}

---@return table backend
local function get_backend()
  local mode = M.state.config.backend or "auto"
  if mode == "rex" then
    return require("agentbridge.backend.rex")
  elseif mode == "nvim" then
    return require("agentbridge.backend.nvim")
  end
  local rex = require("agentbridge.backend.rex")
  if rex.is_available() then
    return rex
  end
  return require("agentbridge.backend.nvim")
end

---@return string
local function resolve_cwd()
  local cfg = M.state.config
  if type(cfg.cwd) == "function" then
    local ok, res = pcall(cfg.cwd)
    if ok and type(res) == "string" and res ~= "" then
      return vim.fn.expand(res)
    end
  elseif type(cfg.cwd) == "string" and cfg.cwd ~= "" then
    return vim.fn.expand(cfg.cwd)
  end

  if cfg.git_repo_cwd then
    local file = vim.api.nvim_buf_get_name(0)
    local start = (file ~= "" and vim.fn.fnamemodify(file, ":h")) or vim.fn.getcwd()
    local git_dir = vim.fs.find(".git", { path = start, upward = true })[1]
    if git_dir then
      return vim.fn.fnamemodify(git_dir, ":h")
    end
  end

  return vim.fn.getcwd()
end

---Create (or refresh) a stable Claude Code settings JSON file that registers
---our UserPromptSubmit hook for any Claude account/config dir. Kept stable
---across Neovim restarts so already-open Claude panes keep working.
---@return string|nil
local function ensure_claude_settings_file()
  if M.state.claude_settings_path and vim.fn.filereadable(M.state.claude_settings_path) == 1 then
    return M.state.claude_settings_path
  end

  local cfg = M.state.config
  local cmd = string.format(
    "%s %s --provider claude",
    vim.fn.shellescape(cfg.python_cmd or "/usr/bin/python3"),
    vim.fn.shellescape(cfg.hook_script)
  )

  local payload = vim.json.encode({
    hooks = {
      UserPromptSubmit = {
        {
          hooks = {
            {
              type = "command",
              command = cmd,
              timeout = 3,
            },
          },
        },
      },
    },
  })

  local base = uv.os_tmpdir() or "/tmp"
  local user = (vim.env.USER or "user"):gsub("[^A-Za-z0-9_.-]+", "_")
  local path = string.format("%s/nvim-agentbridge-claude-hooks-%s.json", base, user)
  local tmp = path .. ".tmp." .. tostring(uv.hrtime())
  local fd = uv.fs_open(tmp, "w", tonumber("600", 8))
  if not fd then
    return nil
  end
  local ok = pcall(function()
    uv.fs_write(fd, payload, 0)
  end)
  pcall(uv.fs_close, fd)
  if ok then
    pcall(uv.fs_rename, tmp, path)
    M.state.claude_settings_path = path
    return path
  end
  pcall(uv.fs_unlink, tmp)
  return nil
end

---@param provider_name? string
---@return string name
---@return AgentBridgeProvider|nil cfg
local function resolve_provider(provider_name)
  local name = (provider_name and provider_name ~= "" and provider_name) or M.state.active_provider
  local pcfg = M.state.config.providers[name]
  if not pcfg then
    vim.notify("agentbridge: unknown provider '" .. tostring(name) .. "'", vim.log.levels.ERROR)
    return name, nil
  end
  return name, pcfg
end

---@param provider_cfg AgentBridgeProvider
---@param extra_args? string[]
---@return string[] argv
---@return table<string, string> env
local function build_launch_spec(provider_cfg, extra_args)
  local argv = vim.deepcopy(provider_cfg.cmd)

  if provider_cfg.inject_claude_hook and M.state.config.state.enabled then
    local settings_path = ensure_claude_settings_file()
    if settings_path then
      vim.list_extend(argv, { "--settings", settings_path })
    end
  end

  if extra_args and #extra_args > 0 then
    vim.list_extend(argv, extra_args)
  end

  local env = vim.deepcopy(provider_cfg.env or {})
  if M.state.config.state.enabled then
    env.NVIM_EDITOR_STATE = state_mod.path()
  end

  return argv, env
end

---@return string
function M.active_provider()
  return M.state.active_provider
end

---@param name string
---@return boolean
function M.set_provider(name)
  if not M.state.config.providers[name] then
    vim.notify("agentbridge: unknown provider '" .. tostring(name) .. "'", vim.log.levels.ERROR)
    return false
  end
  M.state.active_provider = name
  vim.notify("agentbridge: active provider -> " .. (M.state.config.providers[name].label or name), vim.log.levels.INFO)
  return true
end

function M.pick_provider()
  local names = vim.tbl_keys(M.state.config.providers)
  table.sort(names)
  vim.ui.select(names, {
    prompt = "Select AI provider:",
    format_item = function(name)
      local p = M.state.config.providers[name]
      local active_mark = (name == M.state.active_provider) and " (active)" or ""
      return string.format("%s [%s]%s", p.label or name, name, active_mark)
    end,
  }, function(choice)
    if choice then
      M.set_provider(choice)
    end
  end)
end

---Open or focus a provider pane, making it the active provider.
---@param provider_name? string
---@param extra_args? string[]
---@param opts? { force_new?: boolean, focus?: boolean }
---@return boolean ok
---@return boolean spawned
function M.open(provider_name, extra_args, opts)
  local name, pcfg = resolve_provider(provider_name)
  if not pcfg then
    return false, false
  end

  M.state.active_provider = name
  state_mod.flush_now()

  local argv, env = build_launch_spec(pcfg, extra_args)
  local cwd = resolve_cwd()
  local backend = get_backend()
  local open_opts = vim.tbl_extend("force", opts or {}, {
    force_new = (opts and opts.force_new) or (extra_args and #extra_args > 0),
  })

  local ok, spawned, err = backend.open(name, pcfg, argv, env, cwd, M.state.config, open_opts)
  if not ok then
    vim.notify("agentbridge: " .. (err or "failed to open pane"), vim.log.levels.ERROR)
    return false, false
  end
  return true, spawned
end

---@param provider_name? string
function M.focus(provider_name)
  local name, pcfg = resolve_provider(provider_name)
  if not pcfg then
    return false
  end
  M.state.active_provider = name
  local backend = get_backend()
  if backend.is_alive(name, M.state.config, pcfg) then
    local ok, err = backend.focus(name, M.state.config)
    if not ok then
      vim.notify("agentbridge: " .. (err or "failed to focus pane"), vim.log.levels.WARN)
    end
    return ok
  end
  local ok = M.open(name)
  return ok
end

---@param provider_name? string
function M.resume(provider_name)
  local name, pcfg = resolve_provider(provider_name)
  if not pcfg then
    return
  end
  M.open(name, pcfg.resume_args or { "--resume" }, { force_new = true })
end

---@param provider_name? string
function M.continue(provider_name)
  local name, pcfg = resolve_provider(provider_name)
  if not pcfg then
    return
  end
  M.open(name, pcfg.continue_args or { "--continue" }, { force_new = true })
end

---@param provider_name? string
function M.select_model(provider_name)
  local name, pcfg = resolve_provider(provider_name)
  if not pcfg then
    return
  end
  local models = pcfg.models or {}
  if #models == 0 then
    vim.notify("agentbridge: no models configured for '" .. name .. "'", vim.log.levels.WARN)
    return
  end
  vim.ui.select(models, {
    prompt = "Select model for " .. (pcfg.label or name) .. ":",
    format_item = function(item)
      return item.name
    end,
  }, function(choice)
    if not choice then
      return
    end
    local flag = pcfg.model_flag or "--model"
    M.open(name, { flag, choice.value }, { force_new = true })
  end)
end

---Send raw text to the active (or specified) provider pane, spawning it first if needed.
---@param text string
---@param opts? { provider?: string, submit?: boolean, focus?: boolean }
---@return boolean
function M.send_text(text, opts)
  opts = opts or {}
  if type(text) ~= "string" or text == "" then
    return false
  end
  local name, pcfg = resolve_provider(opts.provider)
  if not pcfg then
    return false
  end

  local backend = get_backend()
  local function deliver()
    local ok, err = backend.send_text(name, text, M.state.config, {
      submit = opts.submit,
      focus = opts.focus,
    })
    if not ok then
      vim.notify("agentbridge: " .. (err or "failed to send text"), vim.log.levels.ERROR)
    end
    return ok
  end

  if backend.is_alive(name, M.state.config, pcfg) then
    return deliver()
  end

  -- Spawn the pane first, then deliver text after a short startup grace period
  local ok, spawned = M.open(name, nil, { focus = opts.focus == true })
  if not ok then
    return false
  end
  if spawned then
    local delay = M.state.config.launch_send_delay_ms or 600
    vim.defer_fn(deliver, delay)
    return true
  end
  return deliver()
end

---Send a file (with optional 1-based line range) as a provider-formatted @mention.
---@param path? string
---@param start_line? integer
---@param end_line? integer
---@param opts? { provider?: string, submit?: boolean, focus?: boolean }
---@return boolean
function M.send_file(path, start_line, end_line, opts)
  opts = opts or {}
  local name, pcfg = resolve_provider(opts.provider)
  if not pcfg then
    return false
  end

  local cwd = resolve_cwd()
  local target_path = path
  if not target_path or target_path == "" then
    local resolved, err = extract.current_file(cwd)
    if not resolved then
      vim.notify("agentbridge: " .. err, vim.log.levels.WARN)
      return false
    end
    target_path = resolved
  else
    target_path = extract.format_relative(vim.fn.fnamemodify(target_path, ":p"), cwd)
  end

  local fmt = pcfg.format_mention
  local mention = fmt and fmt(target_path, start_line, end_line) or ("@" .. target_path .. " ")
  return M.send_text(mention, vim.tbl_extend("force", opts, { provider = name }))
end

---Send the visual selection either as an @path#L10-20 mention or as a fenced code snippet.
---@param line1? integer
---@param line2? integer
---@param opts? { provider?: string, mode?: "mention"|"snippet", submit?: boolean, focus?: boolean }
---@return boolean
function M.send_visual(line1, line2, opts)
  opts = opts or {}
  local cwd = resolve_cwd()
  local sel, err = extract.visual_selection(line1, line2, cwd)
  if not sel then
    vim.notify("agentbridge: " .. err, vim.log.levels.WARN)
    return false
  end

  if opts.mode == "snippet" then
    return M.send_text(extract.format_snippet(sel), opts)
  end
  return M.send_file(sel.abs_path, sel.start_line, sel.end_line, opts)
end

---Send selected file(s) from nvim-tree / oil / snacks picker.
---@param line1? integer
---@param line2? integer
---@param opts? { provider?: string, submit?: boolean, focus?: boolean }
---@return boolean
function M.send_tree(line1, line2, opts)
  opts = opts or {}
  local name, pcfg = resolve_provider(opts.provider)
  if not pcfg then
    return false
  end

  local cwd = resolve_cwd()
  local files, err = extract.tree_files(line1, line2, cwd)
  if not files or #files == 0 then
    vim.notify("agentbridge: " .. (err or "no files selected"), vim.log.levels.WARN)
    return false
  end

  local chunks = {}
  local fmt = pcfg.format_mention
  for _, p in ipairs(files) do
    table.insert(chunks, fmt and fmt(p) or ("@" .. p .. " "))
  end
  return M.send_text(table.concat(chunks, ""), vim.tbl_extend("force", opts, { provider = name }))
end

---Return the exact JSON snippet needed for ~/.gemini/config/hooks.json (Antigravity CLI).
---@return string
function M.agy_hooks_json()
  local cfg = M.state.config
  local cmd = string.format("%s %s --provider agy", cfg.python_cmd or "/usr/bin/python3", cfg.hook_script)
  return vim.json.encode({
    ["nvim-editor-context"] = {
      PreInvocation = {
        {
          type = "command",
          command = cmd,
          timeout = 3,
        },
      },
    },
  })
end

local function create_commands()
  vim.api.nvim_create_user_command("AgentOpen", function(opts)
    local args = opts.fargs or {}
    local provider = nil
    local extra = {}
    if #args > 0 and M.state.config.providers[args[1]] then
      provider = args[1]
      for i = 2, #args do
        table.insert(extra, args[i])
      end
    else
      extra = args
    end
    M.open(provider, #extra > 0 and extra or nil)
  end, {
    nargs = "*",
    complete = function()
      return vim.tbl_keys(M.state.config.providers)
    end,
    desc = "Open or focus an AI agent pane (optional provider name + CLI args)",
  })

  vim.api.nvim_create_user_command("AgentFocus", function(opts)
    M.focus(opts.args ~= "" and opts.args or nil)
  end, {
    nargs = "?",
    complete = function()
      return vim.tbl_keys(M.state.config.providers)
    end,
    desc = "Focus the active (or named) AI agent pane",
  })

  vim.api.nvim_create_user_command("AgentSwitch", function(opts)
    if opts.args ~= "" then
      M.set_provider(opts.args)
    else
      M.pick_provider()
    end
  end, {
    nargs = "?",
    complete = function()
      return vim.tbl_keys(M.state.config.providers)
    end,
    desc = "Switch the active AI provider",
  })

  vim.api.nvim_create_user_command("AgentResume", function(opts)
    M.resume(opts.args ~= "" and opts.args or nil)
  end, { nargs = "?", desc = "Resume last session for active provider" })

  vim.api.nvim_create_user_command("AgentContinue", function(opts)
    M.continue(opts.args ~= "" and opts.args or nil)
  end, { nargs = "?", desc = "Continue most recent conversation for active provider" })

  vim.api.nvim_create_user_command("AgentSelectModel", function(opts)
    M.select_model(opts.args ~= "" and opts.args or nil)
  end, { nargs = "?", desc = "Pick a model and open active provider" })

  vim.api.nvim_create_user_command("AgentAdd", function(opts)
    local arg = opts.args
    if arg == "" or arg == "%" then
      M.send_file()
    else
      local path = arg:match("^[%%#<]") and vim.fn.expand(arg) or vim.fn.expand(arg)
      M.send_file(path)
    end
  end, { nargs = "?", complete = "file", desc = "Send current buffer or file path to active agent" })

  vim.api.nvim_create_user_command("AgentSend", function(opts)
    if extract.is_tree_filetype(vim.bo.filetype or "") then
      local l1 = opts.range > 0 and opts.line1 or nil
      local l2 = opts.range > 0 and opts.line2 or nil
      M.send_tree(l1, l2)
      return
    end
    local l1 = opts.range > 0 and opts.line1 or nil
    local l2 = opts.range > 0 and opts.line2 or nil
    M.send_visual(l1, l2, { mode = "mention" })
  end, { range = true, desc = "Send visual selection (or tree file) as @mention to active agent" })

  vim.api.nvim_create_user_command("AgentSendCode", function(opts)
    local l1 = opts.range > 0 and opts.line1 or nil
    local l2 = opts.range > 0 and opts.line2 or nil
    M.send_visual(l1, l2, { mode = "snippet" })
  end, { range = true, desc = "Send visual selection as a fenced code snippet to active agent" })

  vim.api.nvim_create_user_command("AgentTreeAdd", function(opts)
    local l1 = opts.range > 0 and opts.line1 or nil
    local l2 = opts.range > 0 and opts.line2 or nil
    M.send_tree(l1, l2)
  end, { range = true, desc = "Send selected file(s) from tree explorer to active agent" })

  vim.api.nvim_create_user_command("AgentSendText", function(opts)
    M.send_text(opts.args, { submit = not opts.bang })
  end, { nargs = "+", bang = true, desc = "Send raw text to active agent (! = insert without submitting)" })

  vim.api.nvim_create_user_command("AgentStatus", function()
    local backend_name = (get_backend() == require("agentbridge.backend.rex")) and "rex" or "nvim"
    local msg = string.format(
      "agentbridge: provider=%s backend=%s state_file=%s",
      M.state.active_provider,
      backend_name,
      M.state.config.state.enabled and state_mod.path() or "disabled"
    )
    vim.notify(msg, vim.log.levels.INFO)
  end, { desc = "Show agentbridge status" })

  vim.api.nvim_create_user_command("AgentHookConfig", function()
    print(M.agy_hooks_json())
  end, { desc = "Print the ~/.gemini/config/hooks.json snippet for Antigravity CLI" })
end

---@param user_opts? table
---@return table
function M.setup(user_opts)
  M.state.config = config_mod.apply(user_opts)
  M.state.active_provider = M.state.config.default_provider or "agy"

  if M.state.config.state.enabled then
    state_mod.enable(M.state.config.state)
  end

  create_commands()

  M.state.initialized = true
  return M
end

return M
