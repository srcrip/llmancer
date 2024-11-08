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
---@field send_to_anthropic fun(message: Message[], callback: fun(response: table|nil)) Function to send message to Anthropic
---@field target_buffers table<number, number> Map of chat bufnr to target bufnr
---@field build_system_prompt fun():string Function to build system prompt with current context
local M = {}

local config = require('llmancer.main').config
local main = require('llmancer.main')

-- Store chat history for each buffer
---@type table<number, ChatMessage[]>
M.chat_history = {}

-- Store target buffers for each chat buffer
---@type table<number, number> Map of chat bufnr to target bufnr
M.target_buffers = {}

-- Function to generate a random ID
---@return number
local function generate_id()
  return math.floor(math.random() * 2 ^ 32)
end

-- Function to make API request with retry
---@param max_retries number Maximum number of retry attempts
---@param initial_delay number Initial delay in seconds
---@param request_fn fun():table|nil Function that makes the request
---@return table|nil response The API response or nil if all retries fail
local function with_retry(max_retries, initial_delay, request_fn)
  local delay = initial_delay

  for attempt = 1, max_retries do
    local response = request_fn()
    if response then
      return response
    end

    if attempt < max_retries then
      vim.notify(string.format("Retrying in %d seconds (attempt %d/%d)...",
        delay, attempt, max_retries), vim.log.levels.WARN)
      vim.cmd('sleep ' .. delay * 1000 .. 'm')
      delay = delay * 2 -- Exponential backoff
    else
      vim.notify('Failed after ' .. max_retries .. ' attempts', vim.log.levels.ERROR)
    end
  end

  return nil
end

-- Update the parse_params_from_buffer function
local function parse_params_from_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
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

  -- Try to load the params as Lua code
  local params_str = table.concat(params_text, "\n")
  local chunk, err = loadstring("return " .. params_str)
  if chunk then
    local success, result = pcall(chunk)
    if success then
      -- Return the entire table instead of just params field
      return result
    end
  end
  return nil
end

-- Update the send_to_anthropic function to handle the new structure
function M.send_to_anthropic(message, callback)
  local curl = require('plenary.curl')

  -- Get current params from buffer
  local bufnr = vim.api.nvim_get_current_buf()
  local config_table = parse_params_from_buffer(bufnr)
  local params = (config_table and config_table.params) or {
    model = config.model,
    max_tokens = config.max_tokens,
    temperature = config.temperature,
  }

  -- Build system prompt
  local system = M.build_system_prompt()

  curl.post('https://api.anthropic.com/v1/messages', {
    headers = {
      ['x-api-key'] = config.anthropic_api_key,
      ['anthropic-version'] = '2023-06-01',
      ['content-type'] = 'application/json',
    },
    body = vim.fn.json_encode({
      model = params.model,
      max_tokens = params.max_tokens,
      temperature = params.temperature,
      messages = message,
      system = system,
    }),
    callback = vim.schedule_wrap(function(response)
      if response.status == 200 then
        callback(vim.fn.json_decode(response.body))
      else
        local error_data = vim.fn.json_decode(response.body)
        if error_data and error_data.error and error_data.error.type == "overloaded_error" then
          callback(nil) -- Signal retry needed
        else
          vim.notify('Error from Anthropic API: ' .. response.body, vim.log.levels.ERROR)
          callback(false) -- Signal permanent failure
        end
      end
    end)
  })
end

-- Function to get buffer content as message
---@return string content The buffer content
local function get_buffer_content()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, '\n')
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

  -- Find the last user message
  local in_message = false
  for i = #lines, separator_line, -1 do
    local line = lines[i]

    -- Check for user message start
    local user_num = line:match("^user %((%d+)%):")
    if user_num then
      message_number = tonumber(user_num)
      -- Skip empty prompts
      if not line:match("^user %([%d]+%):%s*$") then
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
  end

  -- For debugging
  vim.notify("Content: " .. vim.inspect(content))
  vim.notify("Message number: " .. (message_number or "nil"))

  return table.concat(content, '\n'), message_number
end

-- Function to append response to buffer
---@param text string The text to append
---@param message_type "user"|"llm" The type of message
---@param message_number number|nil The message number (for user messages)
local function append_to_buffer(text, message_type, message_number)
  local bufnr = vim.api.nvim_get_current_buf()
  local prefix = ""

  if message_type == "user" then
    prefix = string.format("user (%d): ", message_number)
  elseif message_type == "llm" then
    prefix = config.model .. ": "
  end

  local lines = vim.split(prefix .. text, '\n')
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
end

-- Function to view conversation
function M.view_conversation()
  local bufnr = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(bufnr, 'LLMancer-History')

  -- Open in a new buffer
  vim.cmd('enew')
  vim.api.nvim_set_current_buf(bufnr)

  -- Set buffer options
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'llmancer'

  -- Get current chat history
  local current_bufnr = vim.fn.bufnr(config.buffer_name)
  local history = M.chat_history[current_bufnr] or {}

  -- Convert history to string
  local content = vim.fn.json_encode(history)
  -- Pretty print the JSON
  content = vim.fn.system('echo ' .. vim.fn.shellescape(content) .. ' | jq .')

  -- Set content
  local lines = vim.split(content, '\n')
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

-- Update the save_chat function to be more robust
local function save_chat(bufnr)
  local chat_name = vim.api.nvim_buf_get_name(bufnr)
  local chat_id = chat_name:match("LLMancer_(.+)$") or chat_name:match("LLMancer%.nvim_(.+)$")

  if not chat_id then
    vim.notify("Could not extract chat ID from buffer name: " .. chat_name, vim.log.levels.DEBUG)
    return
  end

  -- Ensure storage directory exists
  local storage_dir = config.storage_dir
  vim.fn.mkdir(storage_dir, "p")

  local filename = storage_dir .. "/" .. chat_id .. ".txt"

  -- Get all lines from buffer
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Write to file
  local success = vim.fn.writefile(lines, filename)
  if success == 0 then
    vim.notify("Chat saved to " .. filename, vim.log.levels.DEBUG)
  else
    vim.notify("Failed to save chat to " .. filename, vim.log.levels.ERROR)
  end
end

-- Update the create_params_text function
local function create_params_text()
  local chat_bufnr = vim.api.nvim_get_current_buf()
  local target_bufnr = M.target_buffers[chat_bufnr]

  local params_table = {
    params = {
      model = config.model,
      max_tokens = config.max_tokens,
      temperature = config.temperature,
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

This developer is an export and doesn't need long explanations.

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
  local system_context = config.system_prompt or system_role

  -- Get the params table from the buffer
  local params = parse_params_from_buffer(chat_bufnr)
  if not params or not params.context then return system_context end

  -- Add context for each file
  for _, file in ipairs(params.context) do
    -- Handle special case for codebase() function
    if type(file) == "function" then
      local success, files = pcall(file)
      if success and type(files) == "table" then
        for _, f in ipairs(files) do
          if vim.fn.filereadable(f) == 1 then
            local content = table.concat(vim.fn.readfile(f), '\n')
            system_context = string.format([[%s

File: %s
Content:
%s]], system_context, f, content)
          end
        end
      end
    else
      -- Handle regular file paths
      if vim.fn.filereadable(file) == 1 then
        local content = table.concat(vim.fn.readfile(file), '\n')
        system_context = string.format([[%s

File: %s
Content:
%s]], system_context, file, content)
      end
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

-- Update the get_file_context function to handle the new structure
---@return string
local function get_file_context()
  local chat_bufnr = vim.api.nvim_get_current_buf()
  local context_lines = {}

  -- Get params from buffer to check context configuration
  local params = parse_params_from_buffer(chat_bufnr)
  if params and params.context then
    -- Handle files context
    if params.context.files then
      for _, file in ipairs(params.context.files) do
        if vim.fn.filereadable(file) == 1 then
          local content = table.concat(vim.fn.readfile(file), '\n')
          table.insert(context_lines, string.format("File: %s\n%s", file, content))
        end
      end
    end

    -- Handle global context
    if params.context.global then
      for _, item in ipairs(params.context.global) do
        if type(item) == "function" then
          local success, files = pcall(item)
          if success and type(files) == "table" then
            for _, f in ipairs(files) do
              if vim.fn.filereadable(f) == 1 then
                local content = table.concat(vim.fn.readfile(f), '\n')
                table.insert(context_lines, string.format("File: %s\n%s", f, content))
              end
            end
          end
        end
      end
    end
  end

  -- If we have context, format it with separators
  if #context_lines > 0 then
    return "---\n" .. table.concat(context_lines, "\n\n") .. "\n---\n\n"
  end

  return ""
end

-- Function to send message (called when pressing Enter)
function M.send_message()
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()

  -- Initialize history for this buffer if it doesn't exist
  if not M.chat_history[bufnr] then
    M.chat_history[bufnr] = {
      {
        content = M.build_system_prompt(),
        id = generate_id(),
        opts = { visible = false },
        role = "system"
      }
    }
  end

  -- Get latest user message
  local content, message_number = get_latest_user_message()

  -- Skip if content is empty
  if vim.trim(content) == "" then
    return
  end

  -- If no message number found, this is the first message
  if not message_number then
    message_number = 1
  else
    message_number = message_number + 1
  end

  -- Get params and build context from files
  local params = parse_params_from_buffer(bufnr)
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
    id = generate_id(),
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

  -- Auto-scroll if we were near the bottom
  if is_near_bottom then
    vim.schedule(function()
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(bufnr), 0 })
      vim.cmd('normal! zz')
    end)
  end

  -- Start thinking animation
  local stop_thinking = main.create_thinking_indicator(bufnr)

  -- Send to Anthropic asynchronously
  M.send_to_anthropic(message, function(response)
    if response and response.content and response.content[1] then
      local response_text = response.content[1].text

      -- Add newline before code block if response starts with ```
      if response_text:match("^```") then
        response_text = "\n" .. response_text
      end

      -- Add response to history
      table.insert(M.chat_history[bufnr], {
        content = response_text,
        id = generate_id(),
        opts = { visible = true },
        role = "llm"
      })

      -- Replace the blank lines with response
      local last_line = vim.api.nvim_buf_line_count(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, last_line - 2, last_line, false, { "" }) -- Remove extra blank line
      append_to_buffer(response_text, "llm")

      -- Add a new blank line and prompt for the next user message
      local next_prompt = string.format("user (%d): ", message_number + 1)
      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "", next_prompt })

      -- Move cursor to the end of the prompt line and ensure it's visible
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      vim.api.nvim_win_set_cursor(win, { line_count, #next_prompt })

      -- Save chat after successful response
      vim.schedule(function()
        save_chat(bufnr)
      end)
    end

    -- Stop thinking animation
    stop_thinking()
  end)
end

-- Update the create_help_text function to remove both lines
local function create_help_text(chat_bufnr)
  -- Combine params and help text
  local text = create_params_text()
  vim.list_extend(text, {
    "",
    "Welcome to LLMancer.nvim! 🤖",
    "",
    "Shortcuts:",
    "- <Enter> in normal mode: Send message",
    "- gd: View conversation history",
    "- gs: View system prompt",
    "- i or a: Enter insert mode to type",
    "- <Esc>: Return to normal mode",
    "",
    "Type your message below:",
    "----------------------------------------",
    "",
  })
  return text
end

-- Update the help_text variable to match
local help_text = {
  "Welcome to LLMancer.nvim! 🤖",
  "",
  "Shortcuts:",
  "- <Enter> in normal mode: Send message",
  "- gd: View conversation history",
  "- gs: View system prompt",
  "- i or a: Enter insert mode to type",
  "- <Esc>: Return to normal mode",
  "",
  "Type your message below:",
  "----------------------------------------",
  "",
}

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
end

-- Export the function
M.show_system_prompt = show_system_prompt
M.setup_buffer_mappings = setup_buffer_mappings

-- Export the function for use in main.lua
M.create_help_text = create_help_text

return M
