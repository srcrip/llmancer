-- Add plugin directory to runtimepath
vim.opt.rtp:append(".")
vim.opt.swapfile = false

-- Add plenary to runtimepath
local plenary_path = vim.fn.stdpath("data") .. "/site/pack/vendor/start/plenary.nvim"
vim.opt.rtp:append(plenary_path)

-- Load test dependencies
local cwd = vim.fn.getcwd()
vim.opt.rtp:append(cwd)
vim.opt.rtp:append(cwd .. "/specs")

-- Load plenary
vim.cmd("runtime plugin/plenary.vim")
require("plenary.busted")

-- Configure test environment
_G.test_config = {
    anthropic_api_key = "test_key_123",
    model = "test-model",
    max_tokens = 100,
    temperature = 0.5
}

-- Set up global test helpers
_G.t = require('specs.helpers')

-- Ensure clean test environment
vim.api.nvim_create_augroup("TestCleanup", { clear = true })
vim.api.nvim_create_autocmd("VimLeavePre", {
    group = "TestCleanup",
    callback = function()
        require('specs.helpers').reset_env()
    end,
}) 