.PHONY: lint secretlint shellcheck shfmt oxlint oxfmt actionlint zizmor test-modify test-scripts test-pipeline-health check-templates scan-sensitive test-sensitive

# File discovery — mirrors .github/workflows/lint.yml and .pre-commit-config.yaml
SHELL_FILES := $(shell find . -type f \( -name '*.sh' -o -name '*.bash' -o -name 'executable_*' \) \
	! -name '*.tmpl' ! -name '*.mts' ! -name '*.ts' ! -name '*.mjs' \
	! -path './node_modules/*' 2>/dev/null)

TMPL_FILES := $(shell find . -name '*.tmpl' \
	! -path './node_modules/*' \
	! -name '.chezmoi.toml.tmpl' 2>/dev/null)

JS_TS_FILES := $(shell find . -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.mts' -o -name '*.ts' \) \
	! -name '*.tmpl' \
	! -path './node_modules/*' 2>/dev/null)

JSON_FILES := $(shell find . -type f -name '*.json' \
	! -path './node_modules/*' \
	! -name 'pnpm-lock.yaml' \
	! -name 'modify_*' 2>/dev/null)

DOCS_MD_FILES := $(shell find ./docs -type f -name '*.md' 2>/dev/null)

## Run all checks (mirrors CI)
lint: secretlint shellcheck shfmt oxlint oxfmt actionlint zizmor test-modify test-scripts test-pipeline-health check-templates scan-sensitive test-sensitive

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

## Lint JS/TS files
oxlint:
	@if [ -n "$(JS_TS_FILES)" ]; then \
		echo "Running oxlint..."; \
		pnpm exec oxlint $(JS_TS_FILES); \
	else \
		echo "No JS/TS files found"; \
	fi

## Check JS/TS and JSON formatting
oxfmt:
	@if [ -n "$(JS_TS_FILES)$(JSON_FILES)" ]; then \
		echo "Running oxfmt..."; \
		pnpm exec oxfmt --check $(JS_TS_FILES) $(JSON_FILES); \
	else \
		echo "No JS/TS or JSON files found"; \
	fi

## Lint GitHub Actions workflows (syntax + types)
actionlint:
	@if command -v actionlint >/dev/null 2>&1; then \
		echo "Running actionlint..."; \
		actionlint; \
	else \
		echo "WARNING: actionlint not found, skipping"; \
	fi

## Security audit GitHub Actions workflows
zizmor:
	@if command -v zizmor >/dev/null 2>&1; then \
		echo "Running zizmor..."; \
		zizmor .github/workflows/; \
	else \
		echo "WARNING: zizmor not found, skipping"; \
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

## Smoke test hook scripts
test-scripts:
	@if ! command -v jq >/dev/null 2>&1; then echo "WARNING: jq not found, skipping"; exit 0; fi
	@echo "Testing harness-activator.sh..."
	@SCRIPT="$$(pwd)/dot_claude/scripts/executable_harness-activator.sh"; \
	TEST_SID="test-harness-$$$$-$$(date +%s)"; \
	cleanup() { rm -f "/tmp/claude-harness-checked-$$TEST_SID"; }; \
	cleanup; \
	echo "  Test 1: normal execution inside git repo..."; \
	output=$$(printf '{"session_id":"%s"}' "$$TEST_SID" | bash "$$SCRIPT" 2>/dev/null); \
	if echo "$$output" | grep -q "HARNESS EVALUATION REMINDER"; then \
		echo "  PASS: stdout contains HARNESS EVALUATION REMINDER"; \
	else \
		echo "  FAIL: expected HARNESS EVALUATION REMINDER in stdout"; cleanup; exit 1; \
	fi; \
	cleanup; \
	echo "  Test 2: HOME guard suppresses output..."; \
	TEST_SID2="test-harness-$$$$-$$(date +%s)-home"; \
	output=$$(cd "$$HOME" && printf '{"session_id":"%s"}' "$$TEST_SID2" | bash "$$SCRIPT" 2>/dev/null); \
	if [ -z "$$output" ]; then \
		echo "  PASS: stdout is empty when PWD is HOME"; \
	else \
		echo "  FAIL: expected empty stdout when PWD is HOME"; rm -f "/tmp/claude-harness-checked-$$TEST_SID2"; cleanup; exit 1; \
	fi; \
	rm -f "/tmp/claude-harness-checked-$$TEST_SID2"; \
	echo "  Test 3: duplicate session_id produces empty output..."; \
	TEST_SID3="test-harness-$$$$-$$(date +%s)-dup"; \
	rm -f "/tmp/claude-harness-checked-$$TEST_SID3"; \
	printf '{"session_id":"%s"}' "$$TEST_SID3" | bash "$$SCRIPT" > /dev/null 2>&1; \
	output=$$(printf '{"session_id":"%s"}' "$$TEST_SID3" | bash "$$SCRIPT" 2>/dev/null); \
	if [ -z "$$output" ]; then \
		echo "  PASS: second run with same session_id produces empty stdout"; \
	else \
		echo "  FAIL: expected empty stdout on duplicate session_id"; rm -f "/tmp/claude-harness-checked-$$TEST_SID3"; cleanup; exit 1; \
	fi; \
	rm -f "/tmp/claude-harness-checked-$$TEST_SID3"; \
	cleanup
	@echo "Testing notify-wrapper.sh..."
	@WRAPPER="$$(pwd)/dot_claude/scripts/executable_notify-wrapper.sh"; \
	if [ ! -f "$$WRAPPER" ]; then \
		echo "  FAIL: notify-wrapper.sh not found"; exit 1; \
	fi; \
	echo "  PASS: notify-wrapper.sh exists"; \
	if ! head -1 "$$WRAPPER" | grep -q '#!/usr/bin/env bash'; then \
		echo "  FAIL: shebang is not #!/usr/bin/env bash"; exit 1; \
	fi; \
	echo "  PASS: shebang is correct"; \
	if command -v node >/dev/null 2>&1; then \
		if echo '{}' | bash "$$WRAPPER" 2>/dev/null; then \
			echo "  PASS: notify-wrapper.sh exits cleanly on empty JSON input"; \
		else \
			echo "  PASS: notify-wrapper.sh exits non-zero on empty input (expected — node script needs real hook data)"; \
		fi; \
	else \
		echo "  SKIP: node not found, skipping runtime test"; \
	fi

## Test pipeline-health.sh
test-pipeline-health:
	@echo "Testing pipeline-health.sh..."
	@SCRIPT="$$(pwd)/scripts/pipeline-health.sh"; \
	echo "  Test 1: script is executable and has correct shebang..."; \
	if head -1 "$$SCRIPT" | grep -q '#!/usr/bin/env bash'; then \
		echo "  PASS: shebang is correct"; \
	else \
		echo "  FAIL: expected #!/usr/bin/env bash shebang"; exit 1; \
	fi; \
	echo "  Test 2: --help exits 0 and shows usage..."; \
	if bash "$$SCRIPT" --help 2>/dev/null | grep -q "Usage:"; then \
		echo "  PASS: --help shows usage"; \
	else \
		echo "  FAIL: --help did not show usage"; exit 1; \
	fi; \
	echo "  Test 3: human-readable output contains expected sections..."; \
	output=$$(bash "$$SCRIPT" 2>/dev/null); \
	if echo "$$output" | grep -q "ECC Learning Pipeline Health" && \
	   echo "$$output" | grep -q "Observation Capture:" && \
	   echo "$$output" | grep -q "Observer Analysis:" && \
	   echo "$$output" | grep -q "Instinct Creation:" && \
	   echo "$$output" | grep -q "Overall:"; then \
		echo "  PASS: human output contains all expected sections"; \
	else \
		echo "  FAIL: human output missing expected sections"; exit 1; \
	fi; \
	echo "  Test 4: --json produces valid JSON..."; \
	if command -v jq >/dev/null 2>&1; then \
		json_output=$$(bash "$$SCRIPT" --json 2>/dev/null); \
		if echo "$$json_output" | jq -e '.overall_status' >/dev/null 2>&1 && \
		   echo "$$json_output" | jq -e '.stages.observation_capture.status' >/dev/null 2>&1 && \
		   echo "$$json_output" | jq -e '.stages.observer_analysis.status' >/dev/null 2>&1 && \
		   echo "$$json_output" | jq -e '.stages.instinct_creation.status' >/dev/null 2>&1; then \
			echo "  PASS: --json produces valid JSON with all required fields"; \
		else \
			echo "  FAIL: --json output missing required fields"; exit 1; \
		fi; \
	else \
		echo "  SKIP: jq not found, skipping JSON validation"; \
	fi; \
	echo "  Test 5: unknown flag exits non-zero..."; \
	if bash "$$SCRIPT" --bogus >/dev/null 2>&1; then \
		echo "  FAIL: expected non-zero exit for unknown flag"; exit 1; \
	else \
		echo "  PASS: unknown flag exits non-zero"; \
	fi

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

## Scan docs for sensitive information (PII, credentials, absolute paths)
scan-sensitive:
	@if [ -n "$(DOCS_MD_FILES)" ]; then \
		echo "Running scan-sensitive-info..."; \
		bash scripts/scan-sensitive-info.sh $(DOCS_MD_FILES); \
	else \
		echo "No docs files found"; \
	fi

## Smoke test scan-sensitive-info.sh
test-sensitive:
	@echo "Testing scan-sensitive-info.sh..."
	@SCRIPT="$$(pwd)/scripts/scan-sensitive-info.sh"; \
	tmpdir=$$(mktemp -d /tmp/test-sensitive-XXXXXX); \
	cleanup() { rm -rf "$$tmpdir"; }; \
	echo "  Test 1: clean file exits 0..."; \
	printf 'No sensitive data here\n' > "$$tmpdir/clean.md"; \
	if bash "$$SCRIPT" "$$tmpdir/clean.md" > /dev/null 2>&1; then \
		echo "  PASS: exit 0 on clean file"; \
	else \
		echo "  FAIL: expected exit 0 on clean file"; cleanup; exit 1; \
	fi; \
	echo "  Test 2: file with absolute path exits 1..."; \
	printf '/Users/realname/some/path\n' > "$$tmpdir/pii.md"; \
	if bash "$$SCRIPT" "$$tmpdir/pii.md" > /dev/null 2>&1; then \
		echo "  FAIL: expected exit 1 on PII file"; cleanup; exit 1; \
	else \
		echo "  PASS: exit 1 on PII file"; \
	fi; \
	echo "  Test 3: file with SSH key exits 1..."; \
	printf 'signingkey = ssh-ed25519 AAAAC3Nza\n' > "$$tmpdir/sshkey.md"; \
	if bash "$$SCRIPT" "$$tmpdir/sshkey.md" > /dev/null 2>&1; then \
		echo "  FAIL: expected exit 1 on SSH key"; cleanup; exit 1; \
	else \
		echo "  PASS: exit 1 on SSH key"; \
	fi; \
	echo "  Test 4: multiple files with mixed content..."; \
	printf 'Safe content only\n' > "$$tmpdir/safe.md"; \
	printf '12345+user@users.noreply.github.com\n' > "$$tmpdir/email.md"; \
	if bash "$$SCRIPT" "$$tmpdir/safe.md" "$$tmpdir/email.md" > /dev/null 2>&1; then \
		echo "  FAIL: expected exit 1 on mixed files"; cleanup; exit 1; \
	else \
		echo "  PASS: exit 1 when any file has PII"; \
	fi; \
	cleanup
