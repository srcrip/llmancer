.PHONY: test lint format check

test:
	@echo "Running tests..."
	nvim --headless -c "PlenaryBustedDirectory tests/llmancer/ {minimal_init = 'tests/minimal_init.lua'}"

lint:
	luacheck .

format-check:
	stylua --check .

format:
	stylua .

check: test lint format-check
