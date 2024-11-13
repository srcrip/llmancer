local M = {}

-- Create a test buffer with content
---@param content string[] Lines of content
---@param opts? {filetype?: string, name?: string} Buffer options
---@return number bufnr The buffer number
function M.create_test_buffer(content, opts)
    opts = opts or {}
    local bufnr = vim.api.nvim_create_buf(false, true)

    if content then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
    end

    if opts.filetype then
        vim.bo[bufnr].filetype = opts.filetype
    end

    if opts.name then
        vim.api.nvim_buf_set_name(bufnr, opts.name)
    end

    return bufnr
end

-- Reset the test environment
function M.reset_env()
    -- Clear all buffers except the current one
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) and not vim.api.nvim_buf_get_option(bufnr, 'modified') then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end
end

return M
