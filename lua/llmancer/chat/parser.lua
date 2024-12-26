-- Constants
local SECTION_SEPARATOR = "---"
local CHAT_SEPARATOR = "----------------------------------------"

---@class ChatParser
local M = {}

-- Valid roles for the API
local valid_roles = {
  user = true,
  assistant = true,
  system = true,
}

-- Parse the chat buffer into a sequence of messages
---@param lines string[] Array of lines from the buffer
---@return table[] messages Array of message objects {role, content}
function M.parse_chat_lines(lines)
  local messages = {}
  local current_msg = nil
  local in_params = false
  local found_separator = false

  for _, line in ipairs(lines) do
    -- Handle parameters section
    if line == SECTION_SEPARATOR then
      in_params = not in_params
    elseif not in_params then
      -- Process chat content
      if line == CHAT_SEPARATOR then
        found_separator = true
      elseif found_separator and not current_msg then
        local trimmed = vim.trim(line)
        if trimmed ~= "" and not trimmed:match "^[^:]+:" then
          current_msg = {
            role = "user",
            content = trimmed,
          }
        end
      else
        local role = line:match "^(%w+):%s*"
        if role and valid_roles[role] then
          if current_msg then
            current_msg.content = vim.trim(current_msg.content)
            if current_msg.content ~= "" then
              table.insert(messages, current_msg)
            end
          end
          current_msg = {
            role = role,
            content = line:sub(#role + 2),
          }
        elseif current_msg then
          current_msg.content = current_msg.content .. "\n" .. line
        end
      end
    end
  end

  -- Handle the last message
  if current_msg then
    current_msg.content = vim.trim(current_msg.content)
    if current_msg.content ~= "" then
      table.insert(messages, current_msg)
    end
  end

  return messages
end

-- Parse the chat buffer into a sequence of messages
---@param bufnr number The buffer number to parse
---@return table[] messages Array of message objects {role, content}
function M.parse_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return M.parse_chat_lines(lines)
end

-- Get the latest user message from the chat buffer
---@param bufnr number The buffer number
---@return string content The content of the latest user message
function M.get_latest_user_message(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local message_lines = {}

  -- First find the last non-empty line
  local last_line = nil
  for i = #lines, 1, -1 do
    if vim.trim(lines[i]) ~= "" then
      last_line = i
      break
    end
  end

  if not last_line then
    return ""
  end

  -- Now find the start of this message by looking for separator or role marker
  local start_line = nil
  local user_prefix = nil
  for i = last_line, 1, -1 do
    local line = lines[i]

    if line:match "^A:" or line:match "^assistant:" then
      -- Skip back to previous user message or separator
      while i > 1 do
        i = i - 1
        if lines[i]:match "^user:" then
          start_line = i
          user_prefix = true
          break
        elseif lines[i] == CHAT_SEPARATOR then
          start_line = i + 1
          break
        end
      end
      break
    elseif line:match "^user:" then
      start_line = i
      user_prefix = true
      break
    elseif line == CHAT_SEPARATOR then
      start_line = i + 1
      break
    end
  end

  if not start_line then
    return ""
  end

  -- Find end of message (next assistant response or EOF)
  local end_line = last_line
  for i = start_line, last_line do
    local line = lines[i]
    if line:match "^A:" or line:match "^assistant:" then
      end_line = i - 1
      break
    end
  end

  -- Collect all lines from start to end
  for i = start_line, end_line do
    local line = lines[i]
    -- If this is the first line and it has a user prefix, remove it
    if i == start_line and user_prefix then
      line = line:gsub("^user:%s*", "")
    end
    table.insert(message_lines, line)
  end

  -- Trim trailing empty lines while preserving intentional newlines in the message
  while #message_lines > 0 and vim.trim(message_lines[#message_lines]) == "" do
    table.remove(message_lines)
  end

  return table.concat(message_lines, "\n")
end

return M
