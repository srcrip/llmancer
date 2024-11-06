---@class CustomModule
---@field config Config Current configuration
---@field setup fun(opts: Config|nil) Setup function
---@field open_chat fun() Function to open chat buffer
---@field list_chats fun() Function to list saved chats
local M = {}

-- Default configuration
---@type Config
M.config = {
  -- How to open the chat buffer: 'vsplit', 'split', or 'enew'
  open_mode = 'vsplit',
  -- Buffer name for the chat
  buffer_name = 'LLMancer.nvim',
  -- Anthropic API key (defaults to environment variable)
  anthropic_api_key = os.getenv("ANTHROPIC_API_KEY"),
  -- Model to use
  model = "claude-3-sonnet-20240229",
  -- Max tokens for response
  max_tokens = 4096,
  -- Temperature (0.0 to 1.0)
  temperature = 0.7,
  -- System prompt
  system_prompt = "You are a helpful AI assistant with expertise in programming and software development.",
  -- Directory to store chat histories
  storage_dir = vim.fn.stdpath("data") .. "/llmancer/chats",
}

-- Setup function to initialize the plugin with user config
---@param opts Config|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  
  if not M.config.anthropic_api_key then
    vim.notify("LLMancer: No Anthropic API key found!", vim.log.levels.ERROR)
    return
  end
  
  -- Create storage directory if it doesn't exist
  vim.fn.mkdir(M.config.storage_dir, "p")

  -- Ensure treesitter is available and configure it
  local ok, ts_configs = pcall(require, "nvim-treesitter.configs")
  if ok then
    local parsers = {
      "markdown", "markdown_inline",
      "lua", "python", "javascript",
      "typescript", "rust", "go",
    }
    
    ts_configs.setup({
      ensure_installed = parsers,
      highlight = {
        enable = true,
        additional_vim_regex_highlighting = { "markdown", "llmancer" },
      },
    })

    -- Install missing parsers
    local ts_parsers = require("nvim-treesitter.parsers")
    for _, lang in ipairs(parsers) do
      if not ts_parsers.has_parser(lang) then
        vim.cmd("TSInstall " .. lang)
      end
    end
  else
    vim.notify("LLMancer: nvim-treesitter is recommended for syntax highlighting", vim.log.levels.WARN)
  end
end

-- Function to generate a unique chat ID
---@return string
local function generate_chat_id()
  return os.date("%Y%m%d_%H%M%S") .. "_" .. tostring(math.random(1000, 9999))
end

-- Function to open the chat buffer
---@param chat_id string|nil The ID of an existing chat to open
---@return number bufnr The buffer number of the created chat buffer
function M.open_chat(chat_id)
  local chat_name = chat_id and ("LLMancer_" .. chat_id) or (M.config.buffer_name .. "_" .. generate_chat_id())
  
  -- Check if buffer already exists
  local existing_bufnr = vim.fn.bufnr(chat_name)
  if existing_bufnr ~= -1 then
    -- Buffer exists, switch to it
    if M.config.open_mode == 'vsplit' then
      vim.cmd('vsplit')
    elseif M.config.open_mode == 'split' then
      vim.cmd('split')
    end
    vim.api.nvim_set_current_buf(existing_bufnr)
    return existing_bufnr
  end
  
  local bufnr = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(bufnr, chat_name)
  
  -- Open buffer according to config
  if M.config.open_mode == 'vsplit' then
    vim.cmd('vsplit')
  elseif M.config.open_mode == 'split' then
    vim.cmd('split')
  end
  
  vim.api.nvim_set_current_buf(bufnr)
  
  -- Set buffer options
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'llmancer'
  
  -- Enable treesitter highlighting for the buffer
  if pcall(require, "nvim-treesitter.configs") then
    vim.cmd([[TSBufEnable highlight]])
    -- Ensure markdown highlighting is enabled
    vim.cmd([[TSBufEnable indent]])
    -- Enable language injection
    pcall(vim.treesitter.start, bufnr, "markdown")
  end
  
  -- Add help text at the top
  local help_text = {
    "Welcome to LLMancer.nvim! 🤖",
    "Currently using: " .. M.config.model,
    "",
    "Shortcuts:",
    "- <Enter> in normal mode: Send message",
    "- gd: View conversation history",
    "- i or a: Enter insert mode to type",
    "- <Esc>: Return to normal mode",
    "",
    "Type your message below:",
    "----------------------------------------",
    "",
  }
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, help_text)
  
  -- Set up mappings for the chat buffer
  vim.api.nvim_buf_set_keymap(bufnr, 'n', '<CR>', 
    [[<cmd>lua require('llmancer.chat').send_message()<CR>]], 
    { noremap = true, silent = true })
  
  -- Add mapping for viewing conversation
  vim.api.nvim_buf_set_keymap(bufnr, 'n', 'gd',
    [[<cmd>lua require('llmancer.chat').view_conversation()<CR>]],
    { noremap = true, silent = true })
  
  -- If loading existing chat, restore its content
  if chat_id then
    require('llmancer.chat').load_chat(chat_id)
  end
  
  return bufnr
end

-- Function to list saved chats using fzf-lua
function M.list_chats()
  local fzf = require('fzf-lua')
  
  -- Get list of chat files
  local chat_files = vim.fn.glob(M.config.storage_dir .. "/*.json", false, true)
  local chats = {}
  
  -- Read metadata from each chat file
  for _, file in ipairs(chat_files) do
    local chat_id = vim.fn.fnamemodify(file, ':t:r')
    local content = vim.fn.readfile(file)
    if #content > 0 then
      local data = vim.fn.json_decode(content)
      -- Get first user message as preview
      local first_msg = ""
      for _, msg in ipairs(data) do
        if msg.role == "user" then
          first_msg = msg.content
          break
        end
      end
      table.insert(chats, {
        chat_id = chat_id,
        preview = first_msg,
        time = os.date("%Y-%m-%d %H:%M:%S", tonumber(chat_id:match("(%d+)")))
      })
    end
  end
  
  -- Show chats in fzf
  fzf.fzf_exec(
    vim.tbl_map(function(chat)
      return string.format("[%s] %s", chat.time, chat.preview:sub(1, 50))
    end, chats),
    {
      actions = {
        ['default'] = function(selected)
          local chat_id = chats[selected[1]:match("%[([^%]]+)%]")].chat_id
          M.open_chat(chat_id)
        end
      },
      prompt = "Select chat > ",
      winopts = {
        height = 0.6,
        width = 0.9,
      }
    }
  )
end

-- Add this near the top with other local functions
local function create_thinking_indicator(bufnr)
  local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local current_frame = 1
  local namespace = vim.api.nvim_create_namespace('llmancer_thinking')
  local timer = vim.loop.new_timer()
  
  -- Clear any existing virtual text in our namespace
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  
  -- Start animation
  timer:start(0, 80, vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      timer:stop()
      return
    end
    
    current_frame = (current_frame % #frames) + 1
    -- Get the last line number (will update if buffer changes)
    local last_line = vim.api.nvim_buf_line_count(bufnr) - 1
    
    -- Clear existing marks first
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
    
    -- Add new mark with both thinking text and spinner at the bottom
    vim.api.nvim_buf_set_extmark(bufnr, namespace, last_line, 0, {
      virt_text = {
        { "Assistant thinking... ", "Comment" },
        { frames[current_frame], "Special" }
      },
      virt_text_pos = "eol",
      priority = 100,
    })
  end))
  
  -- Return function to stop the animation
  return function()
    timer:stop()
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  end
end

-- Export the function
M.create_thinking_indicator = create_thinking_indicator

return M
