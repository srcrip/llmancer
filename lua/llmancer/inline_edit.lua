local api = require "llmancer.api"
local indicators = require "llmancer.indicators"

local M = {}

---Create a floating window for editing instructions
---@return number bufnr Buffer number of the new window
---@return number win_id Window ID of the new window
local function create_edit_window()
  -- Calculate dimensions based on editor size
  local width = math.min(120, math.floor(vim.o.columns * 0.8))
  local height = math.min(20, math.floor(vim.o.lines * 0.4))
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  -- todo: get some other custom filetype made
  -- vim.api.nvim_buf_set_option(bufnr, 'filetype', 'markdown')

  local opts = {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    anchor = "NW",
    style = "minimal",
    border = "rounded",
    title = " Edit Instructions ",
    title_pos = "center",
  }

  local win_id = vim.api.nvim_open_win(bufnr, true, opts)

  -- Set window-local options for better editing experience
  vim.wo[win_id].wrap = true
  vim.wo[win_id].conceallevel = 2
  vim.wo[win_id].concealcursor = "nc"

  return bufnr, win_id
end

---Get the current visual selection
---@return table|nil selection Object containing selection details or nil if invalid
---@field lines string[] Selected lines
---@field start_line number Starting line number
---@field end_line number Ending line number
---@field text string Complete selected text
local function get_visual_selection()
  local mode = vim.fn.mode()
  if mode == "n" then
    -- Normal mode - get the last visual selection
    local start_pos = vim.fn.getpos "'<"
    local end_pos = vim.fn.getpos "'>"
    local start_line = start_pos[2]
    local end_line = end_pos[2]

    -- Validate selection
    if start_line <= 0 or end_line <= 0 then
      return nil
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

    if not lines or #lines == 0 then
      return nil
    end

    return {
      lines = lines,
      start_line = start_line,
      end_line = end_line,
      text = table.concat(lines, "\n"),
    }
  elseif mode:match "[vV]" then
    -- Visual mode - get the current selection
    local _, csrow, cscol, _ = unpack(vim.fn.getpos ".")
    local _, cerow, cecol, _ = unpack(vim.fn.getpos "v")

    -- Normalize positions (make sure start comes before end)
    local start_line = math.min(csrow, cerow)
    local end_line = math.max(csrow, cerow)

    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

    if not lines or #lines == 0 then
      return nil
    end

    return {
      lines = lines,
      start_line = start_line,
      end_line = end_line,
      text = table.concat(lines, "\n"),
    }
  end
  return nil
end

---Handle the submission of editing instructions
---@param bufnr number Buffer number of the instruction window
---@param win_id number Window ID of the instruction window
---@param target_bufnr number Buffer number of the target file
---@param start_line number Starting line of the selection
---@param end_line number Ending line of the selection
local function handle_edit_submit(bufnr, win_id, target_bufnr, start_line, end_line)
  -- Get all lines
  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Find the separator line
  local separator_index
  for i, line in ipairs(all_lines) do
    if line:match "^%-%-%-%-%-%-" then
      separator_index = i
      break
    end
  end

  -- Get only the lines after the separator
  local instruction_lines = {}
  if separator_index then
    for i = separator_index + 1, #all_lines do
      table.insert(instruction_lines, all_lines[i])
    end
  end

  local instruction = table.concat(instruction_lines, "\n")

  -- Get the code that was selected
  local current_code = table.concat(vim.api.nvim_buf_get_lines(target_bufnr, start_line - 1, end_line, false), "\n")

  vim.api.nvim_win_close(win_id, true)

  -- Show thinking indicator with highlighting
  local stop_thinking = indicators.create_inline_edit_indicator(target_bufnr, start_line - 1, end_line - 1)

  local msg = [[
I have this code:

```javascript
%s
```

Please provide ONLY a code block with the updated code. The code block should contain the complete replacement for the selected code.

Rules:
1. You MUST preserve the EXACT indentation level of each line from the original code
2. Do not modify the indentation or spacing at the start of any line
3. Do not omit any parts of the code, even if they are unchanged

Here are the user's instructions:

<instructions>
%s
</instructions>
]]

  -- Prepare the message for the AI
  local message = string.format(msg, current_code, instruction)

  -- Send request to the AI
  api.send_message(
    {
      { role = "user", content = message },
    },
    nil,
    function(success, response, error)
      stop_thinking() -- This will now clear both the indicator and highlights

      if not success then
        vim.schedule(function()
          vim.notify(error, vim.log.levels.ERROR)
        end)
        return
      end

      -- Extract code block from response
      local code = response:match "```[%w_]*\n(.-)\n```"
      if not code then
        vim.schedule(function()
          vim.notify("No code block found in response", vim.log.levels.ERROR)
        end)
        return
      end

      -- Apply the changes to the buffer
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(target_bufnr) then
          local lines = vim.split(code, "\n")
          vim.api.nvim_buf_set_lines(target_bufnr, start_line - 1, end_line, false, lines)
        end
      end)
    end
  )
end

---Start the inline editing process
---@public
function M.start_edit()
  -- Get the selection immediately while still in visual mode
  local selection = get_visual_selection()

  if not selection then
    vim.notify("No text selected", vim.log.levels.ERROR)
    return
  end

  local target_bufnr = vim.api.nvim_get_current_buf()
  local edit_bufnr, win_id = create_edit_window()

  -- Set up the instruction buffer
  vim.api.nvim_buf_set_lines(edit_bufnr, 0, -1, false, {
    "Enter your editing instructions here.",
    "Press <Enter> in normal mode to submit.",
    "----------",
    "",
    "",
  })

  -- Set cursor position to the first empty line after the separator
  vim.api.nvim_win_set_cursor(win_id, { 5, 0 })

  -- Set up keymaps for the instruction window
  vim.keymap.set("n", "<CR>", function()
    handle_edit_submit(edit_bufnr, win_id, target_bufnr, selection.start_line, selection.end_line)
  end, { buffer = edit_bufnr, noremap = true })

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win_id, true)
  end, { buffer = edit_bufnr, noremap = true })

  -- Start in insert mode
  vim.cmd "startinsert"
end

return M
