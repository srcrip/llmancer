local parser = require('llmancer.chat.parser')

describe('chat parser', function()
  -- Helper function to create a test buffer with content
  local function create_test_buffer(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return bufnr
  end

  describe('parse_chat_lines', function()
    it('should parse a simple chat with one message', function()
      local lines = {
        '---',
        '{ params = {} }',
        '---',
        '',
        'Welcome to LLMancer!',
        '',
        '----------------------------------------',
        'Hello world',
        '',
        'assistant: Nice to meet you!'
      }

      local messages = parser.parse_chat_lines(lines)
      assert.equals(2, #messages)
      assert.equals('user', messages[1].role)
      assert.equals('Hello world', messages[1].content)
      assert.equals('assistant', messages[2].role)
      assert.equals('Nice to meet you!', messages[2].content)
    end)

    it('should handle multiline messages', function()
      local lines = {
        '---',
        '{ params = {} }',
        '---',
        '',
        'Welcome to LLMancer!',
        '',
        '----------------------------------------',
        'Hello',
        'This is a',
        'multiline message',
        '',
        'assistant: This is also',
        'a multiline',
        'response'
      }

      local messages = parser.parse_chat_lines(lines)
      assert.equals(2, #messages)
      assert.equals('Hello\nThis is a\nmultiline message', messages[1].content)
      assert.equals('This is also\na multiline\nresponse', messages[2].content)
    end)

    it('should handle messages with user prefix', function()
      local lines = {
        '----------------------------------------',
        'First message',
        '',
        'assistant: First response',
        '',
        'user: Second message',
        '',
        'assistant: Second response'
      }

      local messages = parser.parse_chat_lines(lines)
      assert.equals(4, #messages)
      assert.equals('First message', messages[1].content)
      assert.equals('First response', messages[2].content)
      assert.equals('Second message', messages[3].content)
      assert.equals('Second response', messages[4].content)
    end)
  end)

  describe('get_latest_user_message', function()
    it('should get the last user message after separator', function()
      local bufnr = create_test_buffer({
        '----------------------------------------',
        'Hello world',
        '',
        'assistant: Hi there!'
      })

      local message = parser.get_latest_user_message(bufnr)
      assert.equals('Hello world', message)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('should get the last user message with prefix', function()
      local bufnr = create_test_buffer({
        '----------------------------------------',
        'First message',
        '',
        'assistant: First response',
        '',
        'user: Second message',
        '',
        'assistant: Second response'
      })

      local message = parser.get_latest_user_message(bufnr)
      assert.equals('Second message', message)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('should handle multiline last message', function()
      local bufnr = create_test_buffer({
        '----------------------------------------',
        'user: This is a',
        'multiline',
        'message',
        ''
      })

      local message = parser.get_latest_user_message(bufnr)
      assert.equals('This is a\nmultiline\nmessage', message)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('should return empty string for empty buffer', function()
      local bufnr = create_test_buffer({})
      local message = parser.get_latest_user_message(bufnr)
      assert.equals('', message)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('should handle messages with code blocks', function()
      local bufnr = create_test_buffer({
        '----------------------------------------',
        'Here is some code:',
        '',
        '```lua',
        'local function test()',
        '  print("hello")',
        'end',
        '```',
        '',
        'assistant: Nice code!'
      })

      local message = parser.get_latest_user_message(bufnr)
      assert.equals('Here is some code:\n\n```lua\nlocal function test()\n  print("hello")\nend\n```', message)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)
end) 