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
    'srcrip/llmancer',
    dependencies = {
        "nvim-lua/plenary.nvim",
        -- required for listing past chats (telescope coming soon)
        "ibhagwan/fzf-lua"
    },
    config = function()
        local llmancer = require('llmancer')

        llmancer.setup({
            anthropic_api_key = 'your-api-key-here', -- Required or:
            -- alternatively, the plugin will look for ANTHROPIC_API_KEY in your environment if you leave that blank
            -- Optional configuration...
            model = 'claude-3-sonnet-20240229',
            max_tokens = 4096,
            temperature = 0.7,
            close_chat_buffer_on_win_closed = true, -- Whether to close the chat buffer when its window is closed
            add_files_to_new_chat = "all", -- Which files to add to context when creating a new chat ("all", "current", or "none")
        })

        -- example keymaps
        vim.keymap.set('n', '<leader>ll', llmancer.open_chat, { desc = "Open chat" })
        vim.keymap.set('v', '<leader>le', llmancer.edit_selection, { desc = "Edit selection" })
        vim.keymap.set('n', '<leader>lc', llmancer.list_chats, { desc = "List chats" })
    end,
},
```

## 🚀 Usage

Start a chat session:

```lua
require('llmancer').open_chat()
```

## 🗺️ Roadmap

- [ ] More advanced prompts
- [ ] Advanced context management features (chat with codebase)
- [ ] Integrate Claude prompt caching

## ❤️  Contributing

Contributions are welcome!
