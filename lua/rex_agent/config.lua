---@class RexAgentProvider
---@field cmd string[] Base command argv (e.g. { "agy" } or { "claude" })
---@field label string Display label for Rex pane / UI
---@field extends? string Optional parent provider name to inherit fields from
---@field env? table<string, string> Extra environment variables for this provider
---@field resume_args? string[] Args appended by :AgentResume
---@field continue_args? string[] Args appended by :AgentContinue
---@field model_flag? string CLI flag for selecting a model (default "--model")
---@field models? { name: string, value: string }[] Model picker entries
---@field inject_claude_hook? boolean Pass session-only --settings JSON for Claude UserPromptSubmit hook
---@field format_mention? fun(path: string, start_line?: integer, end_line?: integer): string

local M = {}

---Locate the plugin root directory from this file's path.
---@return string
function M.plugin_root()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  -- <root>/lua/rex_agent/config.lua -> <root>
  return vim.fn.fnamemodify(source, ":p:h:h:h")
end

---Default path to the shared Python hook script.
---@return string
function M.default_hook_script()
  return M.plugin_root() .. "/hooks/inject_context.py"
end

---@param path string
---@param start_line? integer
---@param end_line? integer
---@return string
local function format_claude_mention(path, start_line, end_line)
  if start_line and end_line then
    if start_line == end_line then
      return string.format("@%s#L%d ", path, start_line)
    end
    return string.format("@%s#L%d-%d ", path, start_line, end_line)
  elseif start_line then
    return string.format("@%s#L%d ", path, start_line)
  end
  return "@" .. path .. " "
end

---@param path string
---@param start_line? integer
---@param end_line? integer
---@return string
local function format_agy_mention(path, start_line, end_line)
  if start_line and end_line then
    if start_line == end_line then
      return string.format("@%s:%d ", path, start_line)
    end
    return string.format("@%s:%d-%d ", path, start_line, end_line)
  elseif start_line then
    return string.format("@%s:%d ", path, start_line)
  end
  return "@" .. path .. " "
end

M.defaults = {
  default_provider = "agy",
  -- "auto" uses Rex when $REX_BLOCK is present, otherwise Neovim terminal split
  backend = "auto",
  python_cmd = "/usr/bin/python3",
  hook_script = nil, -- defaults to <plugin_root>/hooks/inject_context.py
  -- Delay (ms) after spawning a brand-new pane before injecting queued initial send_text
  launch_send_delay_ms = 600,
  -- Optional static cwd or function(): string
  cwd = nil,
  git_repo_cwd = false,

  rex = {
    bin = "rex",
    split = "right", -- "right" | "left" | "below" | "above"
    ratio = 40,
    focus_on_open = true,
    focus_on_send = false,
  },

  nvim = {
    split_side = "right", -- "right" | "left"
    split_width_percentage = 0.40,
    auto_insert = true,
    focus_on_send = false,
  },

  state = {
    enabled = true,
    debounce_ms = 80,
    max_selection_bytes = 8192,
    ignore_filetypes = {
      NvimTree = true,
      ["neo-tree"] = true,
      oil = true,
      minifiles = true,
      netrw = true,
      snacks_picker_list = true,
      qf = true,
      help = true,
      TelescopePrompt = true,
      lazy = true,
      mason = true,
    },
  },

  providers = {
    agy = {
      cmd = { "agy" },
      label = "Antigravity",
      resume_args = { "--continue" },
      continue_args = { "--continue" },
      model_flag = "--model",
      models = {
        { name = "Default (auto)", value = "auto" },
        { name = "Gemini 3 Pro", value = "gemini-3-pro" },
        { name = "Gemini 3 Flash", value = "gemini-3-flash" },
      },
      format_mention = format_agy_mention,
    },
    claude = {
      cmd = { "claude" },
      label = "Claude",
      resume_args = { "--resume" },
      continue_args = { "--continue" },
      model_flag = "--model",
      inject_claude_hook = true,
      models = {
        { name = "Claude Opus (Latest)", value = "opus" },
        { name = "Claude Opus (1M context)", value = "opus[1m]" },
        { name = "Claude Sonnet (Latest)", value = "sonnet" },
        { name = "Claude Sonnet (1M context)", value = "sonnet[1m]" },
        { name = "Claude Haiku (Latest)", value = "haiku" },
        { name = "Default", value = "default" },
      },
      format_mention = format_claude_mention,
    },
    claude2 = {
      extends = "claude",
      label = "Claude-2",
      env = {
        CLAUDE_CONFIG_DIR = vim.fn.expand("~/.claude-2"),
      },
    },
  },
}

---Resolve `extends` inheritance on provider configs.
---@param providers table<string, RexAgentProvider>
---@return table<string, RexAgentProvider>
local function resolve_providers(providers)
  local resolved = {}

  local function resolve_one(name, seen)
    if resolved[name] then
      return resolved[name]
    end
    local raw = providers[name]
    if not raw then
      return nil
    end
    seen = seen or {}
    if seen[name] then
      error("rex-agent: cyclic provider inheritance involving '" .. name .. "'")
    end
    seen[name] = true

    local result = vim.deepcopy(raw)
    if raw.extends then
      local parent = resolve_one(raw.extends, seen)
      if not parent then
        error("rex-agent: provider '" .. name .. "' extends unknown provider '" .. raw.extends .. "'")
      end
      result = vim.tbl_deep_extend("force", vim.deepcopy(parent), result)
      result.extends = nil
    end

    if result.env then
      local expanded = {}
      for k, v in pairs(result.env) do
        if type(v) == "string" and v:sub(1, 1) == "~" then
          expanded[k] = vim.fn.expand(v)
        else
          expanded[k] = tostring(v)
        end
      end
      result.env = expanded
    end

    resolved[name] = result
    return result
  end

  for name in pairs(providers) do
    resolve_one(name)
  end

  return resolved
end

---@param user_opts? table
---@return table
function M.apply(user_opts)
  local cfg = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_opts or {})
  if not cfg.hook_script then
    cfg.hook_script = M.default_hook_script()
  else
    cfg.hook_script = vim.fn.expand(cfg.hook_script)
  end
  cfg.providers = resolve_providers(cfg.providers)
  return cfg
end

return M
