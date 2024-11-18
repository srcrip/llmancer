local curl = require('plenary.curl')
local config = require('llmancer.config')

local M = {}

-- Send a message to Claude API and get the full response
---@param messages table[] The messages to send
---@param system_prompt string|nil Optional system prompt override
---@param callback fun(success: boolean, response: string|nil, error: string|nil) Callback function
function M.send_message(messages, system_prompt, callback)
  -- Check for API key
  if not config.values.anthropic_api_key or config.values.anthropic_api_key == "" then
    vim.schedule(function()
      callback(false, nil, "Anthropic API key not set")
    end)
    return
  end

  -- Build request body
  local request_body = {
    model = config.values.model,
    max_tokens = config.values.max_tokens,
    temperature = config.values.temperature,
    messages = messages,
    system = system_prompt,
    stream = false,
  }

  -- Make the request
  curl.post('https://api.anthropic.com/v1/messages', {
    headers = {
      ['x-api-key'] = config.values.anthropic_api_key,
      ['anthropic-version'] = '2023-06-01',
      ['content-type'] = 'application/json',
    },
    body = vim.json.encode(request_body),
    callback = vim.schedule_wrap(function(response)
      if response.status ~= 200 then
        callback(false, nil, "API request failed with status " .. response.status)
        return
      end

      local ok, parsed = pcall(vim.json.decode, response.body)
      if not ok or not parsed or not parsed.content then
        callback(false, nil, "Failed to parse API response")
        return
      end

      callback(true, parsed.content[1].text, nil)
    end),
  })
end

return M 