local M = {}

-- Constants for the plan buffer
local HELP_TEXT = [[Apply Changes:
<enter> to apply change (without saving)
<A> to apply all changes (and save)
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
    -- Create a unique filename in the storage directory
    local config = require('llmancer.config').config
    local plan_dir = config.storage_dir .. "/plans"
    vim.fn.mkdir(plan_dir, "p")
    local plan_name = plan_dir .. "/plan_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"

    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, plan_name)

    -- Set buffer options
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = 'llmancer_plan'

    -- Set content
    local lines = vim.split(HELP_TEXT .. "\n" .. content, "\n")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    -- Set up autocmd to save modified buffers before buffer write
    vim.api.nvim_create_autocmd({ "BufWritePre" }, {
        buffer = bufnr,
        callback = function()
            M.apply_all_blocks(bufnr)
            -- Add a small delay to ensure all buffer modifications are complete
            vim.defer_fn(function()
                save_modified_buffers()
            end, 100)
        end
    })

    -- Calculate window size and position
    local width = math.min(120, math.floor(vim.o.columns * 0.8))
    local height = math.min(30, math.floor(vim.o.lines * 0.8))
    local col = math.floor((vim.o.columns - width) / 2)
    local row = math.floor((vim.o.lines - height) / 2)

    -- Create floating window
    local win_opts = {
        relative = 'editor',
        width = width,
        height = height,
        col = col,
        row = row,
        anchor = 'NW',
        style = 'minimal',
        border = 'rounded'
    }

    local win_id = vim.api.nvim_open_win(bufnr, true, win_opts)

    -- Enable treesitter highlighting for the buffer
    if pcall(require, "nvim-treesitter.configs") then
        vim.cmd([[TSBufEnable highlight]])
        vim.cmd([[TSBufEnable indent]])
        pcall(vim.treesitter.start, bufnr, "markdown")
    end

    -- Set up keymaps
    local opts = { buffer = bufnr, noremap = true, silent = true }

    -- Apply single block
    vim.keymap.set('n', '<CR>', function()
        M.apply_block_under_cursor(bufnr)
    end, opts)

    -- Apply all blocks and save
    vim.keymap.set('n', 'A', function()
        M.apply_all_blocks(bufnr)
        vim.cmd('write')
        vim.notify("Saved all modified buffers", vim.log.levels.INFO)
    end, opts)

    -- Add q mapping to close the floating window
    vim.keymap.set('n', 'q', function()
        vim.api.nvim_win_close(win_id, true)
    end, opts)

    -- Add autocmd to properly clean up buffer when window is closed
    vim.api.nvim_create_autocmd("WinClosed", {
        buffer = bufnr,
        callback = function()
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(bufnr) then
                    vim.api.nvim_buf_delete(bufnr, { force = true })
                end
            end)
        end,
        once = true,
    })

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

    -- Skip help text
    local help_text_lines = #vim.split(HELP_TEXT, '\n')
    if start_line <= help_text_lines then
        vim.notify("Cannot apply help text", vim.log.levels.WARN)
        return false
    end

    -- Find block boundaries
    while start_line > help_text_lines and not lines[start_line]:match("^file:") do
        start_line = start_line - 1
    end

    -- Find the end of the block (next file: line or EOF)
    while end_line < #lines do
        end_line = end_line + 1
        if lines[end_line] and lines[end_line]:match("^file:") then
            end_line = end_line - 1
            break
        end
    end

    -- Extract and apply the block
    if start_line >= help_text_lines and end_line <= #lines then
        local block_text = table.concat(vim.list_slice(lines, start_line, end_line), "\n")
        if apply_block(block_text) then
            vim.notify("Applied changes successfully", vim.log.levels.INFO)
            return true
        end
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

-- Function to send request to Anthropic and get response
---@param message string The message to send
---@param callback fun(response: string|nil) Callback function with response
local function get_operations_from_llm(message, callback)
    local Job = require('plenary.job')
    local config = require('llmancer.config').config

    -- Prepare request body
    local body = vim.fn.json_encode({
        model = config.model,
        max_tokens = config.max_tokens,
        temperature = config.temperature,
        messages = { { role = "user", content = message } },
        stream = false, -- No streaming needed for this
    })

    local job = Job:new({
        command = 'curl',
        args = {
            'https://api.anthropic.com/v1/messages',
            '-X', 'POST',
            '-H', 'x-api-key: ' .. config.anthropic_api_key,
            '-H', 'anthropic-version: 2023-06-01',
            '-H', 'content-type: application/json',
            '-d', body,
        },
        on_exit = vim.schedule_wrap(function(j, return_val)
            if return_val == 0 then
                local result = table.concat(j:result(), "")
                local ok, decoded = pcall(vim.fn.json_decode, result)
                if ok and decoded.content and decoded.content[1] then
                    callback(decoded.content[1].text)
                else
                    vim.notify("Failed to parse LLM response", vim.log.levels.ERROR)
                    callback(nil)
                end
            else
                vim.notify("Failed to get LLM response", vim.log.levels.ERROR)
                callback(nil)
            end
        end),
    })

    job:start()
end

-- Function to create application plan
---@param code_blocks string[] Array of code blocks to apply
---@param target_buffers number[] Array of target buffer numbers
function M.create_plan(code_blocks, target_buffers)
    -- Create the plan buffer immediately with help text and initial message
    local bufnr = create_plan_buffer("Generating plan...")

    -- Start thinking indicator
    local main = require('llmancer.main')
    local stop_thinking = main.create_thinking_indicator(bufnr)

    -- Prepare buffer context
    local buffer_context = {}
    for _, bufnr in ipairs(target_buffers) do
        local filename = vim.api.nvim_buf_get_name(bufnr)
        table.insert(buffer_context,
            "Filename " .. filename .. " content:\n```\n" .. get_buffer_content(bufnr) .. "\n```")
    end

    -- Build prompt
    local prompt = [[
      You are about to receive:
        - Some code the user wants to apply to some files, or create new files from.
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

      Here's the code to apply:

    ]] .. table.concat(code_blocks, "\n\n") .. [[

      Here are the current files:

    ]] .. table.concat(buffer_context, "\n\n") .. [[

      Now generate the operations to apply to the files.

      REMEMBER:
      - you are to return only the set of operations, that is, ONLY CODE! nothing that's not code. Don't put anything else outside the blocks besides the header info.
      - when inserting text, consider the whitespace around the code you'll be inserting. For instance, you may want to have some blank lines in the code block you'll insert if it will result in properly formatted text once inserted.
      - remember to include the language at the backticks, e.g. ```javascript because we use it for syntax highlighting.
      - please try to use the `write` operation the most. When doing so remember to return the entirety of the changed file content.
      - you must always use the available operations. each code block must be either a write block or a replace block. and you must always include the file: and operation: header info.
    ]]

    -- Get operations from LLM and update the buffer
    get_operations_from_llm(prompt, function(response)
        -- Stop thinking indicator
        stop_thinking()

        if response then
            -- Update buffer content with response only (help text is already there)
            local lines = vim.split(response, '\n')
            vim.api.nvim_buf_set_lines(bufnr, #vim.split(HELP_TEXT, '\n'), -1, false, lines)
        else
            -- Show error message (help text is already there)
            vim.api.nvim_buf_set_lines(bufnr, #vim.split(HELP_TEXT, '\n'), -1, false, { "Failed to get plan from LLM" })
        end
    end)

    return bufnr
end

-- Make create_plan_buffer available to other modules
M.create_plan_buffer = create_plan_buffer

return M
