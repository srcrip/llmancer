globals = {
    "vim",
    "describe",
    "it",
    "before_each",
    "after_each",
    "assert"
}

ignore = {
    "212", -- Unused argument
    "631", -- Line is too long
}

exclude_files = {
    "lua/plenary/*",
    ".luarocks/*",
    ".github/*",
    "test/*",
} 