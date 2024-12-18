---@class Config
---@field open_mode "vsplit"|"split"|"enew" How to open the chat buffer
---@field buffer_name string Buffer name for the chat
---@field anthropic_api_key string Anthropic API key
---@field model string Model to use (e.g. "claude-3-sonnet-20240229")
---@field max_tokens number Maximum tokens in response
---@field temperature number Temperature for response generation
---@field system_prompt string System prompt for the assistant
---@field storage_dir string Directory to store chat histories

-- Import the main module
local main = require("llmancer.main")

---@class LLMancerModule
---@field setup fun(opts: Config|nil) Function to setup the plugin
---@field open_chat fun() Function to open the chat buffer
---@field list_chats fun() Function to list saved chats
---@field edit_selection fun() Function to edit the selection
---@field config Config The current configuration
local M = {}

-- Forward all public functions and config
M.setup = main.setup
M.open_chat = main.open_chat
M.list_chats = main.list_chats
M.edit_selection = main.edit_selection
M.config = main.config

return M
