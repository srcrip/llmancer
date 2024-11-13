local M = {}

-- Helper function to get git root directory
---@return string|nil
local function get_git_root()
    local handle = io.popen("git rev-parse --show-toplevel 2>/dev/null")
    if not handle then return nil end

    local result = handle:read("*a")
    handle:close()

    if result then
        return vim.trim(result)
    end
    return nil
end

-- Helper function to get all files using tree command
---@param dir string Directory path
---@return string, string[] Returns tree output and list of files
local function get_files_with_tree(dir)
    -- Run tree command with full formatting:
    -- -f: Print full path prefix for each file
    -- -a: Show all files (including hidden)
    -- --noreport: Don't print file/directory report at the end
    local handle = io.popen('tree -f -a --noreport "' .. dir .. '" 2>/dev/null')
    if not handle then return "", {} end

    local tree_output = {}
    local files = {}
    local exclude_patterns = {
        "%.git/",
        "node_modules/",
        "%.DS_Store$",
        "%.pyc$",
        "__pycache__/",
        "%.o$",
        "%.obj$",
        "%.class$",
        "%.swp$",
        "%.swo$"
    }

    for line in handle:lines() do
        -- Extract the file path from the tree output line
        local file_path = line:match("── (.+)$")

        if file_path then
            local exclude = false
            for _, pattern in ipairs(exclude_patterns) do
                if file_path:match(pattern) then
                    exclude = true
                    break
                end
            end

            if not exclude then
                table.insert(files, file_path)
                table.insert(tree_output, line)
            end
        else
            -- If no file path found, it's a directory line
            table.insert(tree_output, line)
        end
    end

    handle:close()
    return table.concat(tree_output, '\n'), files
end

-- Function to get all files in the codebase with their contents
---@return string A formatted string containing all file contents
function M.codebase()
    local root = get_git_root() or vim.fn.getcwd()
    local tree_output, files = get_files_with_tree(root)
    local contents = {}

    -- Start with the tree output
    table.insert(contents, "Project Structure:\n" .. tree_output)

    -- Add each file's contents
    for _, file in ipairs(files) do
        -- Only read if it's a regular file and readable
        if vim.fn.filereadable(file) == 1 then
            -- Read file contents
            local lines = vim.fn.readfile(file)
            if lines then
                table.insert(contents, string.format("\nFile: %s\n\n%s", file, table.concat(lines, '\n')))
            end
        end
    end

    return table.concat(contents, "\n")
end

return M
