---@class ChatMessage
---@field content string The content of the message
---@field id number A unique identifier
---@field opts table Message options
---@field role "user"|"assistant"|"system" The role of the message sender

---@class ChatModule
---@field send_message fun() Function to send message
---@field view_conversation fun() Function to view the conversation
---@field send_to_anthropic fun(message: Message[]) Function to send message to Anthropic
---@field target_buffers table<number, number> Map of chat bufnr to target bufnr
---@field build_system_prompt fun():string Function to build system prompt with current context
---@type table<number, plenary.Job> Map of buffer numbers to active jobs
---@type table<number, boolean> Map of buffer numbers to response waiting state
local M = {}

local config = require('llmancer.config')
local main = require('llmancer.main')
local indicators = require('llmancer.indicators')
local parser = require('llmancer.chat.parser')

-- Module state
M.target_buffers = {} ---@type table<number, number>
M.active_jobs = {} ---@type table<number, plenary.Job>
M.is_waiting_response = {} ---@type table<number, boolean>

-- Add these constants at the top of the file
local SECTION_SEPARATOR = "---"
local CHAT_SEPARATOR = "----------------------------------------"

-- At the top with other helper functions, after the constants
-- Parse the chat buffer into a sequence of messages
---@param bufnr number The buffer number to parse
---@return table[] messages Array of message objects {role, content}
local function parse_chat_buffer(bufnr)
  return parser.parse_buffer(bufnr)
end

-- Helper functions
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

-- Context management functions
---@param bufnr number The buffer number
---@return table|nil context The parsed context or nil if invalid
local function load_buffer_context(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local in_params = false
  local params_lines = {}

  for i, line in ipairs(lines) do
    if line == SECTION_SEPARATOR then
      if not in_params then
        in_params = true
      else
        break
      end
    elseif in_params and line ~= "" then -- Skip empty lines in params section
      table.insert(params_lines, line)
    end
  end

  if #params_lines == 0 then
    return nil
  end

  local params_str = table.concat(params_lines, "\n")
  local result, err = safe_eval_lua(params_str)
  if err then
    vim.notify("Error parsing params: " .. err, vim.log.levels.WARN)
    return nil
  end

  return result
end

---@param bufnr number The buffer number
---@param context table The context to write
local function write_buffer_context(bufnr, context)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local start_idx = nil
  local end_idx = nil

  -- Find the params section
  for i, line in ipairs(lines) do
    if line == SECTION_SEPARATOR then
      if not start_idx then
        start_idx = i
      else
        end_idx = i
        break
      end
    end
  end

  if not start_idx or not end_idx then
    vim.notify("Could not find params section in buffer", vim.log.levels.ERROR)
    return false
  end

  -- Convert context to lines
  local context_str = vim.inspect(context)
  local context_lines = vim.split(context_str, '\n')

  -- Build new lines array
  local new_lines = {}

  -- Add everything before params
  vim.list_extend(new_lines, vim.list_slice(lines, 1, start_idx))

  -- Add params
  vim.list_extend(new_lines, context_lines)

  -- Add everything after params
  vim.list_extend(new_lines, vim.list_slice(lines, end_idx, #lines))

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)

  return true
end

-- Then the toggle function that depends on both of those
function M.toggle_file_in_context(filename)
  local bufnr = vim.api.nvim_get_current_buf()

  -- Check if we're in a chat buffer
  if vim.bo.filetype ~= "llmancer" then
    vim.notify("This command must be run from a chat buffer", vim.log.levels.ERROR)
    return
  end

  -- Load current context
  local context = load_buffer_context(bufnr)
  if not context then
    vim.notify("Could not load context from buffer", vim.log.levels.ERROR)
    return
  end

  -- Initialize files array if it doesn't exist
  context.context = context.context or {}
  context.context.files = context.context.files or {}

  -- Check if file is already in context
  local found = false
  for i, file in ipairs(context.context.files) do
    if file == filename then
      -- Remove the file
      table.remove(context.context.files, i)
      found = true
      vim.notify("Removed " .. filename .. " from context", vim.log.levels.INFO)
      break
    end
  end

  -- Add file if it wasn't found
  if not found then
    table.insert(context.context.files, filename)
    vim.notify("Added " .. filename .. " to context", vim.log.levels.INFO)
  end

  -- Write context back to buffer
  if not write_buffer_context(bufnr, context) then
    vim.notify("Failed to update context in buffer", vim.log.levels.ERROR)
    return
  end
end

-- Function to generate a random ID
---@return number
function M.generate_id()
  return math.floor(math.random() * 2 ^ 32)
end

-- Get configuration parameters from buffer
---@param bufnr number The buffer number
---@return table params The configuration parameters
local function get_buffer_config(bufnr)
  local context = load_buffer_context(bufnr)

  if not context then
    vim.notify("Using default config due to missing context", vim.log.levels.DEBUG)
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
  context.params = context.params or {
    model = config.values.model,
    max_tokens = config.values.max_tokens,
    temperature = config.values.temperature,
  }
  context.context = context.context or { files = {}, global = {} }

  return context
end

-- Append text to the buffer, handling newlines appropriately
---@param bufnr number The buffer number
---@param new_text string The text to append
local function append_to_buffer_streaming(bufnr, new_text)
  -- Check if buffer is still valid and modifiable
  if not vim.api.nvim_buf_is_valid(bufnr) or
      not vim.api.nvim_buf_get_option(bufnr, 'modifiable') then
    return false
  end

  local last_line_idx = vim.api.nvim_buf_line_count(bufnr) - 1
  
  -- Additional validation before getting last line
  if last_line_idx < 0 then
    return false
  end

  -- Safely get last line with pcall
  local ok, last_line = pcall(vim.api.nvim_buf_get_lines, bufnr, last_line_idx, last_line_idx + 1, false)
  if not ok or not last_line or #last_line == 0 then
    return false
  end
  last_line = last_line[1]

  -- Split the new text into lines
  local lines = vim.split(new_text, "\n", { plain = true })

  -- Safely update the last line
  ok = pcall(vim.api.nvim_buf_set_lines, bufnr, last_line_idx, last_line_idx + 1, false,
    { last_line .. lines[1] })
  if not ok then
    return false
  end

  -- Add any additional lines
  if #lines > 1 then
    ok = pcall(vim.api.nvim_buf_set_lines, bufnr, last_line_idx + 1, last_line_idx + 1, false,
      vim.list_slice(lines, 2))
    if not ok then
      return false
    end
  end

  return true
end

-- Handle a single chunk of streamed response
---@param chunk string The raw chunk from the API
---@param bufnr number The buffer number
---@param accumulated_text string The accumulated text so far
---@param callback function|nil The callback function
---@return string accumulated_text The updated accumulated text
local function handle_stream_chunk(chunk, bufnr, accumulated_text)
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
      -- Safely add new lines
      local ok = pcall(vim.api.nvim_buf_set_lines, bufnr, -2, -1, false, { "" })
      if not ok then return end
      
      local prefix = "assistant:"
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

    -- If this is the last chunk, store in chat history
    if content_delta.delta.stop_reason then
      -- Only proceed if buffer is still valid
      if vim.api.nvim_buf_is_valid(bufnr) then
        add_next_prompt(bufnr)
        M.save_chat(bufnr)
      end
    end
  end)

  return accumulated_text
end

-- Move save_chat to be part of the module instead of local
function M.save_chat(bufnr)
  local chat_name = vim.api.nvim_buf_get_name(bufnr)

  if chat_name == "" then
    vim.notify("Buffer has no name", vim.log.levels.ERROR)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local success = vim.fn.writefile(lines, chat_name)

  if success ~= 0 then
    vim.notify("Failed to save chat to " .. chat_name, vim.log.levels.ERROR)
  end
end

-- Add helper function for adding next prompt (near other helper functions)
local function add_next_prompt(bufnr)
  local next_prompt = "user: "
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "", "", next_prompt })

  -- Move cursor to the end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_win_set_cursor(0, { line_count, #next_prompt })
end

-- Update send_to_anthropic to add debug logging
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

  -- Parse chat history from buffer
  local messages = parse_chat_buffer(bufnr)

  -- Check if the current message is already in history
  local new_message = message[1]
  local is_duplicate = false

  -- Check the last message in history
  if #messages > 0 and messages[#messages].role == new_message.role then
    if messages[#messages].content == new_message.content then
      is_duplicate = true
    end
  end

  -- Only add the message if it's not a duplicate
  if not is_duplicate then
    if #message == 1 then
      table.insert(messages, message[1])
    else
      vim.notify("Warning: Multiple messages in current message array", vim.log.levels.WARN)
      table.insert(messages, message[1])
    end
  end

  -- Track the accumulated response
  local accumulated_text = ""
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

  local debug = false
  if debug then
    local module_path = debug.getinfo(1).source:sub(2)
    local base_dir = vim.fn.fnamemodify(module_path, ':h:h:h')
    local debug_file = base_dir .. '/debug_log.txt'

    local f = io.open(debug_file, "a")
    if f then
      f:write(string.format("\n\n=== Request %s ===\n%s\n", os.date("%Y-%m-%d %H:%M:%S"), body))
      f:close()
    end
  end

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
            -- Log the full response for debugging
            vim.notify(
              "API request failed with status " .. status .. "\nResponse: " .. chunk,
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
          accumulated_text = handle_stream_chunk(chunk, bufnr, accumulated_text)
        end
      end
    end),
    on_exit = vim.schedule_wrap(function(j, return_val)
      -- Remove job from active jobs
      if M.active_jobs[bufnr] == j then
        M.active_jobs[bufnr] = nil
      end

      if return_val == 0 and not had_error and vim.api.nvim_buf_is_valid(bufnr) then
        add_next_prompt(bufnr)
        M.save_chat(bufnr)
      end
    end),
  })

  -- Store the job
  M.active_jobs[bufnr] = job
  job:start()
  return job
end

-- Get the latest user message from the chat buffer
---@return string content The content of the latest user message
local function get_latest_user_message()
  local bufnr = vim.api.nvim_get_current_buf()
  return parser.get_latest_user_message(bufnr)
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

  -- Parse chat history from buffer
  local messages = parse_chat_buffer(source_bufnr)

  -- Convert history to string
  local content = vim.fn.json_encode(messages)
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

  if target_bufnr ~= -1 and vim.api.nvim_buf_is_valid(target_bufnr) then
    M.target_buffers[chat_bufnr] = target_bufnr
  else
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
  end

  return system_content
end

-- Update send_message to not use chat_history
function M.send_message()
  local bufnr = vim.api.nvim_get_current_buf()

  -- Check if already waiting for a response
  if M.is_waiting_response[bufnr] then
    return
  end

  -- Set waiting state at the start
  M.is_waiting_response[bufnr] = true

  local win = vim.api.nvim_get_current_win()

  -- Set target buffer if not already set
  if not M.target_buffers[bufnr] then
    M.set_target_buffer(bufnr)
  end

  -- Get latest user message
  local ok, content = pcall(get_latest_user_message)
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

  -- If job is nil (API key not set), clean up state
  if not job then
    stop_thinking()
    M.is_waiting_response[bufnr] = nil
    -- Remove the blank lines we added
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, line_count - 2, line_count, false, {})
    return
  end

  -- Ensure cleanup happens even if job fails
  job:after(function()
    vim.schedule(function()
      stop_thinking()
      M.is_waiting_response[bufnr] = nil
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
  vim.api.nvim_buf_set_keymap(bufnr, 'n', '<CR>',
    [[<cmd>lua require('llmancer.chat').send_message()<CR>]],
    { noremap = true, silent = true })

  vim.api.nvim_buf_set_keymap(bufnr, 'n', 'gd',
    [[<cmd>lua require('llmancer.chat').view_conversation()<CR>]],
    { noremap = true, silent = true })

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
        if lines[j]:match("^user:") then
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

  -- Move cursor to end of buffer after making sure we're in the right window
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      -- Get the window ID after the buffer is displayed
      local win_id = vim.fn.bufwinid(bufnr)
      if win_id ~= -1 then
        local line_count = vim.api.nvim_buf_line_count(bufnr)
        if line_count > 0 then
          -- Set cursor to last line, first column
          vim.api.nvim_win_set_cursor(win_id, { line_count, 0 })
        end
      end
    end
  end)

  return bufnr
end

-- Export the functions
M.show_system_prompt = show_system_prompt
M.setup_buffer_mappings = setup_buffer_mappings

-- Update cleanup_buffer
function M.cleanup_buffer(bufnr)
  -- Cancel any active job
  if M.active_jobs[bufnr] then
    M.active_jobs[bufnr]:shutdown()
    M.active_jobs[bufnr] = nil
  end

  -- Clean up target buffers
  if M.target_buffers[bufnr] then
    M.target_buffers[bufnr] = nil
  end

  -- Clean up waiting state
  if M.is_waiting_response[bufnr] then
    M.is_waiting_response[bufnr] = nil
  end
end

-- Add this near the end of the file, with the other setup code
local function setup_commands()
  -- Command to toggle file in context
  vim.api.nvim_create_user_command('LLMContext', function(opts)
    require('llmancer.chat').toggle_file_in_context(opts.args)
  end, {
    nargs = 1,
    complete = function(_, _, _)
      local bufs = {}
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name ~= "" then
          table.insert(bufs, name)
        end
      end
      return bufs
    end,
    desc = "Toggle a file in the chat context"
  })
end

-- Add setup_commands() to the end of the file
setup_commands()

return M
