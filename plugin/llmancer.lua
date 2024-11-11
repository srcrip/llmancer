-- Create augroup for all LLMancer autocommands
local group = vim.api.nvim_create_augroup("LLMancerSetup", { clear = true })

-- Setup autocommands for llmancer filetype
vim.api.nvim_create_autocmd("FileType", {
  pattern = "llmancer",
  group = group,
  callback = function(ev)
    local bufnr = ev.buf

    -- Ensure required modules are loaded
    local ok1, chat = pcall(require, 'llmancer.chat')
    local ok2, main = pcall(require, 'llmancer.main')
    
    if not (ok1 and ok2) then
      vim.notify("Failed to load required modules", vim.log.levels.ERROR)
      return
    end

    -- Set buffer options
    vim.bo[bufnr].bufhidden = 'hide'
    vim.bo[bufnr].swapfile = false

    -- Enable treesitter if available
    if pcall(require, "nvim-treesitter.configs") then
      vim.schedule(function()
        vim.cmd([[TSBufEnable highlight]])
        vim.cmd([[TSBufEnable indent]])
        pcall(vim.treesitter.start, bufnr, "markdown")
      end)
    end

    -- Setup buffer mappings
    chat.setup_buffer_mappings(bufnr)

    -- Check if this is a new buffer or existing file
    local is_new_buffer = vim.fn.filereadable(vim.api.nvim_buf_get_name(bufnr)) == 0

    -- Initialize chat history
    if not chat.chat_history[bufnr] then
      local id = chat.generate_id()
      chat.chat_history[bufnr] = {
        {
          content = chat.build_system_prompt(),
          id = id,
          opts = { visible = false },
          role = "system"
        }
      }
    end

    -- Add help text only for new buffers
    if is_new_buffer then
      local help_text = chat.create_help_text(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, help_text)
    end

    -- Try to determine target buffer
    local target_bufnr = vim.fn.bufnr('#')
    if target_bufnr ~= -1 and target_bufnr ~= bufnr then
      chat.set_target_buffer(bufnr, target_bufnr)
    end
  end,
})

-- Also set up BufEnter autocmd as a fallback
vim.api.nvim_create_autocmd("BufEnter", {
  pattern = "*.llmc",
  group = group,
  callback = function(ev)
    local ft = vim.bo[ev.buf].filetype
    if ft ~= "llmancer" then
      vim.bo[ev.buf].filetype = "llmancer"
    end
  end,
})
