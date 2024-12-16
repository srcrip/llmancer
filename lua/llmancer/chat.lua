---@class ChatMessage
---@field content string The content of the message
---@field id number A unique identifier
---@field opts table Message options
---@field role "user"|"assistant"|"system" The role of the message sender
---@field message_number number|nil Message number for user messages

---@class ChatModule
---@field chat_history table<number, ChatMessage[]> Store chat history for each buffer
---@field send_message fun() Function to send message
---@field view_conversation fun() Function to view the conversation
---@field send_to_anthropic fun(message: Message[]) Function to send message to Anthropic
---@field target_buffers table<number, number> Map of chat bufnr to target bufnr
---@field build_system_prompt fun():string Function to build system prompt with current context
---@type table<number, plenary.Job> Map of buffer numbers to active jobs
local M = {}

local config = require('llmancer.config')
local main = require('llmancer.main')
local indicators = require('llmancer.indicators')

-- Store chat history for each buffer
---@type table<number, ChatMessage[]>
M.chat_history = {}

-- Store target buffers for each chat buffer
---@type table<number, number> Map of chat bufnr to target bufnr
M.target_buffers = {}

-- Add at the top with other module variables:
---@type table<number, plenary.Job> Map of buffer numbers to active jobs
M.active_jobs = {}

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
  -- Check if buffer is still valid
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

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

  -- Auto-scroll to the last line and center cursor
  -- todo: doesn't work
  -- vim.schedule(function()
  --   -- Only scroll if we're in the chat buffer
  --   if vim.api.nvim_get_current_buf() == bufnr then
  --     local win = vim.api.nvim_get_current_win()
  --     local new_last_line = vim.api.nvim_buf_line_count(bufnr)
  --     vim.api.nvim_win_set_cursor(win, { new_last_line, 0 })
  --     vim.cmd('normal! zz')
  --   end
  -- end)

  return true
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
    -- Check if buffer is still valid
    if not vim.api.nvim_buf_is_valid(bufnr) then
      -- Cancel the job if buffer is invalid
      if M.active_jobs[bufnr] then
        M.active_jobs[bufnr]:shutdown()
        M.active_jobs[bufnr] = nil
      end
      return
    end

    -- If this is the first chunk, add the model prefix and a newline
    if #accumulated_text == #new_text then
      vim.api.nvim_buf_set_lines(bufnr, -2, -1, false, { "" })
      local prefix = config.values.model .. ":"
      if new_text:sub(1, 3) == "```" then
        prefix = prefix .. "\n\n"
      else
        prefix = prefix .. " "
      end
      if not append_to_buffer_streaming(bufnr, prefix .. new_text) then
        return
      end
    else
      if not append_to_buffer_streaming(bufnr, new_text) then
        return
      end
    end

    -- If this is the last chunk (stop token received), store in chat history
    if content_delta.delta.stop_reason then
      -- Initialize history for this buffer if needed
      if not M.chat_history[bufnr] then
        M.chat_history[bufnr] = {}
      end

      -- Add the assistant response to chat history
      table.insert(M.chat_history[bufnr], {
        content = accumulated_text,
        id = M.generate_id(),
        opts = { visible = true },
        role = "assistant",
        message_number = message_number
      })
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

-- Simplify the prepare_messages_for_api function to just format messages without limits
---@param history ChatMessage[] The full chat history
---@return table[] messages Formatted messages for API
local function prepare_messages_for_api(history)
  local messages = {}

  -- Convert messages to API format
  for _, msg in ipairs(history) do
    if msg.role ~= "system" then
      table.insert(messages, {
        role = msg.role,
        content = msg.content
      })
    end
  end

  return messages
end

-- Update send_to_anthropic to handle auth errors
function M.send_to_anthropic(message)
  -- Check for API key before proceeding
  if not config.values.anthropic_api_key or config.values.anthropic_api_key == "" then
    vim.notify(
      "Anthropic API key not set. Please set ANTHROPIC_API_KEY environment variable or configure it in your setup.",
      vim.log.levels.ERROR
    )
    return nil
  end

  local Job = require('plenary.job')
  local bufnr = vim.api.nvim_get_current_buf()
  local config_table = get_buffer_config(bufnr)
  local params = config_table.params

  -- Cancel any existing job for this buffer
  if M.active_jobs[bufnr] then
    M.active_jobs[bufnr]:shutdown()
    M.active_jobs[bufnr] = nil
  end

  -- Build system prompt
  local system = M.build_system_prompt()

  -- Get conversation history and prepare messages
  local history = M.chat_history[bufnr] or {}
  local messages = prepare_messages_for_api(history)

  -- Add current message to messages array
  vim.list_extend(messages, message)

  -- Track the accumulated response
  local accumulated_text = ""
  local message_number = message[1] and message[1].message_number
  local had_error = false

  -- Prepare request body
  local body = vim.fn.json_encode({
    model = params.model,
    max_tokens = params.max_tokens,
    temperature = params.temperature,
    messages = messages,
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
      '-i', -- Include response headers
    },
    on_stdout = vim.schedule_wrap(function(_, chunk)
      if chunk then
        -- Check for HTTP status line
        local status = chunk:match("^HTTP/[%d.]+ (%d+)")
        if status then
          if status == "401" then
            had_error = true
            vim.notify(
              "Authentication failed. Please check your Anthropic API key.",
              vim.log.levels.ERROR
            )
            if M.active_jobs[bufnr] then
              M.active_jobs[bufnr]:shutdown()
              M.active_jobs[bufnr] = nil
            end
            return
          elseif status ~= "200" then
            had_error = true
            vim.notify(
              "API request failed with status " .. status,
              vim.log.levels.ERROR
            )
            if M.active_jobs[bufnr] then
              M.active_jobs[bufnr]:shutdown()
              M.active_jobs[bufnr] = nil
            end
            return
          end
        end
        -- Only process data if we haven't had an error
        if not had_error then
          accumulated_text = handle_stream_chunk(chunk, bufnr, message_number, accumulated_text)
        end
      end
    end),
    on_exit = vim.schedule_wrap(function(j, return_val)
      -- Remove job from active jobs
      if M.active_jobs[bufnr] == j then
        M.active_jobs[bufnr] = nil
      end

      if return_val == 0 and not had_error and vim.api.nvim_buf_is_valid(bufnr) then
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

  -- Store the job
  M.active_jobs[bufnr] = job
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

  -- First, find the separator line (the dashed line)
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
  local message_start = nil

  for i = #lines, separator_line, -1 do
    local line = lines[i]
    local user_num = line:match("^user %((%d+)%):")

    if user_num and not message_start then
      message_start = i
      message_number = tonumber(user_num)
      in_message = true
    elseif message_start and (line:match("^[^:]+:") or line:match("^%-%-%-")) then
      -- Get all lines between message_start and this line
      for j = i + 1, message_start do
        local msg_line = lines[j]
        if j == message_start then
          msg_line = msg_line:match("^user %([%d]+%):%s*(.*)$") or ""
        end
        table.insert(content, msg_line)
      end
      break
    elseif i == separator_line + 1 and message_start then
      for j = i, message_start do
        local msg_line = lines[j]
        if j == message_start then
          msg_line = msg_line:match("^user %([%d]+%):%s*(.*)$") or ""
        end
        table.insert(content, msg_line)
      end
      break
    end
  end

  -- If we haven't found a message yet, look for content after the separator
  if #content == 0 then
    local message_lines = {}
    local started_content = false
    local has_content = false -- Add flag to track if we found any non-empty content

    for i = separator_line + 1, #lines do
      local line = lines[i]

      -- Skip only specific prompts
      local is_user_prompt = line:match("^user %([%d]+%):%s*$") ~= nil
      local is_system_prompt = line:match("^(system|assistant|user):%s*$") ~= nil

      if not is_user_prompt and not is_system_prompt then
        -- If we find a non-empty line, mark that we've started content
        if line ~= "" then
          started_content = true
          has_content = true -- Set flag when we find non-empty content
        end

        -- Only add the line if we've started content
        if started_content then
          table.insert(message_lines, line)
        end
      end
    end

    -- Remove trailing empty lines
    while #message_lines > 0 and message_lines[#message_lines] == "" do
      table.remove(message_lines, #message_lines)
    end

    -- Only add to content if we found actual content
    if has_content then
      for _, line in ipairs(message_lines) do
        table.insert(content, line)
      end
      message_number = 1
    end
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
  -- Get the source chat buffer number BEFORE creating the history window
  local source_bufnr = vim.api.nvim_get_current_buf()

  local bufnr = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(bufnr, 'LLMancer-History')

  -- Create and open floating window with title
  local win_opts = create_floating_window(" Chat History ")

  vim.api.nvim_open_win(bufnr, true, win_opts)

  -- Setup buffer options and mappings
  setup_floating_buffer(bufnr, 'json')

  local history = M.chat_history[source_bufnr] or {}

  -- Convert history to string
  local content = vim.fn.json_encode(history)
  -- Pretty print the JSON with fallback if jq is not available
  local jq_result = vim.fn.system('which jq >/dev/null 2>&1 && echo ' ..
    vim.fn.shellescape(content) .. ' | jq . || echo ' .. vim.fn.shellescape(content))

  -- Set content
  local lines = vim.split(jq_result, '\n')
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

-- Modify create_params_text to include debugging:
function M.create_params_text()
  local chat_bufnr = vim.api.nvim_get_current_buf()

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

  -- Only add current file if in "current" mode
  if config.values.add_files_to_new_chat == "current" then
    local target_bufnr = vim.fn.bufnr('#')
    if target_bufnr ~= -1 and target_bufnr ~= chat_bufnr then
      local filename = vim.api.nvim_buf_get_name(target_bufnr)
      if filename ~= "" then
        params_table.context.files = { filename }
      end
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

-- Update the build_system_prompt function to NOT include files
function M.build_system_prompt()
  local chat_bufnr = vim.api.nvim_get_current_buf()
  local system_context = M.get_system_role()

  -- No longer need to add files to system prompt
  return system_context
end

-- Function to set target buffer for a chat buffer
---@param chat_bufnr number The chat buffer number
---@param target_bufnr number|nil The target buffer number (defaults to alternate buffer)
function M.set_target_buffer(chat_bufnr, target_bufnr)
  target_bufnr = target_bufnr or vim.fn.bufnr('#')

  -- vim.notify(string.format("Setting target buffer - Chat: %d, Target: %d", chat_bufnr, target_bufnr), vim.log.levels.DEBUG)

  if target_bufnr ~= -1 and vim.api.nvim_buf_is_valid(target_bufnr) then
    M.target_buffers[chat_bufnr] = target_bufnr
    -- vim.notify(string.format("Target buffer set successfully - Chat: %d, Target: %d", chat_bufnr, target_bufnr), vim.log.levels.DEBUG)
  else
    -- vim.notify(string.format("Failed to set target buffer - Chat: %d, Target: %d (invalid)", chat_bufnr, target_bufnr), vim.log.levels.WARN)
  end
end

function M.get_system_role()
  local module_path = debug.getinfo(1).source:sub(2) -- Remove @ from start
  local base_dir = vim.fn.fnamemodify(module_path, ':h:h:h')
  local system_prompt_path = base_dir .. '/prompts/system.xml'
  local system_content = nil

  if vim.fn.filereadable(system_prompt_path) == 1 then
    local system_prompt_lines = vim.fn.readfile(system_prompt_path)
    system_content = table.concat(system_prompt_lines, '\n')
  else
    -- vim.notify("System prompt not found", vim.log.levels.ERROR)
  end

  return system_content
end

-- Add this function to help with debugging target buffer setup
function M.debug_target_buffer_state()
  local bufnr = vim.api.nvim_get_current_buf()
  -- vim.notify(string.format("Debug target buffer state for chat buffer %d:", bufnr), vim.log.levels.DEBUG)
  -- vim.notify(string.format("Current alternate buffer: %d", vim.fn.bufnr('#')), vim.log.levels.DEBUG)
  -- vim.notify(string.format("Is current buffer valid: %s", tostring(vim.api.nvim_buf_is_valid(bufnr))), vim.log.levels.DEBUG)

  local target_bufnr = M.target_buffers[bufnr]
  if target_bufnr then
    -- vim.notify(string.format("Target buffer: %d", target_bufnr), vim.log.levels.DEBUG)
    -- vim.notify(string.format("Is target buffer valid: %s", tostring(vim.api.nvim_buf_is_valid(target_bufnr))), vim.log.levels.DEBUG)
  else
    vim.notify("No target buffer set", vim.log.levels.DEBUG)
  end
end

-- Update send_message to set target buffer if not already set
function M.send_message()
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()

  -- Set target buffer if not already set
  if not M.target_buffers[bufnr] then
    M.set_target_buffer(bufnr)
    M.debug_target_buffer_state() -- Add debugging info
  end

  -- Initialize history for this buffer if it doesn't exist
  if not M.chat_history[bufnr] then
    local system_content = M.get_system_role()

    M.chat_history[bufnr] = {
      {
        content = system_content,
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

  -- Get file contents from context
  local params = get_buffer_config(bufnr)
  local context_content = ""

  if params and params.context and params.context.files then
    for _, file in ipairs(params.context.files) do
      if type(file) == "string" and vim.fn.filereadable(file) == 1 then
        local file_content = table.concat(vim.fn.readfile(file), '\n')
        context_content = context_content .. string.format([[

<open_file>
```:%s
%s
```
</open_file>]], file, file_content)
      end
    end
  end

  -- Combine user message with context
  local full_content = content
  if context_content ~= "" then
    full_content = context_content .. "\n\n" .. content
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

  -- Auto-scroll to bottom
  vim.schedule(function()
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(bufnr), 0 })
    vim.cmd('normal! zz')
  end)

  -- Start thinking animation
  local stop_thinking = indicators.create_thinking_indicator(bufnr)

  -- Send to Anthropic asynchronously
  local job = M.send_to_anthropic(message)

  -- If job is nil (API key not set), clean up thinking indicator
  if not job then
    stop_thinking()
    -- Remove the blank lines we added
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, line_count - 2, line_count, false, {})
    return
  end

  -- Ensure cleanup happens even if job fails
  job:after(function()
    vim.schedule(function()
      stop_thinking()
    end)
  end)
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

  -- Update cleanup autocmds to use M.cleanup_buffer
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    buffer = bufnr,
    callback = function()
      require('llmancer.chat').cleanup_buffer(bufnr)
    end,
    once = true,
  })

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
  -- vim.notify(string.format("Current buffer (chat): %d", bufnr), vim.log.levels.DEBUG)

  -- Debug target buffers table
  -- vim.notify("Target buffers table:", vim.log.levels.DEBUG)
  -- for chat_buf, target_buf in pairs(M.target_buffers) do
  -- vim.notify(string.format("Chat buf: %d -> Target buf: %d", chat_buf, target_buf), vim.log.levels.DEBUG)
  -- end

  local target_bufnr = M.target_buffers[bufnr]
  -- vim.notify(string.format("Found target buffer: %s", tostring(target_bufnr)), vim.log.levels.DEBUG)

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

-- Add cleanup_buffer to the module instead of keeping it local
function M.cleanup_buffer(bufnr)
  vim.notify(string.format("Cleaning up buffer %d", bufnr), vim.log.levels.DEBUG)

  -- Cancel any active job
  if M.active_jobs[bufnr] then
    vim.notify(string.format("Cancelling active job for buffer %d", bufnr), vim.log.levels.DEBUG)
    M.active_jobs[bufnr]:shutdown()
    M.active_jobs[bufnr] = nil
  end

  -- Clean up chat history
  if M.chat_history[bufnr] then
    vim.notify(string.format("Cleaning chat history for buffer %d", bufnr), vim.log.levels.DEBUG)
    M.chat_history[bufnr] = nil
  end

  -- Clean up target buffers
  if M.target_buffers[bufnr] then
    vim.notify(string.format("Cleaning target buffer association for buffer %d", bufnr), vim.log.levels.DEBUG)
    M.target_buffers[bufnr] = nil
  end
end

return M
