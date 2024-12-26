local chat = require('llmancer.chat')
local config = require('llmancer.config')

describe('llmancer.chat', function()
  -- Setup before each test
  before_each(function()
    -- Initialize config with test values
    config.setup({
      anthropic_api_key = 'test_key',
      model = 'claude-3-sonnet-20240229',
      max_tokens = 1024,
      temperature = 0.7,
      storage_dir = vim.fn.stdpath('data') .. '/llmancer/chats',
    })
  end)

  -- Cleanup after each test
  after_each(function()
    -- Clean up any test buffers
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_option(buf, 'buftype') == 'nofile' then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end)

  describe('generate_id', function()
    it('should generate a valid numeric ID', function()
      local id = chat.generate_id()
      assert.is_number(id)
      assert.is_true(id >= 0)
      assert.is_true(id < 2^32)
    end)

    it('should generate unique IDs', function()
      local ids = {}
      for _ = 1, 100 do
        local id = chat.generate_id()
        assert.is_falsy(ids[id])
        ids[id] = true
      end
    end)
  end)

  describe('toggle_file_in_context', function()
    local test_buffer

    before_each(function()
      -- Create a test buffer with initial context
      test_buffer = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_option(test_buffer, 'filetype', 'llmancer')
      
      -- Set initial content with params section
      local initial_content = {
        "---",
        "{",
        "  params = {",
        "    model = 'claude-3-sonnet-20240229',",
        "    max_tokens = 1024,",
        "    temperature = 0.7",
        "  },",
        "  context = {",
        "    files = {},",
        "    global = {}",
        "  }",
        "}",
        "---",
      }
      vim.api.nvim_buf_set_lines(test_buffer, 0, -1, false, initial_content)
    end)

    after_each(function()
      if vim.api.nvim_buf_is_valid(test_buffer) then
        vim.api.nvim_buf_delete(test_buffer, { force = true })
      end
    end)

    it('should add a file to empty context', function()
      -- Switch to test buffer
      vim.api.nvim_set_current_buf(test_buffer)
      
      -- Toggle a test file
      chat.toggle_file_in_context('test.lua')
      
      -- Get buffer content and parse it
      local lines = vim.api.nvim_buf_get_lines(test_buffer, 0, -1, false)
      local content = table.concat(lines, '\n')
      
      -- Load the content as Lua table
      local chunk = assert(loadstring('return ' .. content:match('{.*}')))
      local result = chunk()
      
      -- Verify the file was added
      assert.equals(1, #result.context.files)
      assert.equals('test.lua', result.context.files[1])
    end)

    it('should remove an existing file from context', function()
      -- Set up buffer with existing file in context
      local content_with_file = {
        "---",
        "{",
        "  params = {",
        "    model = 'claude-3-sonnet-20240229',",
        "    max_tokens = 1024,",
        "    temperature = 0.7",
        "  },",
        "  context = {",
        "    files = {'test.lua'},",
        "    global = {}",
        "  }",
        "}",
        "---",
      }
      vim.api.nvim_buf_set_lines(test_buffer, 0, -1, false, content_with_file)
      
      -- Switch to test buffer
      vim.api.nvim_set_current_buf(test_buffer)
      
      -- Toggle the same file
      chat.toggle_file_in_context('test.lua')
      
      -- Get buffer content and parse it
      local lines = vim.api.nvim_buf_get_lines(test_buffer, 0, -1, false)
      local content = table.concat(lines, '\n')
      
      -- Load the content as Lua table
      local chunk = assert(loadstring('return ' .. content:match('{.*}')))
      local result = chunk()
      
      -- Verify the file was removed
      assert.equals(0, #result.context.files)
    end)
  end)

  describe('target buffer management', function()
    it('should set and get target buffer correctly', function()
      local chat_buf = vim.api.nvim_create_buf(false, true)
      local target_buf = vim.api.nvim_create_buf(false, true)
      
      chat.set_target_buffer(chat_buf, target_buf)
      assert.equals(target_buf, chat.target_buffers[chat_buf])
      
      -- Cleanup
      vim.api.nvim_buf_delete(chat_buf, { force = true })
      vim.api.nvim_buf_delete(target_buf, { force = true })
    end)

    it('should cleanup target buffer on buffer delete', function()
      local chat_buf = vim.api.nvim_create_buf(false, true)
      local target_buf = vim.api.nvim_create_buf(false, true)
      
      chat.set_target_buffer(chat_buf, target_buf)
      chat.cleanup_buffer(chat_buf)
      
      assert.is_nil(chat.target_buffers[chat_buf])
      
      -- Cleanup
      vim.api.nvim_buf_delete(chat_buf, { force = true })
      vim.api.nvim_buf_delete(target_buf, { force = true })
    end)
  end)

  describe('create_params_text', function()
    it('should create valid params section', function()
      local params = chat.create_params_text()
      
      -- Check structure
      assert.equals('---', params[1])
      assert.is_true(#params > 2)
      assert.equals('---', params[#params])
      
      -- Verify content can be evaluated as Lua
      local content = table.concat(vim.list_slice(params, 2, #params - 1), '\n')
      local chunk, err = loadstring('return ' .. content)
      assert.is_nil(err)
      
      local result = chunk()
      assert.is_table(result)
      assert.is_table(result.params)
      assert.is_table(result.context)
      assert.is_table(result.context.files)
      assert.is_table(result.context.global)
    end)
  end)
end) 