local M = {}

---@class Config
---@field open_mode "vsplit"|"split"|"enew" How to open the chat buffer
---@field buffer_name string Buffer name for the chat
---@field anthropic_api_key string Anthropic API key
---@field model string Model to use (e.g. "claude-3-sonnet-20240229")
---@field max_tokens number Maximum tokens in response
---@field temperature number Temperature for response generation
---@field system_prompt string|nil System prompt for the assistant
---@field storage_dir string Directory to store chat histories
---@field close_chat_buffer_on_win_closed boolean Whether to close the chat buffer when its window is closed
---@field actions table Action configuration
---@field actions.keymap string Keymap for actions menu
---@field add_files_to_new_chat "all"|"current"|"none" Which files to add to context when creating a new chat

-- Default configuration
---@type Config
local defaults = {
  open_mode = 'vsplit',
  buffer_name = 'LLMancer.nvim',
  anthropic_api_key = os.getenv("ANTHROPIC_API_KEY"),
  model = "claude-3-sonnet-20240229",
  max_tokens = 4096,
  temperature = 0.7,
  system_prompt = nil,
  storage_dir = vim.fn.stdpath("data") .. "/llmancer/chats",
  close_chat_buffer_on_win_closed = true,
  actions = {
    keymap = "<leader>a",
  },
  add_files_to_new_chat = "all",
}

-- Current configuration (starts as defaults)
---@type Config
M.values = vim.deepcopy(defaults)

-- Validate configuration values
---@param config Config Configuration to validate
---@return string|nil error Error message if invalid
local function validate_config(config)
  -- Required fields
  local required = {
    'anthropic_api_key',
    'model',
    'max_tokens',
    'storage_dir'
  }

  for _, key in ipairs(required) do
    if not config[key] then
      return string.format("Missing required config: %s", key)
    end
  end

  -- Validate open_mode
  if config.open_mode and not vim.tbl_contains({ 'vsplit', 'split', 'enew' }, config.open_mode) then
    return string.format("Invalid open_mode: %s (must be 'vsplit', 'split', or 'enew')", config.open_mode)
  end

  -- Validate numeric values
  if type(config.max_tokens) ~= "number" or config.max_tokens <= 0 then
    return "max_tokens must be a positive number"
  end

  if type(config.temperature) ~= "number" or config.temperature < 0 or config.temperature > 1 then
    return "temperature must be a number between 0 and 1"
  end

  -- Validate add_files_to_new_chat
  if config.add_files_to_new_chat and 
     not vim.tbl_contains({ 'all', 'current', 'none' }, config.add_files_to_new_chat) then
    return string.format("Invalid add_files_to_new_chat: %s (must be 'all', 'current', or 'none')", 
      config.add_files_to_new_chat)
  end

  return nil
end

-- Setup configuration with user values
---@param opts Config|nil User configuration
---@return string|nil error Error message if invalid
function M.setup(opts)
  -- Start with defaults
  local new_config = vim.deepcopy(defaults)

  -- Merge user config if provided
  if opts then
    new_config = vim.tbl_deep_extend("force", new_config, opts)
  end

  -- Validate the merged config
  local err = validate_config(new_config)
  if err then
    return err
  end

  -- Update current config
  M.values = new_config
  return nil
end

-- Reset configuration to defaults (mainly for testing)
function M.reset()
  M.values = vim.deepcopy(defaults)
end

return M
