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
local M = {}

local config = require('llmancer.main').config
local main = require('llmancer.main')

-- Store chat history for each buffer
---@type table<number, ChatMessage[]>
M.chat_history = {}

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

-- Function to send message to Anthropic with retries
---@param message Message[] The message to send
---@param callback fun(response: table|nil) Callback function to handle the response
function M.send_to_anthropic(message, callback)
  local curl = require('plenary.curl')
  local config = require('llmancer.main').config

  curl.post('https://api.anthropic.com/v1/messages', {
    headers = {
      ['x-api-key'] = config.anthropic_api_key,
      ['anthropic-version'] = '2023-06-01',
      ['content-type'] = 'application/json',
    },
    body = vim.fn.json_encode({
      model = config.model,
      max_tokens = config.max_tokens,
      messages = message,
      temperature = config.temperature,
      system = config.system_prompt,
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
local function get_latest_user_message()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Skip the help text (first 12 lines)
  local start_line = 12
  local content = {}
  local collecting = false

  -- Find the last "user (n):" line
  local last_user_line = -1
  for i = start_line, #lines do
    if lines[i]:match("^user %([%d]+%): ") then
      last_user_line = i
    end
  end

  -- If we found a user line, collect everything after it until the next prefix
  if last_user_line > -1 then
    for i = last_user_line + 1, #lines do
      local line = lines[i]
      -- Stop if we hit another prefix or empty line
      if line:match("^[^:]+: ") or line == "" then
        break
      end
      table.insert(content, line)
    end
  end

  return table.concat(content, '\n')
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

-- Function to save chat history
local function save_chat()
  local bufnr = vim.api.nvim_get_current_buf()
  local chat_name = vim.api.nvim_buf_get_name(bufnr)
  local chat_id = chat_name:match("LLMancer_(.+)$") or chat_name:match("LLMancer%.nvim_(.+)$")

  if chat_id and M.chat_history[bufnr] then
    local file_path = config.storage_dir .. "/" .. chat_id .. ".json"
    -- Debug print
    vim.notify("Saving chat to: " .. file_path)

    local file = io.open(file_path, "w")
    if file then
      local json_str = vim.fn.json_encode(M.chat_history[bufnr])
      file:write(json_str)
      file:close()
      vim.notify("Chat saved successfully")
    else
      vim.notify("Failed to open file for writing: " .. file_path, vim.log.levels.ERROR)
    end
  else
    vim.notify("Could not determine chat ID from buffer name: " .. chat_name, vim.log.levels.ERROR)
  end
end

-- Function to send message (called when pressing Enter)
function M.send_message()
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()

  -- Get current window view
  local current_line = vim.api.nvim_win_get_cursor(win)[1]
  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local window_height = vim.api.nvim_win_get_height(win)
  local topline = vim.fn.line('w0')

  -- Check if we're near the bottom (within last screen of text)
  local is_near_bottom = (total_lines - current_line) < window_height

  -- Initialize history for this buffer if it doesn't exist
  if not M.chat_history[bufnr] then
    M.chat_history[bufnr] = {
      {
        content = config.system_prompt,
        id = generate_id(),
        opts = { visible = false },
        role = "system"
      }
    }
  end

  -- Count existing user messages
  local user_count = 0
  for _, msg in ipairs(M.chat_history[bufnr]) do
    if msg.role == "user" then
      user_count = user_count + 1
    end
  end
  user_count = user_count + 1 -- Increment for new message

  -- Get only the latest user message
  local content = get_latest_user_message()
  if content == "" then
    -- For the first message, get everything after the help text
    local lines = vim.api.nvim_buf_get_lines(bufnr, 12, -1, false)
    content = table.concat(lines, '\n')
  end

  -- Skip if content is empty
  if vim.trim(content) == "" then
    return
  end

  -- Add user message to history
  table.insert(M.chat_history[bufnr], {
    content = content,
    id = generate_id(),
    opts = { visible = true },
    role = "user",
    message_number = user_count
  })

  -- Prepare message format for API
  ---@type Message[]
  local message = {
    {
      role = "user",
      content = content
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
      local next_prompt = string.format("user (%d): ", user_count + 1)
      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "", next_prompt })

      -- Move cursor to the end of the prompt line and ensure it's visible
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      vim.api.nvim_win_set_cursor(win, { line_count, #next_prompt })
      if is_near_bottom then
        -- vim.cmd('normal! zz')
      end

      save_chat()
    end

    -- Stop thinking animation
    stop_thinking()
  end)
end

-- Function to load chat history
---@param chat_id string The ID of the chat to load
function M.load_chat(chat_id)
  local file_path = config.storage_dir .. "/" .. chat_id .. ".json"
  local file = io.open(file_path, "r")
  if file then
    local content = file:read("*all")
    file:close()

    local bufnr = vim.api.nvim_get_current_buf()
    M.chat_history[bufnr] = vim.fn.json_decode(content)

    -- Reconstruct the chat in the buffer
    local lines = {}
    for _, msg in ipairs(M.chat_history[bufnr]) do
      if msg.role == "user" then
        table.insert(lines, "")
        table.insert(lines, string.format("user (%d): %s", msg.message_number, msg.content))
      elseif msg.role == "llm" then
        table.insert(lines, "")
        table.insert(lines, config.model .. ": " .. msg.content)
      end
    end

    -- Add the next user prompt
    local user_count = 0
    for _, msg in ipairs(M.chat_history[bufnr]) do
      if msg.role == "user" then
        user_count = user_count + 1
      end
    end
    table.insert(lines, "")
    table.insert(lines, string.format("user (%d): ", user_count + 1))

    -- Append lines after the help text
    vim.api.nvim_buf_set_lines(bufnr, 12, -1, false, lines)
  end
end

return M
