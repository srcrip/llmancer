local helpers = require('specs.helpers')

describe("chat", function()
    local chat = require("llmancer.chat")
    local config = require("llmancer.main").config
    
    before_each(function()
        helpers.reset_env()
        chat.chat_history = {}
        chat.target_buffers = {}
        
        config.system_prompt = "Test system prompt"
        config.model = "test-model"
    end)
    
    after_each(function()
        helpers.reset_env()
    end)
    
    describe("help text", function()
        it("contains expected elements", function()
            local bufnr = helpers.create_test_buffer({})
            local help_text = chat.create_help_text(bufnr)
            local text = table.concat(help_text, "\n")
            
            assert.truthy(text:match("Welcome to LLMancer.nvim"))
            assert.truthy(text:match("Currently using:"))
            assert.truthy(text:match("Shortcuts:"))
        end)
    end)
    
    describe("system prompt", function()
        it("includes file context when target buffer exists", function()
            local target_bufnr = helpers.create_test_buffer(
                {"test content"},
                {filetype = "lua", name = "test.lua"}
            )
            
            local chat_bufnr = helpers.create_test_buffer({})
            vim.api.nvim_set_current_buf(chat_bufnr)
            chat.set_target_buffer(chat_bufnr, target_bufnr)
            
            local prompt = chat.build_system_prompt()
            assert.is_not_nil(prompt, "System prompt should not be nil")
            
            assert.truthy(prompt:match("Test system prompt"))
            assert.truthy(prompt:match("test content"))
            assert.truthy(prompt:match("test.lua"))
            assert.truthy(prompt:match("lua"))
        end)
        
        it("returns basic prompt without target buffer", function()
            local chat_bufnr = helpers.create_test_buffer({})
            vim.api.nvim_set_current_buf(chat_bufnr)
            
            local prompt = chat.build_system_prompt()
            assert.is_not_nil(prompt)
            assert.equals(config.system_prompt, prompt)
        end)
    end)
end) 