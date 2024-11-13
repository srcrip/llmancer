---@class ChatMessage
---@field content string The content of the message
---@field id number A unique identifier
---@field opts table Message options
---@field role "user"|"llm"|"system" The role of the message sender
---@field message_number number|nil Message number for user messages

---@class ChatModule
---@field chat_history table<number, ChatMessage[]> Store chat history for each buffer
---@field send_message fun() Function to send message
---@field view_conversation fun() Function to view the conversation
---@field send_to_anthropic fun(message: Message[]) Function to send message to Anthropic
---@field target_buffers table<number, number> Map of chat bufnr to target bufnr
---@field build_system_prompt fun():string Function to build system prompt with current context
local M = {}

local config = require('llmancer.config')
local main = require('llmancer.main')

-- Store chat history for each buffer
---@type table<number, ChatMessage[]>
M.chat_history = {}

-- Store target buffers for each chat buffer
---@type table<number, number> Map of chat bufnr to target bufnr
M.target_buffers = {}

-- Function to generate a random ID
---@return number
function M.generate_id()
  return math.floor(math.random() * 2 ^ 32)
end

-- Parse parameters from the --- delimited section at the top of the buffer
---@param lines string[] The buffer lines to parse
---@return table|nil params The parsed parameters or nil if invalid
local function parse_param_section(lines)
  local in_params = false
  local params_text = {}

  for _, line in ipairs(lines) do
    if line == "---" then
      if not in_params then
        in_params = true
      else
        break
      end
    elseif in_params then
      table.insert(params_text, line)
    end
  end

  return params_text
end

-- Safely evaluate Lua code string and return result
---@param code_str string The Lua code to evaluate
---@return table|nil result The evaluated result or nil if error
---@return string|nil error The error message if evaluation failed
local function safe_eval_lua(code_str)
  local chunk, load_err = loadstring("return " .. code_str)
  if not chunk then
    return nil, "Failed to load Lua code: " .. (load_err or "unknown error")
  end

  local ok, result = pcall(chunk)
  if not ok then
    return nil, "Failed to execute Lua code: " .. tostring(result)
  end

  return result
end

-- Get configuration parameters from buffer
---@param bufnr number The buffer number
---@return table params The configuration parameters
local function get_buffer_config(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local params_text = parse_param_section(lines)

  if not params_text or #params_text == 0 then
    return {
      params = {
        model = config.values.model,
        max_tokens = config.values.max_tokens,
        temperature = config.values.temperature,
      },
      context = {
        files = {},
        global = {}
      }
    }
  end

  local params_str = table.concat(params_text, "\n")
  local result, err = safe_eval_lua(params_str)

  if err then
    vim.notify("Error parsing parameters: " .. err, vim.log.levels.WARN)
    return {
      params = {
        model = config.values.model,
        max_tokens = config.values.max_tokens,
        temperature = config.values.temperature,
      },
      context = {
        files = {},
        global = {}
      }
    }
  end

  -- Ensure required fields exist
  result.params = result.params or {
    model = config.values.model,
    max_tokens = config.values.max_tokens,
    temperature = config.values.temperature,
  }
  result.context = result.context or { files = {}, global = {} }

  return result
end

-- Append text to the buffer, handling newlines appropriately
---@param bufnr number The buffer number
---@param new_text string The text to append
local function append_to_buffer_streaming(bufnr, new_text)
  local last_line_idx = vim.api.nvim_buf_line_count(bufnr) - 1
  local last_line = vim.api.nvim_buf_get_lines(bufnr, last_line_idx, last_line_idx + 1, false)[1]

  -- Split the new text into lines
  local lines = vim.split(new_text, "\n", { plain = true })

  -- Update the last line with the first part
  vim.api.nvim_buf_set_lines(bufnr, last_line_idx, last_line_idx + 1, false,
    { last_line .. lines[1] })

  -- Add any additional lines
  if #lines > 1 then
    vim.api.nvim_buf_set_lines(bufnr, last_line_idx + 1, last_line_idx + 1, false,
      vim.list_slice(lines, 2))
  end
end

-- Handle a single chunk of streamed response
---@param chunk string The raw chunk from the API
---@param bufnr number The buffer number
---@param message_number number|nil The message number
---@param accumulated_text string The accumulated text so far
---@param callback function|nil The callback function
---@return string accumulated_text The updated accumulated text
local function handle_stream_chunk(chunk, bufnr, message_number, accumulated_text)
  -- Look for data: lines
  local data = chunk:match("^data: (.+)")
  if not data then return accumulated_text end

  local ok, content_delta = pcall(vim.fn.json_decode, data)
  if not ok or not content_delta or not content_delta.delta or not content_delta.delta.text then
    return accumulated_text
  end

  local new_text = content_delta.delta.text
  accumulated_text = accumulated_text .. new_text

  vim.schedule(function()
    -- If this is the first chunk, add the model prefix and a newline
    if #accumulated_text == #new_text then
      vim.api.nvim_buf_set_lines(bufnr, -2, -1, false, { "" })
      -- Format the prefix for the LLM response:
      -- For code blocks: "model_name:\n\n```..."
      -- For normal text: "model_name: text..."
      -- This ensures code blocks render properly with spacing
      local prefix = config.values.model .. ":"
      if new_text:sub(1, 3) == "```" then
        prefix = prefix .. "\n\n" -- Add two newlines before code blocks
      else
        prefix = prefix .. " "    -- Add single space for normal text
      end
      append_to_buffer_streaming(bufnr, prefix .. new_text)
    else
      append_to_buffer_streaming(bufnr, new_text)
    end
  end)

  return accumulated_text
end

-- Move save_chat to be part of the module instead of local
function M.save_chat(bufnr)
  local chat_name = vim.api.nvim_buf_get_name(bufnr)

  -- Extract just the filename without extension from the full path
  local chat_id = vim.fn.fnamemodify(chat_name, ':t:r')

  if not chat_id then
    vim.notify("Could not extract chat ID from buffer name: " .. chat_name, vim.log.levels.ERROR)
    return
  end

  -- Since we're already using the full path as the buffer name, we can just write to it directly
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local success = vim.fn.writefile(lines, chat_name)

  if success == 0 then
    vim.notify("Chat saved to " .. chat_name, vim.log.levels.DEBUG)
  else
    vim.notify("Failed to save chat to " .. chat_name, vim.log.levels.ERROR)
  end
end

-- Update the send_to_anthropic function to save chat after streaming completes
function M.send_to_anthropic(message)
  local Job = require('plenary.job')
  local bufnr = vim.api.nvim_get_current_buf()
  local config_table = get_buffer_config(bufnr)
  local params = config_table.params

  -- Build system prompt
  local system = M.build_system_prompt()

  -- Track the accumulated response
  local accumulated_text = ""
  local message_number = message[1] and message[1].message_number

  -- Prepare request body
  local body = vim.fn.json_encode({
    model = params.model,
    max_tokens = params.max_tokens,
    temperature = params.temperature,
    messages = message,
    system = system,
    stream = true,
  })

  local job = Job:new({
    command = 'curl',
    args = {
      'https://api.anthropic.com/v1/messages',
      '-X', 'POST',
      '-H', 'x-api-key: ' .. config.values.anthropic_api_key,
      '-H', 'anthropic-version: 2023-06-01',
      '-H', 'content-type: application/json',
      '-H', 'accept: text/event-stream',
      '-d', body,
      '--no-buffer',
    },
    on_stdout = vim.schedule_wrap(function(_, chunk)
      if chunk then
        accumulated_text = handle_stream_chunk(chunk, bufnr, message_number, accumulated_text)
      end
    end),
    on_exit = vim.schedule_wrap(function(j, return_val)
      if return_val == 0 then
        -- Add two blank lines and next user prompt after completion
        local next_prompt = string.format("user (%d): ", (message_number or 0) + 1)
        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "", "", next_prompt })

        -- Move cursor to the end
        local line_count = vim.api.nvim_buf_line_count(bufnr)
        vim.api.nvim_win_set_cursor(0, { line_count, #next_prompt })

        -- Save chat after successful completion
        M.save_chat(bufnr)
      end
    end),
  })

  job:start()
  return job
end

-- Function to get the latest user message from buffer
---@return string content The latest user message
---@return number|nil message_number The message number
local function get_latest_user_message()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = {}
  local message_number = nil
  local separator_line = nil

  -- First, find the separator line
  for i, line in ipairs(lines) do
    if line:match("^%-%-%-%-%-%-%-%-%-%-%-%-") then
      separator_line = i
      break
    end
  end

  if not separator_line then
    return "", nil
  end

  -- Find the last user message by scanning backwards from the end
  local in_message = false
  local last_user_num = nil

  -- Count total user messages to determine message number
  local user_message_count = 0
  for i = separator_line, #lines do
    if lines[i]:match("^user %((%d+)%)") then
      user_message_count = user_message_count + 1
    end
  end

  -- Scan backwards to find last message
  for i = #lines, separator_line, -1 do
    local line = lines[i]
    local user_num = line:match("^user %((%d+)%):")

    if user_num then
      -- Found a user message
      if not last_user_num then
        last_user_num = tonumber(user_num)
        message_number = user_message_count + 1
        in_message = true

        -- Add everything after the "user (N):" prefix
        local msg_content = line:match("^user %([%d]+%):%s*(.*)$")
        if msg_content and msg_content ~= "" then
          table.insert(content, 1, msg_content)
        end
      end
    elseif in_message then
      -- Stop if we hit another message
      if line:match("^[^:]+:") then
        break
      end
      -- Add the line to our message
      table.insert(content, 1, line)
    end
  end

  -- If we haven't found a message yet, look for content after the separator
  if #content == 0 then
    for i = separator_line + 1, #lines do
      local line = lines[i]
      -- Skip empty lines and prompts
      if line ~= "" and not line:match("^user %([%d]+%):%s*$") and not line:match("^[^:]+:") then
        table.insert(content, line)
      end
    end
    -- This is the first message
    message_number = 1
  end

  return table.concat(content, '\n'), message_number
end

-- Helper function to create floating window
local function create_floating_window(title)
  -- Get editor dimensions
  local width = vim.api.nvim_get_option("columns")
  local height = vim.api.nvim_get_option("lines")

  -- Calculate floating window size (80% of editor size)
  local win_height = math.ceil(height * 0.8)
  local win_width = math.ceil(width * 0.8)

  -- Calculate starting position
  local row = math.ceil((height - win_height) / 2)
  local col = math.ceil((width - win_width) / 2)

  -- Set window options
  local opts = {
    relative = 'editor',
    row = row,
    col = col,
    width = win_width,
    height = win_height,
    style = 'minimal',
    border = 'rounded',
    title = title,
    title_pos = 'center',
  }

  return opts
end

-- Helper function to setup floating buffer
local function setup_floating_buffer(bufnr, filetype)
  -- Set buffer options
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = filetype

  -- Add keymaps to close window
  vim.api.nvim_buf_set_keymap(bufnr, 'n', 'q',
    [[<cmd>lua vim.api.nvim_win_close(0, true)<CR>]],
    { noremap = true, silent = true })
  vim.api.nvim_buf_set_keymap(bufnr, 'n', '<Esc>',
    [[<cmd>lua vim.api.nvim_win_close(0, true)<CR>]],
    { noremap = true, silent = true })

  -- Add autocmd to properly clean up buffer when window is closed
  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = bufnr,
    callback = function()
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
      end)
    end,
    once = true,
  })
end

-- Function to view conversation
function M.view_conversation()
  local bufnr = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(bufnr, 'LLMancer-History')

  -- Create and open floating window with title
  local win_opts = create_floating_window(" Chat History ")

  vim.api.nvim_open_win(bufnr, true, win_opts)

  -- Setup buffer options and mappings
  setup_floating_buffer(bufnr, 'llmancer')

  -- Get current chat history
  local current_bufnr = vim.fn.bufnr(config.values.buffer_name)
  local history = M.chat_history[current_bufnr] or {}

  -- Convert history to string
  local content = vim.fn.json_encode(history)
  -- Pretty print the JSON with fallback if jq is not available
  local jq_result = vim.fn.system('which jq >/dev/null 2>&1 && echo ' ..
    vim.fn.shellescape(content) .. ' | jq . || echo ' .. vim.fn.shellescape(content))

  -- Set content
  local lines = vim.split(jq_result, '\n')
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

-- Change from local function to M.create_params_text
function M.create_params_text()
  local chat_bufnr = vim.api.nvim_get_current_buf()
  local target_bufnr = M.target_buffers[chat_bufnr]

  local params_table = {
    params = {
      model = config.values.model,
      max_tokens = config.values.max_tokens,
      temperature = config.values.temperature,
    },
    context = {
      files = {},
      global = {}
    }
  }

  -- Add target file to context.files if it exists
  if target_bufnr and vim.api.nvim_buf_is_valid(target_bufnr) then
    local filename = vim.api.nvim_buf_get_name(target_bufnr)
    if filename ~= "" then
      params_table.context.files = { filename }
    end
  end

  -- Convert the table to a string and split it into lines
  local params_str = vim.inspect(params_table)
  local params_lines = vim.split(params_str, '\n')

  -- Return array with separator lines and params lines
  local result = { "---" }
  vim.list_extend(result, params_lines)
  table.insert(result, "---")

  return result
end

local system_role = [[
Act as an expert software developer. Follow best practices and conventions:

- Write clean, maintainable code
- Use the users languages, frameworks, and libraries
- Follow project patterns and style
- Handle errors properly
- Prefer modular and reusable code

You are part of a system for suggesting code changes to a developer.

This developer is an expert and doesn't need long explanations.

Prefer to provide concise information and requested code changes.

You should return code blocks like markdown style, fenced with ``` and include a syntax name like:

```javascript
function add(a, b) {
  return a + b;
}
```

]]

-- Update the build_system_prompt function to use the context
function M.build_system_prompt()
  local chat_bufnr = vim.api.nvim_get_current_buf()
  local system_context = config.values.system_prompt or system_role

  -- Get the params table from the buffer
  local params = get_buffer_config(chat_bufnr)
  if not params or not params.context then return system_context end

  -- Helper function to add file content to context
  local function add_file_to_context(filepath)
    if vim.fn.filereadable(filepath) == 1 then
      local content = table.concat(vim.fn.readfile(filepath), '\n')
      system_context = string.format([[%s

File: %s
Content:
%s]], system_context, filepath, content)
    end
  end

  -- Add context for each file
  for _, file in ipairs(params.context) do
    -- Handle special case for codebase() function
    if type(file) == "function" then
      local success, files = pcall(file)
      if success and type(files) == "table" then
        for _, f in ipairs(files) do
          add_file_to_context(f)
        end
      end
    else
      -- Handle regular file paths
      add_file_to_context(file)
    end
  end

  return system_context
end

-- Function to set target buffer for a chat buffer
---@param chat_bufnr number The chat buffer number
---@param target_bufnr number|nil The target buffer number (defaults to alternate buffer)
function M.set_target_buffer(chat_bufnr, target_bufnr)
  target_bufnr = target_bufnr or vim.fn.bufnr('#')

  if target_bufnr ~= -1 and vim.api.nvim_buf_is_valid(target_bufnr) then
    M.target_buffers[chat_bufnr] = target_bufnr
  end
end

-- Update send_message to use the new function
function M.send_message()
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()

  -- Initialize history for this buffer if it doesn't exist
  if not M.chat_history[bufnr] then
    M.chat_history[bufnr] = {
      {
        content = M.build_system_prompt(),
        id = M.generate_id(),
        opts = { visible = false },
        role = "system"
      }
    }
  end

  -- Get latest user message
  local ok, content, message_number = pcall(get_latest_user_message)
  if not ok then
    vim.notify("Error getting user message: " .. tostring(content), vim.log.levels.ERROR)
    return
  end

  -- Skip if content is empty
  if vim.trim(content) == "" then
    return
  end

  -- If no message number found, this is the first message
  if not message_number then
    message_number = 1
  end

  -- Get params and build context from files
  local params = get_buffer_config(bufnr)
  local context_content = {}

  if params and params.context and params.context.files then
    for _, file in ipairs(params.context.files) do
      if vim.fn.filereadable(file) == 1 then
        local file_content = table.concat(vim.fn.readfile(file), '\n')
        table.insert(context_content, string.format("File: %s\n\n%s", file, file_content))
      end
    end
  end

  -- Combine context and user message
  local full_content
  if #context_content > 0 then
    full_content = "---\n" .. table.concat(context_content, "\n\n") .. "\n---\n\n" .. content
  else
    full_content = content
  end

  -- Add user message to history
  table.insert(M.chat_history[bufnr], {
    content = full_content,
    id = M.generate_id(),
    opts = { visible = true },
    role = "user",
    message_number = message_number
  })

  -- Prepare message format for API
  ---@type Message[]
  local message = {
    {
      role = "user",
      content = full_content
    }
  }

  -- Add blank lines before sending request to position the thinking indicator
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "", "" })

  -- todo: add a config option to disable this
  -- Auto-scroll to bottom
  vim.schedule(function()
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(bufnr), 0 })
    vim.cmd('normal! zz')
  end)

  -- Start thinking animation
  local stop_thinking = main.create_thinking_indicator(bufnr)

  -- Send to Anthropic asynchronously
  local job = M.send_to_anthropic(message)

  -- Ensure cleanup happens even if job fails
  if job then
    job:after(function()
      vim.schedule(function()
        stop_thinking()
      end)
    end)
  end
end

-- Update the create_help_text function to use M.create_params_text
local function create_help_text(chat_bufnr)
  -- Combine params and help text
  local text = M.create_params_text()
  vim.list_extend(text, {
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
  })
  return text
end

-- Function to show system prompt in new buffer
local function show_system_prompt()
  local bufnr = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(bufnr, 'LLMancer-SystemPrompt')

  -- Create and open floating window with title
  local win_opts = create_floating_window(" System Prompt ")

  vim.api.nvim_open_win(bufnr, true, win_opts)

  -- Setup buffer options and mappings
  setup_floating_buffer(bufnr, 'markdown')

  -- Get system prompt
  local system_prompt = M.build_system_prompt()

  -- Set content
  local lines = vim.split(system_prompt, '\n')
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

-- Add the keymap in both open_chat and load_chat functions
local function setup_buffer_mappings(bufnr)
  -- Existing mappings...
  vim.api.nvim_buf_set_keymap(bufnr, 'n', '<CR>',
    [[<cmd>lua require('llmancer.chat').send_message()<CR>]],
    { noremap = true, silent = true })

  vim.api.nvim_buf_set_keymap(bufnr, 'n', 'gd',
    [[<cmd>lua require('llmancer.chat').view_conversation()<CR>]],
    { noremap = true, silent = true })

  -- Add new mapping for system prompt
  vim.api.nvim_buf_set_keymap(bufnr, 'n', 'gs',
    [[<cmd>lua require('llmancer.chat').show_system_prompt()<CR>]],
    { noremap = true, silent = true, desc = "Show system prompt" })

  vim.api.nvim_buf_set_keymap(bufnr, 'n', 'ga',
    [[<cmd>lua require('llmancer.chat').create_plan_from_last_response()<CR>]],
    { noremap = true, silent = true, desc = "Create plan from last response" })

  -- Add the range command
  vim.api.nvim_buf_create_user_command(bufnr, 'LLMancerPlan', function(opts)
    local start = opts.line1
    local end_line = opts.line2
    require('llmancer.chat').create_plan_from_range(start, end_line)
  end, { range = true, desc = "Create application plan from range" })
end

-- Function to get text from range
---@param start number Starting line number (1-based)
---@param end_line number Ending line number (1-based)
---@return string content The text content from the range
local function get_range_content(start, end_line)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, start - 1, end_line, false)
  return table.concat(lines, '\n')
end

-- Function to get the last LLM response
---@return string|nil content The content of the last LLM response
---@return number|nil start_line The starting line of the response
---@return number|nil end_line The ending line of the response
local function get_last_llm_response()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local start_line, end_line

  -- Find the last model response by scanning backwards
  for i = #lines, 1, -1 do
    local line = lines[i]
    -- Look for the model prefix followed by a colon and optional space
    if line:match("^" .. vim.pesc(config.values.model) .. ":%s*") then
      start_line = i
      -- Find the end of this response (next user prompt or EOF)
      end_line = #lines -- Default to end of buffer
      for j = i + 1, #lines do
        if lines[j]:match("^user %(%d+%)") then
          end_line = j - 1
          break
        end
      end
      break
    end
  end

  if start_line and end_line then
    local content = table.concat(vim.list_slice(lines, start_line, end_line), '\n')
    -- Remove the model prefix from the first line
    content = content:gsub("^" .. vim.pesc(config.values.model) .. ":%s*", "")
    return content, start_line, end_line
  end

  return nil
end

-- Function to create application plan from range
---@param start number Starting line number (1-based)
---@param end_line number Ending line number (1-based)
function M.create_plan_from_range(start, end_line)
  local content = get_range_content(start, end_line)
  local bufnr = vim.api.nvim_get_current_buf()
  local target_bufnr = M.target_buffers[bufnr]

  if not target_bufnr then
    vim.notify("No target buffer associated with this chat", vim.log.levels.ERROR)
    return
  end

  -- Create plan using the existing function
  local app_plan = require('llmancer.application_plan')
  app_plan.create_plan(
    { content },
    { target_bufnr }
  )
end

-- Function to create application plan from last response
function M.create_plan_from_last_response()
  local content = get_last_llm_response()
  if not content then
    vim.notify("No LLM response found", vim.log.levels.ERROR)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local target_bufnr = M.target_buffers[bufnr]

  if not target_bufnr then
    vim.notify("No target buffer associated with this chat", vim.log.levels.ERROR)
    return
  end

  -- Create plan using the existing function
  local app_plan = require('llmancer.application_plan')
  app_plan.create_plan(
    { content },
    { target_bufnr }
  )
end

-- Update load_chat function to use config.values
function M.load_chat(chat_id, target_bufnr)
  -- Ensure config is initialized with defaults if not already set
  if not config.values then
    config.setup()
  end

  local file_path = config.values.storage_dir .. '/' .. chat_id .. '.llmc'
  -- Check if file exists
  if vim.fn.filereadable(file_path) ~= 1 then
    vim.notify("Cannot read file: " .. file_path, vim.log.levels.ERROR)
    return nil
  end

  -- Create new buffer for chat
  local bufnr = vim.api.nvim_create_buf(true, true)

  -- Set buffer name (this will trigger filetype detection)
  pcall(vim.api.nvim_buf_set_name, bufnr, file_path)

  -- Load content from file
  local lines = vim.fn.readfile(file_path)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  -- Set target buffer if provided
  if target_bufnr then
    M.set_target_buffer(bufnr, target_bufnr)
  end

  -- Move cursor to end of buffer
  vim.schedule(function()
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_win_set_cursor(0, { line_count, 0 })
  end)

  return bufnr
end

-- Export the functions
M.show_system_prompt = show_system_prompt
M.setup_buffer_mappings = setup_buffer_mappings

-- Export the function for use in main.lua
M.create_help_text = create_help_text

return M
