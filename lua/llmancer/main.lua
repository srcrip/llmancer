local M = {}

-- At the top of the file, add:
local utils = require "llmancer.utils"
local config = require "llmancer.config"
local indicators = require "llmancer.indicators"
local inline_edit = require "llmancer.inline_edit"
local SECTION_SEPARATOR = "---"

-- At the top with other helper functions, before M.setup
local function save_chat_state(bufnr)
  if vim.bo[bufnr].filetype == "llmancer" then
    vim.g.llmancer_last_chat = {
      bufnr = bufnr,
      chat_id = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t:r"),
      win_id = vim.fn.win_getid(),
    }
  end
end

-- Add with other helper functions
local function move_cursor_to_end(bufnr)
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      vim.api.nvim_win_set_cursor(0, { line_count, 0 })
    end
  end)
end

-- Helper functions
-- Open buffer in appropriate split
---@param bufnr number Buffer number to open
local function open_buffer_split(bufnr)
  utils.open_split()
  vim.api.nvim_set_current_buf(bufnr)
end

-- Get existing or create new chat buffer
---@param chat_name string Name for the chat buffer
---@return number bufnr Buffer number
local function get_or_create_chat_buffer(chat_name)
  -- Generate the full file path
  local file_path = config.values.storage_dir .. "/" .. chat_name .. ".llmc"

  -- Check if buffer already exists for this file
  local existing_bufnr = vim.fn.bufnr(file_path)

  if existing_bufnr ~= -1 then
    open_buffer_split(existing_bufnr)
    return existing_bufnr
  end

  -- Create new buffer with the full file path
  local bufnr = vim.api.nvim_create_buf(true, false) -- Listed buffer, not scratch
  vim.api.nvim_buf_set_name(bufnr, file_path)

  open_buffer_split(bufnr)
  return bufnr
end

-- Generate unique chat ID
---@return string
local function generate_chat_id()
  return os.date "%Y%m%d_%H%M%S" .. "_" .. tostring(math.random(1000, 9999))
end

-- Ensure storage directory exists
local function ensure_storage_dir()
  vim.fn.mkdir(config.values.storage_dir, "p")
end

-- Setup treesitter configuration
local function setup_treesitter()
  local ok, ts_configs = pcall(require, "nvim-treesitter.configs")
  if not ok then
    vim.notify(
      "LLMancer: nvim-treesitter is recommended for syntax highlighting. Please install at least 'markdown', 'markdown_inline', 'lua', and any other grammars you want syntax highlighting for in the chat buffer.",
      vim.log.levels.WARN
    )
    return
  end

  -- todo: perhaps add a config to auto install these?
  -- local parsers = { "markdown", "markdown_inline", "lua" }

  -- todo: also maybe we can detect that those grammars are missing and prompt the user to install them?

  ts_configs.setup {
    -- ensure_installed = parsers,
    highlight = {
      enable = true,
      additional_vim_regex_highlighting = { "markdown", "llmancer" },
    },
  }

  -- Install missing parsers
  -- local ts_parsers = require("nvim-treesitter.parsers")
  -- for _, lang in ipairs(parsers) do
  --   if not ts_parsers.has_parser(lang) then
  --     vim.cmd("TSInstall " .. lang)
  --   end
  -- end
end

-- Setup buffer-local keymapping for actions
local function setup_buffer_actions()
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "llmancer",
    callback = function(ev)
      -- Set up the actions keymap if actions module exists
      local ok, actions = pcall(require, "llmancer.actions")
      if ok then
        local keymap = config.values.actions and config.values.actions.keymap or "<leader>a"
        vim.keymap.set("n", keymap, function()
          actions.show_actions()
        end, { buffer = ev.buf, desc = "Show LLMancer actions" })
      end

      -- Only set up the WinClosed autocmd if the config option is enabled
      if config.values.close_chat_buffer_on_win_closed then
        vim.api.nvim_create_autocmd("WinClosed", {
          buffer = ev.buf,
          callback = function()
            -- Add a delay to prevent immediate cleanup
            vim.defer_fn(function()
              -- Only clean up if the buffer isn't visible in any window
              if vim.api.nvim_buf_is_valid(ev.buf) and vim.fn.bufwinid(ev.buf) == -1 then
                vim.api.nvim_buf_delete(ev.buf, { force = true })
              end
            end, 100)
          end,
          once = true,
        })
      end
    end,
  })
end

-- Initialize plugin with user config
---@param opts Config|nil
function M.setup(opts)
  local err = config.setup(opts)

  if err then
    vim.notify("LLMancer: " .. err, vim.log.levels.ERROR)
    return
  end

  ensure_storage_dir()
  setup_treesitter()
  setup_buffer_actions()

  -- Register plugin commands
  vim.api.nvim_create_user_command("LLMToggle", function()
    local current_buf = vim.api.nvim_get_current_buf()
    local is_llmancer = vim.bo[current_buf].filetype == "llmancer"

    if is_llmancer then
      vim.cmd "close"
    else
      local last_chat = vim.g.llmancer_last_chat

      if last_chat and last_chat.chat_id then
        local chat_file = config.values.storage_dir .. "/" .. last_chat.chat_id .. ".llmc"
        local file_exists = vim.fn.filereadable(chat_file) == 1

        if file_exists then
          M.open_chat(last_chat.chat_id)
        else
          M.open_chat()
        end
      else
        M.open_chat()
      end
    end
  end, { desc = "Toggle LLMancer chat window" })

  vim.api.nvim_create_user_command("LLMOpen", function()
    M.open_chat()
  end, { desc = "Open new LLMancer chat" })

  vim.api.nvim_create_user_command("LLMHistory", function()
    M.list_chats()
  end, { desc = "Show LLMancer chat history" })

  -- Create global command for range-based plan creation
  vim.api.nvim_create_user_command("LLMPlan", function(command_opts)
    local start = command_opts.line1
    local end_line = command_opts.line2
    require("llmancer.chat").create_plan_from_range(start, end_line)
  end, { range = true, desc = "Create application plan from range" })

  -- Create augroup for all LLMancer autocommands
  local group = vim.api.nvim_create_augroup("LLMancerSetup", { clear = true })

  -- Setup autocommands for llmancer filetype
  -- todo: this should probably go into the ftdetect section
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "llmancer",
    group = group,
    callback = function(ev)
      local bufnr = ev.buf
      local chat = require "llmancer.chat"

      -- Set buffer options
      vim.bo[bufnr].bufhidden = "hide"
      vim.bo[bufnr].swapfile = false
      vim.bo[bufnr].textwidth = 0

      -- Save state for this buffer
      save_chat_state(bufnr)

      -- Enable treesitter if available
      if pcall(require, "nvim-treesitter.configs") then
        vim.schedule(function()
          vim.cmd [[TSBufEnable highlight]]
          vim.cmd [[TSBufEnable indent]]
          pcall(vim.treesitter.start, bufnr, "markdown")
        end)
      end

      -- Setup buffer mappings
      chat.setup_buffer_mappings(bufnr)

      -- Check if this is a new buffer or existing file
      local is_new_buffer = vim.fn.filereadable(vim.api.nvim_buf_get_name(bufnr)) == 0

      -- Initialize new buffers with params and help text
      if is_new_buffer then
        -- Create params text first
        local params_text = chat.create_params_text()

        -- Then add help text
        local help_text = {
          "",
          "Welcome to LLMancer.nvim! 🤖",
          "",
          "Shortcuts:",
          "- <Enter> in normal mode: Send message",
          "- gd: View conversation history",
          "- gs: View system prompt",
          "- ga: Create application plan from last response",
          "",
          "Type your message below:",
          "----------------------------------------",
          "",
        }

        -- Combine params and help text
        vim.list_extend(params_text, help_text)

        -- Set the buffer content
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, params_text)

        -- Only set target buffer after params are created, and only if we're in "current" mode
        if config.values.add_files_to_new_chat == "current" then
          local target_bufnr = vim.fn.bufnr "#"
          if target_bufnr ~= -1 and target_bufnr ~= bufnr then
            chat.set_target_buffer(bufnr, target_bufnr)
          end
        end
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
      save_chat_state(ev.buf)
    end,
  })
end

-- Buffer management functions
local function create_chat_buffer(chat_id)
  local file_path = config.values.storage_dir .. "/" .. chat_id .. ".llmc"

  -- Check if buffer already exists
  local existing_bufnr = vim.fn.bufnr(file_path)
  if existing_bufnr ~= -1 then
    utils.open_split()
    vim.api.nvim_set_current_buf(existing_bufnr)
    -- Move cursor to end of buffer
    vim.schedule(function()
      local line_count = vim.api.nvim_buf_line_count(existing_bufnr)
      vim.api.nvim_win_set_cursor(0, { line_count, 0 })
    end)
    return existing_bufnr
  end

  -- Create new buffer
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, file_path)
  utils.open_split()
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

-- Content management functions
local function load_chat_content(bufnr)
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  if vim.fn.filereadable(file_path) == 1 then
    local lines = vim.fn.readfile(file_path)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    -- Move cursor to end of buffer
    vim.schedule(function()
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      vim.api.nvim_win_set_cursor(0, { line_count, 0 })
    end)
    return true
  end
  return false
end

local function collect_open_files()
  local open_files = {}
  if config.values.add_files_to_new_chat == "all" then
    local all_bufs = vim.api.nvim_list_bufs()
    for _, buf in ipairs(all_bufs) do
      local filename = vim.api.nvim_buf_get_name(buf)
      -- Filter out .llmc files and ensure file is listed
      if filename ~= "" and vim.fn.buflisted(buf) == 1 and not filename:match "%.llmc$" then
        table.insert(open_files, filename)
      end
    end
  end
  return open_files
end

-- Main interface functions
function M.open_chat(chat_id)
  chat_id = chat_id or generate_chat_id()
  local bufnr = create_chat_buffer(chat_id)

  if not load_chat_content(bufnr) then
    local open_files = collect_open_files()
    local chat = require "llmancer.chat"

    -- Create params text with open files in context
    local params = {
      params = {
        model = config.values.model,
        max_tokens = config.values.max_tokens,
        temperature = config.values.temperature,
      },
      context = {
        files = open_files, -- Add the open files to context
        global = {},
      },
    }

    -- Convert params to string and split into lines
    local params_text = {
      SECTION_SEPARATOR,
    }
    -- Split the inspected params into lines and add them
    for line in vim.inspect(params):gmatch "[^\r\n]+" do
      table.insert(params_text, line)
    end
    table.insert(params_text, SECTION_SEPARATOR)

    -- Then add help text
    local help_text = {
      "",
      "Welcome to LLMancer.nvim! 🤖",
      "",
      "Shortcuts:",
      "- <Enter> in normal mode: Send message",
      "- gd: View conversation history",
      "- gs: View system prompt",
      "- ga: Create application plan from last response",
      "",
      "Type your message below:",
      "----------------------------------------",
      "",
    }

    -- Combine params and help text
    vim.list_extend(params_text, help_text)

    -- Set the buffer content
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, params_text)

    -- Move cursor to end of buffer
    vim.schedule(function()
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      vim.api.nvim_win_set_cursor(0, { line_count, 0 })
    end)

    -- Only set target buffer if we're in "current" mode
    if config.values.add_files_to_new_chat == "current" then
      local target_bufnr = vim.fn.bufnr "#"
      if target_bufnr ~= -1 and target_bufnr ~= bufnr then
        chat.set_target_buffer(bufnr, target_bufnr)
      end
    end
  end

  return bufnr
end

-- Function to list saved chats using fzf-lua
function M.list_chats()
  local fzf = require "fzf-lua"

  -- Get list of chat files
  local chat_files = vim.fn.glob(config.values.storage_dir .. "/*.llmc", false, true)
  if #chat_files == 0 then
    vim.notify("No saved chats found", vim.log.levels.INFO)
    return
  end

  -- Read preview from each chat file
  local chats = vim.tbl_map(function(file)
    local chat_id = vim.fn.fnamemodify(file, ":t:r")
    local lines = vim.fn.readfile(file, "", 50)
    local preview = ""

    -- Find first user message after help text
    local found_separator = false
    for _, line in ipairs(lines) do
      if not found_separator and line:match "^%-%-%-%-%-%-%-%-%-%-%-%-" then
        found_separator = true
      elseif found_separator and line ~= "" then
        preview = line
        break
      end
    end

    -- Use utils functions for timestamp handling
    local timestamp = utils.parse_chat_id(chat_id)
    if not timestamp then
      return nil
    end

    return {
      chat_id = chat_id,
      preview = preview,
      time = utils.format_timestamp(timestamp),
    }
  end, chat_files)

  -- Filter out any nil entries and sort by time
  chats = vim.tbl_filter(function(chat)
    return chat ~= nil
  end, chats)
  table.sort(chats, function(a, b)
    return a.time > b.time
  end)

  -- Format entries for fzf
  local entries = vim.tbl_map(function(chat)
    local preview_text = chat.preview:sub(1, 100)
    if #chat.preview > 100 then
      preview_text = preview_text .. "..."
    end
    return {
      display = string.format("[%s] %s", chat.time, preview_text),
      chat_id = chat.chat_id,
    }
  end, chats)

  -- Show chats in fzf
  fzf.fzf_exec(
    vim.tbl_map(function(entry)
      return entry.display
    end, entries),
    {
      actions = {
        ["default"] = function(selected)
          if selected and selected[1] then
            for _, entry in ipairs(entries) do
              if entry.display == selected[1] then
                -- Get current buffer as target buffer before opening chat
                local target_bufnr = vim.api.nvim_get_current_buf()

                -- Create split first
                if config.values.open_mode == "vsplit" then
                  vim.cmd "vsplit"
                elseif config.values.open_mode == "split" then
                  vim.cmd "split"
                end

                -- Load the chat (filetype handler will do the setup)
                local chat = require "llmancer.chat"
                local bufnr = chat.load_chat(entry.chat_id, target_bufnr)
                if bufnr then
                  vim.api.nvim_set_current_buf(bufnr)
                end
                break
              end
            end
          end
        end,
      },
      prompt = "Select chat > ",
      winopts = {
        height = 0.6,
        width = 0.9,
      },
    }
  )
end

---Start inline editing for the current visual selection
function M.edit_selection()
  inline_edit.start_edit()
end

-- Function to load a chat history
function M.load_chat()
  local chat_dir = config.values.storage_dir

  local files = vim.fn.globpath(chat_dir, "*.llmc", false, true)
  if #files == 0 then
    vim.notify("No chat histories found", vim.log.levels.INFO)
    return
  end

  -- Format files for display
  local formatted_files = {}
  for _, file in ipairs(files) do
    -- Read first few lines of the file for preview
    local lines = vim.fn.readfile(file, "", 5) -- Read up to 5 lines
    local preview = table.concat(lines, " "):sub(1, 50) -- First 50 chars
    local display_name = vim.fn.fnamemodify(file, ":t:r")
    table.insert(formatted_files, {
      string.format("[%s] %s...", display_name, preview),
      file,
    })
  end

  -- Show file picker
  require("fzf-lua").fzf_exec(
    vim.tbl_map(function(entry)
      return entry[1]
    end, formatted_files),
    {
      prompt = "Select Chat History > ",
      actions = {
        ["default"] = function(selected)
          if not selected or #selected == 0 then
            return
          end
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
        end,
      },
    }
  )
end

return M
