# rex-agent.nvim

Lightweight, multi-provider Neovim bridge for TUI coding agents (**Antigravity `agy`**, **Claude Code**, multi-account profiles) running in **Rex** split panes (with automatic Neovim terminal fallback outside Rex).

## How It Works

1. **Explicit send** (`:AgentAdd`, `:AgentSend`, `:AgentSendCode`, `:AgentTreeAdd`):
   - Inside Rex (`$REX_BLOCK`), tracks each provider's Rex `block_id` via `rex split --json` and injects mentions/snippets via `rex send` (over stdin, bracketed-paste safe for multiline text).
   - Outside Rex, falls back to a native Neovim vertical split + `vim.fn.chansend`.
2. **Passive live editor context** (active buffer, cursor line/col, visual selection):
   - Debounced Neovim autocmds atomically write a state JSON file (keyed by `$REX_BLOCK` inside Rex so restarting Neovim automatically resumes live tracking for already-open agent panes, or by PID outside Rex) and pass its path as `NVIM_EDITOR_STATE` to every spawned agent pane.
   - **Antigravity (`agy`)** reads it via a global `PreInvocation` hook in `~/.gemini/config/hooks.json` (deduplicated per `conversationId` so it only injects when your file/cursor/selection changes).
   - **Claude Code (`claude` & `claude2`)** automatically receives a stable `--settings` file at launch registering the same script as a `UserPromptSubmit` hook (works across multiple `CLAUDE_CONFIG_DIR` accounts without duplicating settings).

## 1. Register the Antigravity Global Hook

Run `:AgentHookConfig` in Neovim (or add the block below to `~/.gemini/config/hooks.json`):

```json
{
  "nvim-editor-context": {
    "PreInvocation": [
      {
        "type": "command",
        "command": "/usr/bin/python3 /Users/nick/workspaces/misc/rex-agent.nvim/hooks/inject_context.py --provider agy",
        "timeout": 3
      }
    ]
  }
}
```

When you run `agy` outside Neovim (`NVIM_EDITOR_STATE` unset), the hook exits immediately with `{}`.

## 2. Lazy.nvim Config

```lua
return {
  dir = "~/workspaces/misc/rex-agent.nvim",
  name = "rex-agent.nvim",
  main = "rex_agent",
  opts = {
    default_provider = "agy",
    rex = {
      split = "right",
      ratio = 40,
      focus_on_open = true,
      focus_on_send = false,
    },
  },
  cmd = {
    "AgentOpen",
    "AgentFocus",
    "AgentSwitch",
    "AgentResume",
    "AgentContinue",
    "AgentSelectModel",
    "AgentAdd",
    "AgentSend",
    "AgentSendCode",
    "AgentTreeAdd",
    "AgentSendText",
    "AgentStatus",
    "AgentHookConfig",
  },
  keys = {
    { "<leader>a", nil, desc = "AI Agents" },
    { "<leader>ag", "<cmd>AgentOpen agy<cr>", desc = "Open Antigravity" },
    { "<leader>as", "<cmd>AgentOpen claude<cr>", desc = "Open Claude" },
    { "<leader>aa", "<cmd>AgentOpen claude2<cr>", desc = "Open Claude (.claude-2)" },
    { "<leader>ap", "<cmd>AgentSwitch<cr>", desc = "Switch active AI provider" },
    { "<leader>af", "<cmd>AgentFocus<cr>", desc = "Focus active AI pane" },
    { "<leader>ar", "<cmd>AgentResume<cr>", desc = "Resume active AI session" },
    { "<leader>aC", "<cmd>AgentContinue<cr>", desc = "Continue active AI session" },
    { "<leader>am", "<cmd>AgentSelectModel<cr>", desc = "Select model" },
    { "<leader>ab", "<cmd>AgentAdd %<cr>", desc = "Add current buffer" },
    { "<leader>ac", "<cmd>AgentSend<cr>", mode = "v", desc = "Send selection (@mention)" },
    { "<leader>aS", "<cmd>AgentSendCode<cr>", mode = "v", desc = "Send selection (code snippet)" },
    {
      "<leader>as",
      "<cmd>AgentTreeAdd<cr>",
      mode = { "n", "v" },
      desc = "Add file(s) from tree",
      ft = { "NvimTree", "oil", "netrw", "snacks_picker_list" },
    },
  },
}
```
