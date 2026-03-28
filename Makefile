.PHONY: lint secretlint shellcheck shfmt test-modify check-templates

# File discovery — mirrors .github/workflows/lint.yml and .pre-commit-config.yaml
SHELL_FILES := $(shell find . -type f \( -name '*.sh' -o -name '*.bash' -o -name 'executable_*' \) \
	! -name '*.tmpl' ! -name '*.mts' ! -name '*.ts' ! -name '*.mjs' \
	! -path './node_modules/*' 2>/dev/null)

TMPL_FILES := $(shell find . -name '*.tmpl' \
	! -path './node_modules/*' \
	! -name '.chezmoi.toml.tmpl' 2>/dev/null)

## Run all checks (mirrors CI)
lint: secretlint shellcheck shfmt test-modify check-templates

## Scan for leaked secrets
secretlint:
	@pnpm exec secretlint '**/*'

## Lint shell scripts
shellcheck:
	@if command -v shellcheck >/dev/null 2>&1; then \
		if [ -n "$(SHELL_FILES)" ]; then \
			echo "Running shellcheck..."; \
			shellcheck $(SHELL_FILES); \
		else \
			echo "No shell files found"; \
		fi; \
	else \
		echo "WARNING: shellcheck not found, skipping"; \
	fi

## Check shell script formatting
shfmt:
	@if command -v shfmt >/dev/null 2>&1; then \
		if [ -n "$(SHELL_FILES)" ]; then \
			echo "Running shfmt..."; \
			shfmt -d -i 4 $(SHELL_FILES); \
		else \
			echo "No shell files found"; \
		fi; \
	else \
		echo "WARNING: shfmt not found, skipping"; \
	fi

## Smoke test modify_ scripts
test-modify:
	@echo "Testing modify_dot_claude.json..."
	@export CHEZMOI_SOURCE_DIR="$$(pwd)"; \
	output=$$(printf '{"existingKey":"value","mcpServers":{}}' | bash modify_dot_claude.json); \
	echo "$$output" | jq empty || { echo "FAIL: output is not valid JSON"; exit 1; }; \
	echo "$$output" | jq -e '.existingKey == "value"' > /dev/null || { echo "FAIL: existingKey not preserved"; exit 1; }; \
	echo "$$output" | jq -e '.mcpServers | has("notion")' > /dev/null || { echo "FAIL: mcpServers not replaced"; exit 1; }; \
	echo "PASS: existing data preserved, mcpServers replaced"
	@export CHEZMOI_SOURCE_DIR="$$(pwd)"; \
	output=$$(printf '' | bash modify_dot_claude.json); \
	echo "$$output" | jq empty || { echo "FAIL: empty stdin not valid JSON"; exit 1; }; \
	echo "$$output" | jq -e 'has("mcpServers")' > /dev/null || { echo "FAIL: mcpServers missing for empty stdin"; exit 1; }; \
	echo "PASS: empty stdin produces valid JSON with mcpServers"
	@export CHEZMOI_SOURCE_DIR="/tmp/nonexistent-dir"; \
	input='{"existingKey":"keep","mcpServers":{"old":"data"}}'; \
	output=$$(printf '%s' "$$input" | bash modify_dot_claude.json 2>/dev/null); \
	if [ "$$output" != "$$input" ]; then \
		echo "FAIL: missing source file should passthrough stdin"; exit 1; \
	fi; \
	echo "PASS: missing source file passes through stdin"

## Validate chezmoi templates
check-templates:
	@if command -v chezmoi >/dev/null 2>&1; then \
		echo "Validating chezmoi templates..."; \
		tmpconfig=$$(mktemp /tmp/chezmoi-test-XXXXXX.toml); \
		printf '[data]\n  profile = "personal"\n  ghOrg = "test-org"\n' > "$$tmpconfig"; \
		fail=0; \
		for file in $(TMPL_FILES); do \
			chezmoi execute-template \
				--config "$$tmpconfig" \
				--source "$$(pwd)" \
				< "$$file" > /dev/null || { echo "FAIL: $$file"; fail=1; }; \
		done; \
		rm -f "$$tmpconfig"; \
		if [ "$$fail" -eq 1 ]; then exit 1; fi; \
		echo "PASS: all templates valid"; \
	else \
		echo "WARNING: chezmoi not found, skipping template validation"; \
	fi
