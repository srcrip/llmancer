-- au BufNewFile,BufRead LLMancer-Plan-* setf llmancer_plan

vim.api.nvim_create_autocmd({ "BufNewFile", "BufRead" }, {
  group = "llmancer_detect",
  pattern = "LLMancer-Plan-*",
  callback = function(ev)
    vim.bo[ev.buf].filetype = "llmancer_plan"
  end,
})
