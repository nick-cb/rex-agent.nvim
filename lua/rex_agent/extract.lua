---Context extractors for buffers, visual selections, and file explorers.
local M = {}

---@param abs_path string
---@param cwd? string
---@return string
function M.format_relative(abs_path, cwd)
  if not abs_path or abs_path == "" then
    return ""
  end
  cwd = cwd or vim.fn.getcwd()
  local is_dir = vim.fn.isdirectory(abs_path) == 1
  local formatted = abs_path
  if cwd and cwd ~= "" then
    local prefix = cwd:sub(-1) == "/" and cwd or (cwd .. "/")
    if abs_path == cwd then
      formatted = "./"
    elseif abs_path:sub(1, #prefix) == prefix then
      formatted = abs_path:sub(#prefix + 1)
    end
  end
  if is_dir and formatted:sub(-1) ~= "/" then
    formatted = formatted .. "/"
  end
  return formatted
end

---Get the current buffer's file path (relative to cwd if inside it).
---@param cwd? string
---@return string|nil path
---@return string|nil err
function M.current_file(cwd)
  local abs = vim.api.nvim_buf_get_name(0)
  if not abs or abs == "" then
    return nil, "Current buffer has no file path"
  end
  return M.format_relative(abs, cwd), nil
end

---Extract the visual selection range and text from the current buffer.
---@param line1? integer
---@param line2? integer
---@param cwd? string
---@return table|nil selection
---@return string|nil err
function M.visual_selection(line1, line2, cwd)
  local abs = vim.api.nvim_buf_get_name(0)
  if not abs or abs == "" then
    return nil, "Current buffer has no file path"
  end

  local l1, l2 = line1, line2
  if not l1 or not l2 or l1 <= 0 or l2 <= 0 then
    local mode = vim.fn.mode(1):sub(1, 1)
    if mode == "v" or mode == "V" or mode == "\22" then
      l1 = vim.fn.line("v")
      l2 = vim.fn.line(".")
    else
      l1 = vim.fn.line("'<")
      l2 = vim.fn.line("'>")
    end
  end

  if not l1 or not l2 or l1 <= 0 or l2 <= 0 then
    return nil, "No visual selection available"
  end
  if l1 > l2 then
    l1, l2 = l2, l1
  end

  local lines = vim.api.nvim_buf_get_lines(0, l1 - 1, l2, false)
  return {
    path = M.format_relative(abs, cwd),
    abs_path = abs,
    start_line = l1,
    end_line = l2,
    filetype = vim.bo.filetype or "",
    text = table.concat(lines, "\n"),
  }, nil
end

---Format a selection table as a fenced code snippet with file + line header.
---@param sel table
---@return string
function M.format_snippet(sel)
  local range = sel.start_line == sel.end_line and ("L" .. sel.start_line)
    or string.format("L%d-%d", sel.start_line, sel.end_line)
  local fence = "```"
  while sel.text:find(fence, 1, true) do
    fence = fence .. "`"
  end
  return string.format("%s#%s:\n%s%s\n%s\n%s\n", sel.path, range, fence, sel.filetype, sel.text, fence)
end

---@param line1? integer
---@param line2? integer
---@return string[]|nil files
---@return string|nil err
local function extract_nvim_tree(line1, line2)
  local ok, api = pcall(require, "nvim-tree.api")
  if not ok then
    return nil, "nvim-tree is not available"
  end

  local files = {}
  local seen = {}

  local function add_node(node)
    if node and node.absolute_path and not seen[node.absolute_path] then
      seen[node.absolute_path] = true
      table.insert(files, node.absolute_path)
    end
  end

  if line1 and line2 and line1 > 0 and line2 >= line1 and line1 ~= line2 then
    local saved = vim.api.nvim_win_get_cursor(0)
    for lnum = line1, line2 do
      pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
      local ok_n, node = pcall(api.tree.get_node_under_cursor)
      if ok_n then
        add_node(node)
      end
    end
    pcall(vim.api.nvim_win_set_cursor, 0, saved)
  else
    -- Prefer nvim-tree marks if any are set, otherwise node under cursor.
    local ok_m, marks = pcall(function()
      return api.marks and api.marks.list and api.marks.list()
    end)
    if ok_m and type(marks) == "table" and #marks > 0 then
      for _, node in ipairs(marks) do
        add_node(node)
      end
    else
      local ok_n, node = pcall(api.tree.get_node_under_cursor)
      if ok_n then
        add_node(node)
      end
    end
  end

  if #files == 0 then
    return nil, "No file selected in nvim-tree"
  end
  return files, nil
end

---@param line1? integer
---@param line2? integer
---@return string[]|nil files
---@return string|nil err
local function extract_oil(line1, line2)
  local ok, oil = pcall(require, "oil")
  if not ok then
    return nil, "oil.nvim is not available"
  end
  local dir = oil.get_current_dir()
  if not dir then
    return nil, "Could not determine oil directory"
  end

  local files = {}
  local start_l = (line1 and line1 > 0) and line1 or vim.fn.line(".")
  local end_l = (line2 and line2 >= start_l) and line2 or start_l

  local saved = vim.api.nvim_win_get_cursor(0)
  for lnum = start_l, end_l do
    pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
    local entry = oil.get_cursor_entry()
    if entry and entry.name then
      table.insert(files, dir .. entry.name)
    end
  end
  pcall(vim.api.nvim_win_set_cursor, 0, saved)

  if #files == 0 then
    return nil, "No file selected in oil"
  end
  return files, nil
end

---@return string[]|nil files
---@return string|nil err
local function extract_snacks_picker()
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.picker then
    return nil, "snacks.picker is not available"
  end
  local pickers = snacks.picker.get({ tab = true })
  for _, picker in ipairs(pickers or {}) do
    local selected = picker:selected({ fallback = true })
    if selected and #selected > 0 then
      local files = {}
      for _, item in ipairs(selected) do
        local path = item.file or item._path
        if path then
          table.insert(files, path)
        end
      end
      if #files > 0 then
        return files, nil
      end
    end
  end
  return nil, "No file selected in snacks picker"
end

---@param ft string
---@return boolean
function M.is_tree_filetype(ft)
  return ft == "NvimTree"
    or ft == "oil"
    or ft == "snacks_picker_list"
    or ft == "netrw"
end

---Extract selected file path(s) from the active file explorer buffer.
---@param line1? integer
---@param line2? integer
---@param cwd? string
---@return string[]|nil paths
---@return string|nil err
function M.tree_files(line1, line2, cwd)
  local ft = vim.bo.filetype or ""
  local raw_files, err

  if ft == "NvimTree" then
    raw_files, err = extract_nvim_tree(line1, line2)
  elseif ft == "oil" then
    raw_files, err = extract_oil(line1, line2)
  elseif ft == "snacks_picker_list" then
    raw_files, err = extract_snacks_picker()
  elseif ft == "netrw" then
    local dir = vim.b.netrw_curdir or vim.fn.getcwd()
    local word = vim.fn.expand("<cfile>")
    if word and word ~= "" then
      raw_files = { dir .. "/" .. word }
    else
      err = "No file under cursor in netrw"
    end
  else
    return nil, "Unsupported file explorer filetype: " .. ft
  end

  if err or not raw_files then
    return nil, err
  end

  local formatted = {}
  for _, p in ipairs(raw_files) do
    table.insert(formatted, M.format_relative(p, cwd))
  end
  return formatted, nil
end

return M
