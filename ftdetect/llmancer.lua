-- Clear any existing autocommands for llmancer
vim.api.nvim_create_augroup("llmancer_detect", { clear = true })

-- Set up filetype detection
vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
  group = "llmancer_detect",
  pattern = "*.llmc",
  callback = function(ev)
    vim.bo[ev.buf].filetype = "llmancer"
  end,
})

-- Also register with the filetype system
vim.filetype.add({
  extension = {
    llmc = "llmancer"
  },
})

