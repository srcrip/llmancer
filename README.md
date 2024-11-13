# LLMancer.nvim 🧙‍♂️

A Neovim plugin for chatting with LLMs.

## ✨ Features

- Everything is just a normal buffer as much as possible
- Chat all in one buffer, instead of multiple windows
- LLM doesn't need to provide line numbers in it's responses, it's a two step process to apply changes

## 📦 Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    'jpmcb/LLMancer.nvim',
    dependencies = {
        "nvim-lua/plenary.nvim",
        -- required for listing past chats (telescope coming soon)
        "ibhagwan/fzf-lua"
    },
    config = function()
        require('llmancer').setup({
            anthropic_api_key = 'your-api-key-here', -- Required
            -- Optional configuration...
            model = 'claude-3-sonnet-20240229',
            max_tokens = 4096,
            temperature = 0.7,
        })
    end,
    keys = {
        { "<leader>ll", "<cmd>lua require('llmancer').open_chat()<cr>",  desc = "Open LLMancer Chat" },
        { "<leader>lc", "<cmd>lua require('llmancer').list_chats()<cr>", desc = "List LLMancer Chats" },
    },
},
```

## 🚀 Usage

Start a chat session:

```lua
require('llmancer').open_chat()
```

