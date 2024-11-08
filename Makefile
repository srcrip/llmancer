.PHONY: test lint format check

test:
	@echo "Running tests..."
	timeout 300 nvim -e \
		--headless \
		--noplugin \
		-u specs/spec.lua \
		-c "PlenaryBustedDirectory specs/features {minimal_init = 'specs/spec.lua'}"

lint:
	luacheck .

format:
	stylua --check .

check: test lint format
