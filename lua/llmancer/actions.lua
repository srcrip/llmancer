local M = {}

-- Helper functions for code block extraction
local function find_code_block_boundaries(cursor_line, lines)
  local start_line = cursor_line
  local end_line = cursor_line

  while start_line > 1 and not lines[start_line - 1]:match("^```") do
    start_line = start_line - 1
  end

  while end_line < #lines and not lines[end_line + 1]:match("^```") do
    end_line = end_line + 1
  end

  if start_line >= 1 and end_line <= #lines and
      lines[start_line - 1]:match("^```") and lines[end_line + 1]:match("^```") then
    return start_line, end_line
  end
  return nil, nil
end

local function extract_code_block(lines, start_line, end_line)
  local lang = lines[start_line - 1]:match("^```(.+)$")
  local block = table.concat(vim.list_slice(lines, start_line, end_line), "\n")
  return block, lang
end

-- Get code block under cursor
local function get_code_block_under_cursor()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local start_line, end_line = find_code_block_boundaries(cursor_line, lines)

  if start_line and end_line then
    return extract_code_block(lines, start_line, end_line)
  end
  return nil
end

-- Helper functions for buffer handling
local function get_valid_buffers()
  return vim.tbl_filter(function(bufnr)
    return vim.api.nvim_buf_is_loaded(bufnr)
        and vim.bo[bufnr].buftype == ""
  end, vim.api.nvim_list_bufs())
end

local function format_buffer_items(bufs)
  return vim.tbl_map(function(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    return {
      bufnr = bufnr,
      display = string.format("%d: %s", bufnr, name ~= "" and name or "[No Name]")
    }
  end, bufs)
end

local function show_buffer_selection(items, code_block)
  vim.ui.select(
    items,
    {
      prompt = "Select target buffer:",
      format_item = function(item) return item.display end
    },
    function(choice)
      if choice then
        require('llmancer.application_plan').create_plan(
          { code_block },
          { choice.bufnr }
        )
      end
    end
  )
end

-- Action definitions
local function apply_to_alternate_buffer(code_block)
  local alt_bufnr = vim.fn.bufnr("#")
  if alt_bufnr == -1 then
    vim.notify("No alternate buffer available", vim.log.levels.ERROR)
    return
  end

  require('llmancer.application_plan').create_plan(
    { code_block },
    { alt_bufnr }
  )
end

local function apply_to_selected_buffer(code_block)
  local bufs = get_valid_buffers()
  local items = format_buffer_items(bufs)
  show_buffer_selection(items, code_block)
end

-- Available actions list
local actions = {
  {
    name = "Apply to Alternate Buffer",
    description = "Apply code to the alternate buffer (#)",
    callback = apply_to_alternate_buffer
  },
  {
    name = "Apply to Selected Buffer",
    description = "Apply code to a selected buffer",
    callback = apply_to_selected_buffer
  }
}

local function format_action_items(actions)
  return vim.tbl_map(function(action)
    return {
      name = action.name,
      description = action.description,
      callback = action.callback,
      display = string.format("%s - %s", action.name, action.description)
    }
  end, actions)
end

local function show_action_selection(action_items, code_block)
  vim.ui.select(
    action_items,
    {
      prompt = "Select action:",
      format_item = function(item) return item.display end
    },
    function(choice)
      if choice then
        choice.callback(code_block)
      end
    end
  )
end

-- Show actions picker
function M.show_actions()
  local code_block = get_code_block_under_cursor()
  if not code_block then
    vim.notify("No code block found under cursor", vim.log.levels.WARN)
    return
  end

  local action_items = format_action_items(actions)
  show_action_selection(action_items, code_block)
end

return M

