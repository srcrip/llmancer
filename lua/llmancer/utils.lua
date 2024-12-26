local M = {}

local config = require "llmancer.config"

-- Parse chat ID into timestamp
function M.parse_chat_id(chat_id)
  local pattern = "^(%d%d%d%d)(%d%d)(%d%d)_(%d%d)(%d%d)(%d%d)_"
  local year, month, day, hour, min, sec = chat_id:match(pattern)
  if not year then
    return nil
  end

  return os.time {
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
  }
end

-- Create readable timestamp
function M.format_timestamp(timestamp)
  return os.date("%Y-%m-%d %H:%M:%S", timestamp)
end

-- Open buffer in configured split
function M.open_split()
  if config.values.open_mode == "vsplit" then
    vim.cmd "vsplit"
  elseif config.values.open_mode == "split" then
    vim.cmd "split"
  end
end

-- Validate configuration
function M.validate_config(c)
  local required = {
    "anthropic_api_key",
    "model",
    "max_tokens",
    "storage_dir",
  }

  for _, key in ipairs(required) do
    if not c[key] then
      error(string.format("LLMancer: Missing required config: %s", key))
    end
  end
end

return M
