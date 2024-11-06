; Treat buffer as markdown
((source_file) @markdown
 (#set! injection.language "markdown"))

; Handle code blocks with language
(fenced_code_block
  (info_string (language) @language)
  (code_fence_content) @injection.content
  (#inject! @injection.content @language))