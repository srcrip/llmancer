---@class CustomModule
---@field config Config Current configuration
---@field setup fun(opts: Config|nil) Setup function
---@field open_chat fun() Function to open chat buffer
---@field list_chats fun() Function to list saved chats
local M = {}

-- Core configuration and utilities module
---@type Config
M.config = {
  open_mode = 'vsplit',
  buffer_name = 'LLMancer.nvim',
  anthropic_api_key = os.getenv("ANTHROPIC_API_KEY"),
  model = "claude-3-sonnet-20240229",
  max_tokens = 4096,
  temperature = 0.7,
  -- system_prompt = "You are a helpful AI assistant with expertise in programming and software development.",
  system_prompt = nil,
  storage_dir = vim.fn.stdpath("data") .. "/llmancer/chats",
  actions = {
    keymap = "<leader>a",
  },
}

-- Helper functions
-- Open buffer in appropriate split
---@param bufnr number Buffer number to open
local function open_buffer_split(bufnr)
  if M.config.open_mode == 'vsplit' then
    vim.cmd('vsplit')
  elseif M.config.open_mode == 'split' then
    vim.cmd('split')
  end
  vim.api.nvim_set_current_buf(bufnr)
end

-- Get existing or create new chat buffer
---@param chat_name string Name for the chat buffer
---@return number bufnr Buffer number
local function get_or_create_chat_buffer(chat_name)
  -- Generate the full file path
  local file_path = M.config.storage_dir .. '/' .. chat_name .. '.llmc'
  
  -- Check if buffer already exists for this file
  local existing_bufnr = vim.fn.bufnr(file_path)
  if existing_bufnr ~= -1 then
    open_buffer_split(existing_bufnr)
    return existing_bufnr
  end

  -- Create new buffer with the full file path
  local bufnr = vim.api.nvim_create_buf(true, false)  -- Listed buffer, not scratch
  vim.api.nvim_buf_set_name(bufnr, file_path)
  open_buffer_split(bufnr)
  return bufnr
end

-- Setup chat buffer options and features
---@param bufnr number Buffer number to setup
---@param target_bufnr number Target buffer number
local function setup_chat_buffer(bufnr, target_bufnr)
  -- Set buffer options
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'llmancer'

  -- Enable treesitter
  if pcall(require, "nvim-treesitter.configs") then
    vim.cmd([[TSBufEnable highlight]])
    vim.cmd([[TSBufEnable indent]])
    pcall(vim.treesitter.start, bufnr, "markdown")
  end

  local chat = require('llmancer.chat')
  chat.set_target_buffer(bufnr, target_bufnr)

  -- Add help text
  local help_text = chat.create_help_text(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, help_text)

  chat.setup_buffer_mappings(bufnr)
end

-- Generate unique chat ID
---@return string
local function generate_chat_id()
  return os.date("%Y%m%d_%H%M%S") .. "_" .. tostring(math.random(1000, 9999))
end

-- Ensure storage directory exists
local function ensure_storage_dir()
  vim.fn.mkdir(M.config.storage_dir, "p")
end

-- Setup treesitter configuration
local function setup_treesitter()
  local ok, ts_configs = pcall(require, "nvim-treesitter.configs")
  if not ok then
    vim.notify("LLMancer: nvim-treesitter is recommended for syntax highlighting", vim.log.levels.WARN)
    return
  end

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
end

-- Setup buffer-local keymapping for actions
local function setup_buffer_actions()
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "llmancer",
    callback = function(ev)
      vim.keymap.set("n", M.config.actions.keymap,
        function() require('llmancer.actions').show_actions() end,
        { buffer = ev.buf, desc = "Show LLMancer actions" })
    end
  })
end

-- Initialize plugin with user config
---@param opts Config|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  if not M.config.anthropic_api_key then
    vim.notify("LLMancer: No Anthropic API key found!", vim.log.levels.ERROR)
    return
  end

  ensure_storage_dir()
  setup_treesitter()
  setup_buffer_actions()

  -- Create global command for range-based plan creation
  vim.api.nvim_create_user_command('LLMancerPlan', function(opts)
    local start = opts.line1
    local end_line = opts.line2
    require('llmancer.chat').create_plan_from_range(start, end_line)
  end, { range = true, desc = "Create application plan from range" })
end

-- Create thinking indicator animation
---@param bufnr number Buffer number
---@return function stop_animation Function to stop the animation
function M.create_thinking_indicator(bufnr)
  local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local current_frame = 1
  local namespace = vim.api.nvim_create_namespace('llmancer_thinking')
  local timer = vim.loop.new_timer()
  local is_running = true
  local is_closing = false

  -- Clear namespace at start
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

  timer:start(0, 80, vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(bufnr) or not is_running then
      if not is_closing then
        is_closing = true
        timer:stop()
        timer:close()
        pcall(vim.api.nvim_buf_clear_namespace, bufnr, namespace, 0, -1)
      end
      return
    end

    current_frame = (current_frame % #frames) + 1
    local last_line = vim.api.nvim_buf_line_count(bufnr)
    if last_line > 0 then
      last_line = last_line - 1
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, namespace, 0, -1)
      pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, last_line, 0, {
        virt_text = {
          { "Assistant thinking... ", "Comment" },
          { frames[current_frame],    "Special" }
        },
        virt_text_pos = "eol",
        priority = 100,
      })
    end
  end))

  return function()
    if is_running and not is_closing then
      is_running = false
      is_closing = true
      if timer then
        timer:stop()
        timer:close()
      end
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          pcall(vim.api.nvim_buf_clear_namespace, bufnr, namespace, 0, -1)
        end
      end)
    end
  end
end

-- Open chat buffer
---@param chat_id string|nil The ID of an existing chat to open
---@return number bufnr The buffer number of the created chat buffer
function M.open_chat(chat_id)
  local target_bufnr = vim.api.nvim_get_current_buf()
  
  -- Generate chat ID if not provided
  chat_id = chat_id or generate_chat_id()
  
  -- Create buffer with the file path directly
  local bufnr = get_or_create_chat_buffer(chat_id)
  setup_chat_buffer(bufnr, target_bufnr)

  -- If this is an existing chat, load its content
  if vim.fn.filereadable(vim.api.nvim_buf_get_name(bufnr)) == 1 then
    require('llmancer.chat').load_chat(chat_id)
  end

  return bufnr
end

-- Function to list saved chats using fzf-lua
function M.list_chats()
  local fzf = require('fzf-lua')

  -- Get list of chat files
  local chat_files = vim.fn.glob(M.config.storage_dir .. "/*.llmc", false, true)
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
    local year = tonumber(date_str:sub(1, 4))
    local month = tonumber(date_str:sub(5, 6))
    local day = tonumber(date_str:sub(7, 8))
    local hour = tonumber(date_str:sub(10, 11))
    local min = tonumber(date_str:sub(12, 13))
    local sec = tonumber(date_str:sub(14, 15))

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
                -- Get current buffer as target buffer before opening chat
                local target_bufnr = vim.api.nvim_get_current_buf()
                local bufnr = M.open_chat(entry.chat_id)
                -- Ensure chat buffer is properly set up
                setup_chat_buffer(bufnr, target_bufnr)
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

-- Function to load a chat history
function M.load_chat()
  local chat_dir = vim.fn.stdpath("data") .. "/llmancer/chats"

  -- Ensure the directory exists
  vim.fn.mkdir(chat_dir, "p")

  local files = vim.fn.globpath(chat_dir, "*.llmc", false, true)
  if #files == 0 then
    vim.notify("No chat histories found", vim.log.levels.INFO)
    return
  end

  -- Format files for display
  local formatted_files = {}
  for _, file in ipairs(files) do
    -- Read first few lines of the file for preview
    local lines = vim.fn.readfile(file, "", 5)          -- Read up to 5 lines
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

-- Function to open chat selection menu
function M.open_chat_menu()
  local fzf = require('fzf-lua')
  local chat_dir = config.storage_dir

  -- Create directory if it doesn't exist
  vim.fn.mkdir(chat_dir, "p")

  -- List all .llmc files in the chat directory
  local find_command = string.format("find '%s' -name '*.llmc' -type f", chat_dir)
  local files = vim.fn.systemlist(find_command)

  -- Format the files for display
  local formatted_files = {}
  for _, file in ipairs(files) do
    local filename = vim.fn.fnamemodify(file, ':t:r')  -- Remove path and extension
    local timestamp = filename:match("^(%d+_%d+_%d+)") -- Extract timestamp
    if timestamp then
      -- Convert timestamp to readable format
      local year = timestamp:sub(1,4)
      local month = timestamp:sub(5,6)
      local day = timestamp:sub(7,8)
      local hour = timestamp:sub(10,11)
      local min = timestamp:sub(12,13)
      local sec = timestamp:sub(14,15)
      local readable = string.format("%s-%s-%s %s:%s:%s", year, month, day, hour, min, sec)
      table.insert(formatted_files, {
        display = readable,
        filename = filename,
        path = file
      })
    end
  end

  -- Sort files by timestamp (newest first)
  table.sort(formatted_files, function(a, b)
    return a.filename > b.filename
  end)

  -- Create display list and lookup table
  local display_list = {}
  local lookup = {}
  for _, item in ipairs(formatted_files) do
    table.insert(display_list, item.display)
    lookup[item.display] = item.filename
  end

  -- Show FZF picker
  fzf.fzf_exec(display_list, {
    prompt = "Select Chat > ",
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local filename = lookup[selected[1]]
          if filename then
            M.open_chat(filename)
          end
        end
      end
    }
  })
end

return M
