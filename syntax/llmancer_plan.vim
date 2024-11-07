if exists("b:current_syntax")
    finish
endif

" Highlight operation headers
syntax match llmancerPlanFile "^file:.*$" contains=llmancerPlanLabel
syntax match llmancerPlanOperation "^operation:.*$" contains=llmancerPlanLabel
syntax match llmancerPlanStart "^start:.*$" contains=llmancerPlanLabel
syntax match llmancerPlanEnd "^end:.*$" contains=llmancerPlanLabel
syntax match llmancerPlanLabel "^[^:]\+:" contained

" Highlight code blocks
syntax region llmancerPlanCode start="^```" end="^```$" contains=@Markdown

" Help text at the top
syntax region llmancerPlanHelp start="^Apply Changes:" end="^$" contains=llmancerPlanHelpKey
syntax match llmancerPlanHelpKey "<[^>]\+>" contained

" Link to markdown for nested syntax
runtime! syntax/markdown.vim
unlet! b:current_syntax

" Define highlighting
highlight default link llmancerPlanFile Type
highlight default link llmancerPlanOperation Keyword
highlight default link llmancerPlanStart Number
highlight default link llmancerPlanEnd Number
highlight default link llmancerPlanLabel Label
highlight default link llmancerPlanCode String
highlight default link llmancerPlanHelp Comment
highlight default link llmancerPlanHelpKey Special

let b:current_syntax = "llmancer_plan" 