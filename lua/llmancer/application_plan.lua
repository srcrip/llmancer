local M = {}

-- Constants for the plan buffer
local HELP_TEXT = [[Apply Changes:
<enter> to apply change (without saving)
<A> to apply all changes (and save)
<U> to undo all changes
:q or ZQ to quit without applying changes
:wq or ZZ to apply changes and save the changed buffers
]]

-- Track modified buffers globally for the module
local modified_buffers = {}

-- Function to save all modified buffers
local function save_modified_buffers()
    for bufnr, _ in pairs(modified_buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.fn.bufload(bufnr)
            local line_count = vim.api.nvim_buf_line_count(bufnr)
            if line_count > 0 then
                vim.api.nvim_buf_call(bufnr, function()
                    vim.cmd('write')
                end)
            end
        end
    end
    modified_buffers = {}
end

-- Function to track modified buffer
local function track_modified_buffer(block_text)
    local first_line = block_text:match("^[^\n]+")
    local filename = first_line and first_line:match("^file:%s*(.-)%s*$")

    if filename then
        local abs_path = vim.fn.fnamemodify(filename, ':p')
        local bufnr = vim.fn.bufnr(abs_path)

        if bufnr == -1 then
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                local buf_name = vim.api.nvim_buf_get_name(buf)
                if buf_name == abs_path then
                    bufnr = buf
                    break
                end
            end
        end

        if bufnr == -1 then
            local dir = vim.fn.fnamemodify(abs_path, ':h')
            vim.fn.mkdir(dir, 'p')

            bufnr = vim.fn.bufadd(abs_path)
            vim.fn.bufload(bufnr)
        end

        if bufnr ~= -1 then
            modified_buffers[bufnr] = true
        end
    end
end

-- Function to get buffer content as string
---@param bufnr number Buffer number
---@return string
local function get_buffer_content(bufnr)
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

-- Function to create and show the plan buffer
---@param content string The plan content
local function create_plan_buffer(content)
    local bufnr = vim.api.nvim_create_buf(false, true)
    local plan_name = "LLMancer-Plan-" .. os.date("%H%M%S")
    vim.api.nvim_buf_set_name(bufnr, plan_name)

    -- Set buffer options
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].buftype = 'nofile'
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = 'llmancer_plan'

    -- Set content
    local lines = vim.split(HELP_TEXT .. "\n" .. content, "\n")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    -- Enable treesitter highlighting for the buffer
    if pcall(require, "nvim-treesitter.configs") then
        vim.cmd([[TSBufEnable highlight]])
        -- Enable markdown highlighting
        vim.cmd([[TSBufEnable indent]])
        -- Enable language injection
        pcall(vim.treesitter.start, bufnr, "markdown")
    end

    -- Set up autocmd to save modified buffers before buffer write
    vim.api.nvim_create_autocmd({ "BufWritePre" }, {
        buffer = bufnr,
        callback = function()
            save_modified_buffers()
        end
    })

    -- Set up keymaps
    local opts = { buffer = bufnr, noremap = true, silent = true }

    -- Apply single block
    vim.keymap.set('n', '<CR>', function()
        M.apply_block_under_cursor(bufnr)
    end, opts)

    -- Apply all blocks and save
    vim.keymap.set('n', 'A', function()
        M.apply_all_blocks(bufnr)
        -- Add a small delay to ensure all buffer modifications are complete
        vim.defer_fn(function()
            save_modified_buffers()
            vim.notify("Saved all modified buffers", vim.log.levels.INFO)
        end, 100)
    end, opts)

    -- Undo all changes
    vim.keymap.set('n', 'U', function()
        for bufnr, _ in pairs(modified_buffers) do
            if vim.api.nvim_buf_is_valid(bufnr) then
                vim.api.nvim_buf_call(bufnr, function()
                    vim.cmd('earlier 1f') -- Go back to last file write
                end)
            end
        end
        modified_buffers = {}
        vim.notify("Undid all changes", vim.log.levels.INFO)
    end, opts)

    -- Open buffer in a split
    vim.cmd('vsplit')
    vim.api.nvim_set_current_buf(bufnr)

    return bufnr
end

-- Function to apply a single block of changes
---@param block_text string The text of the block to apply
---@return boolean success Whether the changes were applied successfully
local function apply_block(block_text)
    if not block_text or block_text == "" then
        vim.notify("Empty block text", vim.log.levels.ERROR)
        return false
    end

    local lines = vim.split(block_text, "\n")
    local block = {
        filename = nil,
        operation = nil,
        start = nil,
        end_line = nil
    }

    -- Parse block header
    local in_header = true
    local code_lines = {}

    for _, line in ipairs(lines) do
        if in_header then
            -- Parse header fields
            local filename = line:match("^file:%s*(.+)$")
            local operation = line:match("^operation:%s*(%w+)$")
            local start_line = line:match("^start:%s*(%d+)$")
            local end_line = line:match("^end:%s*(%d+)$")

            if filename then
                block.filename = filename
            elseif operation then
                block.operation = operation
            elseif start_line then
                block.start = tonumber(start_line)
            elseif end_line then
                block.end_line = tonumber(end_line)
            elseif line:match("^```") then
                in_header = false
            end
        else
            -- Collect code lines, skipping the closing backticks
            if not line:match("^```") then
                table.insert(code_lines, line)
            end
        end
    end

    -- Validate required fields
    if not (block.filename and block.operation) then
        vim.notify("Missing required fields in block", vim.log.levels.ERROR)
        return false
    end

    -- Find or create buffer
    local bufnr = vim.fn.bufnr(block.filename)
    if bufnr == -1 then
        if vim.fn.filereadable(block.filename) == 1 then
            bufnr = vim.fn.bufadd(block.filename)
            vim.fn.bufload(bufnr)
        else
            -- Create new file and its directory
            local dir = vim.fn.fnamemodify(block.filename, ':h')
            vim.fn.mkdir(dir, 'p')
            bufnr = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_name(bufnr, block.filename)
        end
    end

    if not vim.api.nvim_buf_is_valid(bufnr) then
        vim.notify("Invalid buffer for file: " .. block.filename, vim.log.levels.ERROR)
        return false
    end

    -- Apply changes based on operation
    local success = false
    if block.operation == "write" then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, code_lines)
        success = true
    elseif block.operation == "insert" or block.operation == "replace" then
        local line_count = vim.api.nvim_buf_line_count(bufnr)

        -- Validate line numbers
        if not block.start or block.start < 1 or block.start > line_count + 1 then
            vim.notify(string.format("Invalid start line: %d (buffer has %d lines)",
                block.start or 0, line_count), vim.log.levels.ERROR)
            return false
        end

        if block.operation == "insert" then
            vim.api.nvim_buf_set_lines(bufnr, block.start, block.start, false, code_lines)
            success = true
        elseif block.operation == "replace" and block.end_line then
            if block.end_line < block.start or block.end_line > line_count then
                vim.notify(string.format("Invalid end line: %d (buffer has %d lines)",
                    block.end_line, line_count), vim.log.levels.ERROR)
                return false
            end
            vim.api.nvim_buf_set_lines(bufnr, block.start - 1, block.end_line, false, code_lines)
            success = true
        end
    end

    if success then
        track_modified_buffer(block_text)
        return true
    end

    vim.notify("Invalid operation: " .. block.operation, vim.log.levels.ERROR)
    return false
end

-- Function to apply block under cursor
---@param bufnr number Buffer number of the plan buffer
---@return boolean success Whether the block was applied successfully
function M.apply_block_under_cursor(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        vim.notify("Invalid plan buffer", vim.log.levels.ERROR)
        return false
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local start_line = cursor[1]
    local end_line = cursor[1]

    -- Find block boundaries
    while start_line > 1 and not lines[start_line - 1]:match("^file:") do
        start_line = start_line - 1
    end
    while end_line < #lines and not lines[end_line + 1]:match("^file:") do
        end_line = end_line + 1
    end

    local block_text = table.concat(vim.list_slice(lines, start_line, end_line), "\n")
    if apply_block(block_text) then
        vim.notify("Applied changes successfully", vim.log.levels.INFO)
        return true
    end

    vim.notify("Failed to apply changes", vim.log.levels.ERROR)
    return false
end

-- Function to apply all blocks
---@param bufnr number Buffer number of the plan buffer
function M.apply_all_blocks(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local current_block = {}
    local success_count = 0
    local total_blocks = 0

    for _, line in ipairs(lines) do
        -- Start a new block when we see a file: line
        if line:match("^file:") then
            -- Apply previous block if it exists
            if #current_block > 0 then
                if apply_block(table.concat(current_block, "\n")) then
                    success_count = success_count + 1
                end
            end
            current_block = { line }
            total_blocks = total_blocks + 1
        elseif #current_block > 0 then
            -- Add lines to current block until we see another file: line
            table.insert(current_block, line)
        end
    end

    -- Apply last block
    if #current_block > 0 then
        if apply_block(table.concat(current_block, "\n")) then
            success_count = success_count + 1
        end
    end

    vim.notify(string.format("Applied %d/%d changes", success_count, total_blocks), vim.log.levels.INFO)
end

-- Function to create application plan
---@param code_blocks string[] Array of code blocks to apply
---@param target_buffers number[] Array of target buffer numbers
function M.create_plan(code_blocks, target_buffers)
    local chat = require('llmancer.chat')

    -- Get current chat buffer
    local chat_bufnr = vim.api.nvim_get_current_buf()
    local chat_history = chat.chat_history[chat_bufnr] or {}

    -- Format chat history for context
    local chat_context = {}
    for _, msg in ipairs(chat_history) do
        if msg.role == "user" then
            table.insert(chat_context, "user: " .. msg.content)
        elseif msg.role == "llm" then
            table.insert(chat_context, "assistant: " .. msg.content)
        end
    end

    -- -- Prepare buffer context
    -- local buffer_context = {}
    -- for _, bufnr in ipairs(target_buffers) do
    --     table.insert(buffer_context, "Buffer " .. bufnr .. " content:\n```\n" .. get_buffer_content(bufnr) .. "\n```")
    -- end

    local buffer_context = {}
    for _, bufnr in ipairs(target_buffers) do
        local filename = vim.api.nvim_buf_get_name(bufnr)
        table.insert(buffer_context,
            "Filename " .. filename .. " content:\n```\n" .. get_buffer_content(bufnr) .. "\n```")
    end


    -- INSERT BLOCK:
    --
    -- file: path/to/file.txt
    -- operation: insert
    -- start: 4
    -- ```
    -- console.log("foo bar");
    -- ```
    --
    --

    -- todo add:
    -- - An overview of the filesystem of the project.
    local prompt = [[
      You are about to receive:
        - The context of a chat with another AI. This chat will contain some code the user wants to apply to some files, or create new files from.
        - The files containing the user's current code.

      Your task is to return a set of operations, in order to apply the requested changes. Here are examples of each kind of block:

      WRITE BLOCK (replaces entire file):

      file: path/to/file.txt
      operation: write
      ```javascript
      // This will be the entire contents of the file
      import { foo } from "bar";

      const foo = () => {
        return "bar";
      };

      const bar = () => {
        return "baz";
      };
      ```

      REPLACE BLOCK:

      file: path/to/file.txt
      operation: replace
      start: 4
      end: 6
      ```
      const foo = () => {
        console.log("foo bar");
      }
      ```

      As you can see, the start (and stop lines for replace blocks) are important for insert and replace operations.
      The write operation will replace the entire contents of the file.

      Your response should include many of these blocks, separated by new lines.
      Pay attention to indentation make sure to match it in your new code.

      ===

      Here's the context:

      ** Context of user's chat: **

    ]] .. table.concat(chat_context, "\n\n") .. [[

      ** Context of user's current files: **

    ]] .. table.concat(buffer_context, "\n\n") .. [[

      Now generate the operations to apply to the files.

      REMEMBER:
      - you are to return only the set of operations, that is, ONLY CODE! nothing that's not code. Don't put anything else outside the blocks besides the header info.
      - when inserting text, consider the whitespace around the code you'll be inserting. For instance, you may want to have some blank lines in the code block you'll insert if it will result in properly formatted text once inserted.
      - remember to incldue the language at the backticks, e.g. ```javascript because we use it for syntax highlighting.
      - please try to use the `write` operation the most. When doing so remember to return the entirity of the changed file content.
      - you must always use the available operations. each code block must be either a write block or a replace block. and you must always include the file: and operation: header info.
    ]]

    -- Debug print the entire prompt
    local debug_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(debug_buf, "LLMancer-Debug-Prompt")
    vim.api.nvim_buf_set_lines(debug_buf, 0, -1, false, vim.split(prompt, "\n"))
    vim.cmd("vsplit")
    vim.api.nvim_set_current_buf(debug_buf)
    vim.bo[debug_buf].buftype = 'nofile'
    vim.bo[debug_buf].swapfile = false

    -- Send to LLM and create plan buffer
    chat.send_to_anthropic({ { role = "user", content = prompt } }, function(response)
        if response and response.content and response.content[1] then
            create_plan_buffer(response.content[1].text)
        end
    end)
end

return M
