" Quit when a syntax file was already loaded
if exists("b:current_syntax")
  finish
endif

" Load markdown syntax as a base
runtime! syntax/markdown.vim
unlet! b:current_syntax

" Load Lua syntax for the params section
syntax include @Lua syntax/lua.vim

" Define the params section region
syntax region llmancerParams start=/^---$/ end=/^---$/ contains=@Lua

" LLMancer-specific syntax patterns
" Match exact user prompt format with number
syntax match llmancerUser "^user (\d\+): " contains=llmancerUserNumber
syntax match llmancerUserNumber "(\d\+)" contained

" Match exact assistant prompt format for Claude models
syntax match llmancerAssistant "^claude-[0-9a-z-]\+: "

" Other syntax elements
syntax match llmancerSeparator /^----------------------------------------$/
syntax match llmancerHelpHeader /^Welcome to LLMancer.nvim! 🤖$/
syntax match llmancerHelpModel /^Currently using: .\+$/
syntax match llmancerHelpCommand /^- \zs<.\{-}>\ze[^<>]*$/

" Highlighting
highlight default link llmancerUser Type
highlight default link llmancerUserNumber Number
highlight default link llmancerAssistant Identifier
highlight default link llmancerSeparator Comment
highlight default link llmancerHelpHeader Title
highlight default link llmancerHelpModel Special
highlight default link llmancerHelpCommand Special
highlight default link llmancerParams Special

let b:current_syntax = "llmancer"