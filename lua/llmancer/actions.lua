local M = {}

-- List of available actions
local actions = {
    {
        name = "Apply to Alternate Buffer",
        description = "Apply code to the alternate buffer (#)",
        callback = function(code_block)
            local alt_bufnr = vim.fn.bufnr("#")
            if alt_bufnr == -1 then
                vim.notify("No alternate buffer available", vim.log.levels.ERROR)
                return
            end
            
            require('llmancer.application_plan').create_plan(
                {code_block},
                {alt_bufnr}
            )
        end
    },
    {
        name = "Apply to Selected Buffer",
        description = "Apply code to a selected buffer",
        callback = function(code_block)
            -- Get list of buffers
            local bufs = vim.tbl_filter(function(bufnr)
                return vim.api.nvim_buf_is_loaded(bufnr)
                    and vim.bo[bufnr].buftype == ""  -- Regular files only
            end, vim.api.nvim_list_bufs())
            
            -- Format buffer items for selection
            local items = vim.tbl_map(function(bufnr)
                local name = vim.api.nvim_buf_get_name(bufnr)
                return {
                    bufnr = bufnr,
                    display = string.format("%d: %s", bufnr, name ~= "" and name or "[No Name]")
                }
            end, bufs)
            
            -- Show buffer selection
            vim.ui.select(
                items,
                {
                    prompt = "Select target buffer:",
                    format_item = function(item)
                        return item.display
                    end
                },
                function(choice)
                    if choice then
                        require('llmancer.application_plan').create_plan(
                            {code_block},
                            {choice.bufnr}
                        )
                    end
                end
            )
        end
    }
}

-- Function to get the code block under cursor
local function get_code_block_under_cursor()
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local start_line = cursor_line
    local end_line = cursor_line
    
    -- Search backwards for code block start
    while start_line > 1 and not lines[start_line-1]:match("^```") do
        start_line = start_line - 1
    end
    
    -- Search forwards for code block end
    while end_line < #lines and not lines[end_line+1]:match("^```") do
        end_line = end_line + 1
    end
    
    -- Check if we're actually in a code block
    if start_line >= 1 and end_line <= #lines and 
       lines[start_line-1]:match("^```") and lines[end_line+1]:match("^```") then
        -- Extract the code block content and language
        local lang = lines[start_line-1]:match("^```(.+)$")
        local block = table.concat(vim.list_slice(lines, start_line, end_line), "\n")
        return block, lang
    end
    
    return nil
end

-- Function to show actions picker
function M.show_actions()
    local code_block = get_code_block_under_cursor()
    if not code_block then
        vim.notify("No code block found under cursor", vim.log.levels.WARN)
        return
    end
    
    -- Format actions for display
    local action_items = vim.tbl_map(function(action)
        return {
            name = action.name,
            description = action.description,
            callback = action.callback,
            display = string.format("%s - %s", action.name, action.description)
        }
    end, actions)

    -- Show vim.ui.select menu
    vim.ui.select(
        action_items,
        {
            prompt = "Select action:",
            format_item = function(item)
                return item.display
            end
        },
        function(choice)
            if choice then
                choice.callback(code_block)
            end
        end
    )
end

return M 