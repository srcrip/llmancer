local M = {}

---Creates a thinking indicator in the specified buffer
---@param bufnr number Buffer number
---@param line_nr number|nil Line number to show indicator (0-based), defaults to last line
---@return function Function to stop the thinking indicator
function M.create_thinking_indicator(bufnr, line_nr)
  local ns_id = vim.api.nvim_create_namespace('llmancer_thinking')
  local current_text = "⟳ Thinking"
  local dots = 0
  local max_dots = 3

  line_nr = line_nr or vim.api.nvim_buf_line_count(bufnr) - 1

  -- Create initial extmark for the indicator
  local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_nr, 0, {
    virt_text = {{current_text, "Comment"}},
    virt_text_pos = "eol",
  })

  local timer = vim.loop.new_timer()
  timer:start(0, 500, vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      timer:stop()
      return
    end

    dots = (dots + 1) % (max_dots + 1)
    local text = current_text .. string.rep(".", dots)
    
    -- Update the existing extmark instead of creating a new one
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_nr, 0, {
      virt_text = {{text, "Comment"}},
      virt_text_pos = "eol",
      id = extmark_id  -- Reuse the same extmark ID
    })
  end))

  return function()
    timer:stop()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    end
  end
end

---Creates a thinking indicator for inline edits with highlighting
---@param bufnr number Buffer number
---@param start_line number Starting line (0-based)
---@param end_line number Ending line (0-based)
---@return function Function to stop the thinking indicator and clear highlights
function M.create_inline_edit_indicator(bufnr, start_line, end_line)
  local ns_id = vim.api.nvim_create_namespace('llmancer_inline_edit')
  local current_text = "⟳ Editing"
  local dots = 0
  local max_dots = 3

  -- Create a custom highlight group for the selection
  vim.api.nvim_set_hl(0, 'LLMancerInlineEdit', {
    bg = '#2c3043',  -- A softer, more muted background color
    blend = 20       -- Some transparency
  })

  -- Add highlights for the selected region
  for line = start_line, end_line do
    vim.api.nvim_buf_add_highlight(
      bufnr,
      ns_id,
      'LLMancerInlineEdit',
      line,
      0,
      -1
    )
  end

  -- Create initial extmark for the indicator
  local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, ns_id, start_line, 0, {
    virt_text = {{current_text, "Comment"}},
    virt_text_pos = "eol",
  })

  local timer = vim.loop.new_timer()
  timer:start(0, 500, vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      timer:stop()
      return
    end

    dots = (dots + 1) % (max_dots + 1)
    local text = current_text .. string.rep(".", dots)
    
    -- Update the existing extmark instead of creating a new one
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, start_line, 0, {
      virt_text = {{text, "Comment"}},
      virt_text_pos = "eol",
      id = extmark_id  -- Reuse the same extmark ID
    })
  end))

  return function()
    timer:stop()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    end
  end
end

return M 