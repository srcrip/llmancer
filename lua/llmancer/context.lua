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

-- Helper function to get all files in directory recursively
---@param dir string Directory path
---@param exclude_patterns string[] Patterns to exclude
---@return string[]
local function get_files_recursive(dir, exclude_patterns)
    local files = {}
    exclude_patterns = exclude_patterns or {
        "%.git/",
        "node_modules/",
        "%.DS_Store$",
        "%.pyc$",
        "__pycache__/",
        "%.o$",
        "%.obj$",
        "%.class$"
    }
    
    local handle = io.popen('find "' .. dir .. '" -type f 2>/dev/null')
    if not handle then return {} end
    
    for file in handle:lines() do
        local exclude = false
        for _, pattern in ipairs(exclude_patterns) do
            if file:match(pattern) then
                exclude = true
                break
            end
        end
        if not exclude then
            table.insert(files, file)
        end
    end
    
    handle:close()
    return files
end

-- Function to get all files in the codebase
---@return string[]
function M.codebase()
    local root = get_git_root() or vim.fn.getcwd()
    return get_files_recursive(root)
end

return M 