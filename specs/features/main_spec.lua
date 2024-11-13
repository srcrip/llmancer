local helpers = require('specs.helpers')

describe("main", function()
    local main = require("llmancer.main")

    before_each(function()
        helpers.reset_env()
    end)

    after_each(function()
        helpers.reset_env()
    end)

    describe("configuration", function()
        it("can be configured with custom options", function()
            main.setup({
                open_mode = 'split',
                buffer_name = 'Test',
                anthropic_api_key = 'test_key'
            })

            assert.equals('split', main.config.open_mode)
            assert.equals('Test', main.config.buffer_name)
            assert.equals('test_key', main.config.anthropic_api_key)
        end)

        it("maintains default values for unspecified options", function()
            local default_model = main.config.model
            main.setup({ open_mode = 'split' })

            assert.equals('split', main.config.open_mode)
            assert.equals(default_model, main.config.model)
        end)
    end)

    describe("thinking indicator", function()
        it("can be created and stopped", function()
            local bufnr = helpers.create_test_buffer({})
            local stop_fn = main.create_thinking_indicator(bufnr)

            assert.is_function(stop_fn)
            stop_fn()
        end)
    end)
end)

