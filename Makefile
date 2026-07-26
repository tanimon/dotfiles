.PHONY: lint secretlint shellcheck shfmt oxlint oxfmt actionlint zizmor test-modify test-scripts check-templates scan-sensitive test-sensitive test-harness-scripts test-nono-profile

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

ALL_MD_FILES := $(shell find . \( -path './node_modules' -o -path './.git' -o -path './.superpowers' \) -prune -o \
	-type f -name '*.md' -print 2>/dev/null)

## Run all checks (mirrors CI)
lint: secretlint shellcheck shfmt oxlint oxfmt actionlint zizmor test-modify test-scripts check-templates scan-sensitive test-sensitive test-harness-scripts test-nono-profile

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
	pnpm exec bats test/modify-dot-claude.bats test/modify-karabiner.bats

## Smoke test hook scripts
test-scripts:
	LC_ALL=C pnpm exec bats test/notify.bats

## Validate chezmoi templates
check-templates:
	@if command -v chezmoi >/dev/null 2>&1; then \
		echo "Validating chezmoi templates..."; \
		tmpconfig=$$(mktemp "$${TMPDIR:-/tmp}/chezmoi-test-XXXXXX.toml") || { echo "FAIL: mktemp failed"; exit 1; }; \
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

## Scan all .md files for sensitive information (PII, credentials, absolute paths)
scan-sensitive:
	@if [ -n "$(ALL_MD_FILES)" ]; then \
		echo "Running scan-sensitive-info..."; \
		bash scripts/scan-sensitive-info.sh $(ALL_MD_FILES); \
	else \
		echo "No .md files found"; \
	fi

## Smoke test scan-sensitive-info.sh
test-sensitive:
	@echo "Testing scan-sensitive-info.sh..."
	@SCRIPT="$$(pwd)/scripts/scan-sensitive-info.sh"; \
	tmpdir=$$(mktemp -d "$${TMPDIR:-/tmp}/test-sensitive-XXXXXX") || { echo "FAIL: mktemp failed"; exit 1; }; \
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

## Smoke test harness loop scripts (reflect-trigger, briefing, doctor)
test-harness-scripts:
	pnpm exec bats test/harness-reflect-trigger.bats test/harness-briefing.bats test/harness-doctor.bats

## Validate the nono sandbox profile (local only — CI does not install nono)
test-nono-profile:
	@if command -v nono >/dev/null 2>&1; then \
		echo "Validating nono profile..."; \
		nono profile validate dot_config/nono/profiles/claude-seal.json \
			|| { echo "FAIL: claude-seal.json is not a valid nono profile"; exit 1; }; \
		echo "PASS: nono profile valid"; \
	else \
		echo "WARNING: nono not found, skipping nono profile validation"; \
	fi
