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
  -- Actions configuration
  actions = {
    -- Key mapping to trigger actions picker
    keymap = "<leader>a",
  },
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

  -- Set up buffer-local keymapping for actions
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "llmancer",
    callback = function(ev)
      vim.keymap.set("n", M.config.actions.keymap,
        function() require('llmancer.actions').show_actions() end,
        { buffer = ev.buf, desc = "Show LLMancer actions" })
    end
  })
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
  -- Store the current buffer as it will become the alternate buffer
  local target_bufnr = vim.api.nvim_get_current_buf()
  
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
  
  -- After creating the chat buffer, set its target buffer
  local chat = require('llmancer.chat')
  chat.set_target_buffer(bufnr, target_bufnr)
  
  -- Add help text at the top using the new function
  local help_text = chat.create_help_text(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, help_text)
  
  -- Set up buffer mappings
  require('llmancer.chat').setup_buffer_mappings(bufnr)
  
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
    local chat_files = vim.fn.glob(M.config.storage_dir .. "/*.txt", false, true)
    if #chat_files == 0 then
        vim.notify("No saved chats found", vim.log.levels.INFO)
        return
    end
    
    -- Read preview from each chat file
    local chats = vim.tbl_map(function(file)
        local chat_id = vim.fn.fnamemodify(file, ':t:r')
        local lines = vim.fn.readfile(file, '', 50)
        local preview = ""
        
        -- Find first user message after help text
        local found_separator = false
        for _, line in ipairs(lines) do
            if not found_separator and line:match("^%-%-%-%-%-%-%-%-%-%-%-%-") then
                found_separator = true
            elseif found_separator and line ~= "" then
                preview = line
                break
            end
        end
        
        -- Extract timestamp from chat_id (format: YYYYMMDD_HHMMSS_XXXX)
        local date_str = chat_id:match("^(%d%d%d%d%d%d%d%d_%d%d%d%d%d%d)_")
        if not date_str then return nil end
        
        -- Parse the timestamp (YYYYMMDD_HHMMSS)
        local year = tonumber(date_str:sub(1,4))
        local month = tonumber(date_str:sub(5,6))
        local day = tonumber(date_str:sub(7,8))
        local hour = tonumber(date_str:sub(10,11))
        local min = tonumber(date_str:sub(12,13))
        local sec = tonumber(date_str:sub(14,15))
        
        -- Create timestamp using os.time
        local timestamp = os.time({
            year = year,
            month = month,
            day = day,
            hour = hour,
            min = min,
            sec = sec
        })
        
        return {
            chat_id = chat_id,
            preview = preview,
            time = os.date("%Y-%m-%d %H:%M:%S", timestamp)
        }
    end, chat_files)
    
    -- Filter out any nil entries and sort by time
    chats = vim.tbl_filter(function(chat) return chat ~= nil end, chats)
    table.sort(chats, function(a, b) return a.time > b.time end)
    
    -- Format entries for fzf
    local entries = vim.tbl_map(function(chat)
        local preview_text = chat.preview:sub(1, 100)
        if #chat.preview > 100 then
            preview_text = preview_text .. "..."
        end
        return {
            display = string.format("[%s] %s", chat.time, preview_text),
            chat_id = chat.chat_id
        }
    end, chats)
    
    -- Show chats in fzf
    fzf.fzf_exec(
        vim.tbl_map(function(entry) return entry.display end, entries),
        {
            actions = {
                ['default'] = function(selected)
                    if selected and selected[1] then
                        for _, entry in ipairs(entries) do
                            if entry.display == selected[1] then
                                M.open_chat(entry.chat_id)
                                break
                            end
                        end
                    end
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

-- Function to load a chat history
function M.load_chat()
    local chat_dir = vim.fn.stdpath("data") .. "/llmancer/chats"
    
    -- Ensure the directory exists
    vim.fn.mkdir(chat_dir, "p")

    -- Get list of chat files (now looking for .txt instead of .json)
    local files = vim.fn.globpath(chat_dir, "*.txt", false, true)
    if #files == 0 then
        vim.notify("No chat histories found", vim.log.levels.INFO)
        return
    end

    -- Format files for display
    local formatted_files = {}
    for _, file in ipairs(files) do
        -- Read first few lines of the file for preview
        local lines = vim.fn.readfile(file, "", 5)  -- Read up to 5 lines
        local preview = table.concat(lines, " "):sub(1, 50) -- First 50 chars
        local display_name = vim.fn.fnamemodify(file, ":t:r")
        table.insert(formatted_files, {
            string.format("[%s] %s...", display_name, preview),
            file
        })
    end

    -- Show file picker
    require('fzf-lua').fzf_exec(
        vim.tbl_map(function(entry) return entry[1] end, formatted_files),
        {
            prompt = "Select Chat History > ",
            actions = {
                ['default'] = function(selected)
                    if not selected or #selected == 0 then return end
                    local idx = 1
                    for i, entry in ipairs(formatted_files) do
                        if entry[1] == selected[1] then
                            idx = i
                            break
                        end
                    end
                    local filename = formatted_files[idx][2]
                    
                    -- Create new chat buffer
                    local chat_id = vim.fn.fnamemodify(filename, ":t:r")
                    local bufnr = M.open_chat(chat_id)
                    
                    -- Read and display the chat content
                    local content = vim.fn.readfile(filename)
                    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
                end
            }
        }
    )
end

return M
