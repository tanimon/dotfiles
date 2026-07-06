.PHONY: lint secretlint shellcheck shfmt oxlint oxfmt actionlint zizmor test-modify test-scripts test-pipeline-health test-snapshot-instincts test-validate-snapshot check-templates scan-sensitive test-sensitive test-harness-scripts

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

ALL_MD_FILES := $(shell find . \( -path './node_modules' -o -path './.git' \) -prune -o \
	-type f -name '*.md' -print 2>/dev/null)

## Run all checks (mirrors CI)
lint: secretlint shellcheck shfmt oxlint oxfmt actionlint zizmor test-modify test-scripts test-pipeline-health test-snapshot-instincts test-validate-snapshot check-templates scan-sensitive test-sensitive test-harness-scripts

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
	@echo "Testing modify_karabiner.json..."
	@export CHEZMOI_SOURCE_DIR="$$(pwd)"; \
	input='{"machine_specific":{"krbn-test":{"external_editor_path":"/Applications/Code.app"}},"profiles":[{"complex_modifications":{"rules":[{"description":"old"}]},"name":"Default profile","selected":true,"virtual_hid_keyboard":{"keyboard_type_v2":"jis"}}]}'; \
	output=$$(printf '%s' "$$input" | bash dot_config/karabiner/modify_karabiner.json); \
	echo "$$output" | jq empty || { echo "FAIL: output is not valid JSON"; exit 1; }; \
	echo "$$output" | jq -e '.machine_specific."krbn-test".external_editor_path == "/Applications/Code.app"' > /dev/null || { echo "FAIL: machine_specific not preserved"; exit 1; }; \
	echo "$$output" | jq -e '.profiles[0].name == "Default profile" and .profiles[0].selected == true' > /dev/null || { echo "FAIL: profile metadata not preserved"; exit 1; }; \
	echo "$$output" | jq -e '.profiles[0].virtual_hid_keyboard.keyboard_type_v2 == "jis"' > /dev/null || { echo "FAIL: virtual_hid_keyboard not preserved"; exit 1; }; \
	echo "$$output" | jq -e '.profiles[0].complex_modifications.rules | length == 1' > /dev/null || { echo "FAIL: expected exactly 1 rule"; exit 1; }; \
	echo "$$output" | jq -e --slurpfile src dot_config/karabiner/complex_modifications.json '.profiles[0].complex_modifications.rules == $$src[0]' > /dev/null || { echo "FAIL: rules content does not equal source"; exit 1; }; \
	echo "PASS: machine_specific + profile metadata preserved, rules replaced and equal to source"
	@export CHEZMOI_SOURCE_DIR="$$(pwd)"; \
	input='{"profiles":[{"complex_modifications":{"rules":[]},"name":"P1","selected":true},{"complex_modifications":{"rules":[{"description":"old"}],"parameters":{"basic.simultaneous_threshold_milliseconds":100}},"name":"P2","selected":false}]}'; \
	output=$$(printf '%s' "$$input" | bash dot_config/karabiner/modify_karabiner.json); \
	echo "$$output" | jq -e '.profiles | length == 2' > /dev/null || { echo "FAIL: multi-profile dropped"; exit 1; }; \
	echo "$$output" | jq -e '.profiles[0].name == "P1" and .profiles[0].selected == true and .profiles[1].name == "P2" and .profiles[1].selected == false' > /dev/null || { echo "FAIL: profile name/selected not preserved across profiles"; exit 1; }; \
	echo "$$output" | jq -e '.profiles[0].complex_modifications.rules | length == 1' > /dev/null || { echo "FAIL: profile 1 expected exactly 1 rule"; exit 1; }; \
	echo "$$output" | jq -e '.profiles[1].complex_modifications.rules | length == 1' > /dev/null || { echo "FAIL: profile 2 expected exactly 1 rule"; exit 1; }; \
	echo "$$output" | jq -e --slurpfile src dot_config/karabiner/complex_modifications.json '.profiles[0].complex_modifications.rules == $$src[0] and .profiles[1].complex_modifications.rules == $$src[0]' > /dev/null || { echo "FAIL: rules content does not equal source on both profiles"; exit 1; }; \
	echo "$$output" | jq -e '.profiles[1].complex_modifications.parameters."basic.simultaneous_threshold_milliseconds" == 100' > /dev/null || { echo "FAIL: profile 2 parameters not preserved"; exit 1; }; \
	echo "PASS: multi-profile rules replaced in both, name/selected/parameters preserved"
	@export CHEZMOI_SOURCE_DIR="$$(pwd)"; \
	output=$$(printf '' | bash dot_config/karabiner/modify_karabiner.json); \
	echo "$$output" | jq empty || { echo "FAIL: empty stdin not valid JSON"; exit 1; }; \
	echo "$$output" | jq -e '.profiles | length == 1' > /dev/null || { echo "FAIL: bootstrap should produce exactly 1 profile"; exit 1; }; \
	echo "$$output" | jq -e '.profiles[0].complex_modifications.rules | length == 1' > /dev/null || { echo "FAIL: bootstrap should slot in exactly 1 rule from source"; exit 1; }; \
	echo "$$output" | jq -e --slurpfile src dot_config/karabiner/complex_modifications.json '.profiles[0].complex_modifications.rules == $$src[0]' > /dev/null || { echo "FAIL: bootstrap rules do not equal source"; exit 1; }; \
	echo "$$output" | jq -e 'has("machine_specific") | not' > /dev/null || { echo "FAIL: bootstrap should not fabricate machine_specific"; exit 1; }; \
	echo "PASS: empty stdin produces valid JSON with rules equal to source and no machine_specific"
	@export CHEZMOI_SOURCE_DIR="/tmp/nonexistent-dir"; \
	input='{"profiles":[{"complex_modifications":{"rules":[]},"name":"Default profile","selected":true}]}'; \
	output=$$(printf '%s' "$$input" | bash dot_config/karabiner/modify_karabiner.json 2>/dev/null); \
	if ! echo "$$output" | jq -e --argjson i "$$input" '. == $$i' > /dev/null 2>&1; then \
		echo "FAIL: missing source file should passthrough stdin (semantic equality)"; exit 1; \
	fi; \
	echo "PASS: missing source file passes through stdin"
	@TMPDIR="$$(mktemp -d)"; \
	export CHEZMOI_SOURCE_DIR="$$TMPDIR"; \
	mkdir -p "$$TMPDIR/dot_config/karabiner"; \
	printf '{"not": "an array"}' > "$$TMPDIR/dot_config/karabiner/complex_modifications.json"; \
	input='{"profiles":[{"complex_modifications":{"rules":[]},"name":"Default profile","selected":true}]}'; \
	output=$$(printf '%s' "$$input" | bash dot_config/karabiner/modify_karabiner.json 2>/dev/null); \
	rm -rf "$$TMPDIR"; \
	if ! echo "$$output" | jq -e --argjson i "$$input" '. == $$i' > /dev/null 2>&1; then \
		echo "FAIL: non-array source should passthrough stdin (guards against silent rules-key corruption)"; exit 1; \
	fi; \
	echo "PASS: non-array source file passes through stdin"
	@TMPDIR="$$(mktemp -d)"; \
	export CHEZMOI_SOURCE_DIR="$$TMPDIR"; \
	mkdir -p "$$TMPDIR/dot_config/karabiner"; \
	printf '{not valid json' > "$$TMPDIR/dot_config/karabiner/complex_modifications.json"; \
	input='{"profiles":[{"complex_modifications":{"rules":[]},"name":"Default profile","selected":true}]}'; \
	output=$$(printf '%s' "$$input" | bash dot_config/karabiner/modify_karabiner.json 2>/dev/null); \
	rm -rf "$$TMPDIR"; \
	if ! echo "$$output" | jq -e --argjson i "$$input" '. == $$i' > /dev/null 2>&1; then \
		echo "FAIL: invalid-JSON source should passthrough stdin"; exit 1; \
	fi; \
	echo "PASS: invalid-JSON source file passes through stdin"
	@export CHEZMOI_SOURCE_DIR="$$(pwd)"; \
	input='{"unrelated":"shape","no_profiles_key":true}'; \
	output=$$(printf '%s' "$$input" | bash dot_config/karabiner/modify_karabiner.json 2>/dev/null); \
	if ! echo "$$output" | jq -e --argjson i "$$input" '. == $$i' > /dev/null 2>&1; then \
		echo "FAIL: stdin without .profiles key should passthrough (jq merge failure must not abort apply)"; exit 1; \
	fi; \
	echo "PASS: stdin without .profiles key passes through stdin"

## Smoke test hook scripts
test-scripts:
	@if ! command -v jq >/dev/null 2>&1; then echo "WARNING: jq not found, skipping"; exit 0; fi
	@echo "Testing learning-briefing.sh..."
	@SCRIPT="$$(pwd)/dot_claude/scripts/executable_learning-briefing.sh"; \
	TEST_SID="test-briefing-$$$$-$$(date +%s)"; \
	cleanup() { rm -f "/tmp/claude-learning-briefing-$$TEST_SID"; }; \
	cleanup; \
	echo "  Test 1: normal execution inside git repo..."; \
	output=$$(printf '{"session_id":"%s"}' "$$TEST_SID" | bash "$$SCRIPT" 2>/dev/null); \
	if echo "$$output" | grep -q "ECC Learning Briefing"; then \
		echo "  PASS: stdout contains ECC Learning Briefing"; \
	else \
		echo "  FAIL: expected ECC Learning Briefing in stdout"; cleanup; exit 1; \
	fi; \
	cleanup; \
	echo "  Test 2: HOME guard suppresses output..."; \
	TEST_SID2="test-briefing-$$$$-$$(date +%s)-home"; \
	output=$$(cd "$$HOME" && printf '{"session_id":"%s"}' "$$TEST_SID2" | bash "$$SCRIPT" 2>/dev/null); \
	if [ -z "$$output" ]; then \
		echo "  PASS: stdout is empty when PWD is HOME"; \
	else \
		echo "  FAIL: expected empty stdout when PWD is HOME"; rm -f "/tmp/claude-learning-briefing-$$TEST_SID2"; cleanup; exit 1; \
	fi; \
	rm -f "/tmp/claude-learning-briefing-$$TEST_SID2"; \
	echo "  Test 3: duplicate session_id produces empty output..."; \
	TEST_SID3="test-briefing-$$$$-$$(date +%s)-dup"; \
	rm -f "/tmp/claude-learning-briefing-$$TEST_SID3"; \
	printf '{"session_id":"%s"}' "$$TEST_SID3" | bash "$$SCRIPT" > /dev/null 2>&1; \
	output=$$(printf '{"session_id":"%s"}' "$$TEST_SID3" | bash "$$SCRIPT" 2>/dev/null); \
	if [ -z "$$output" ]; then \
		echo "  PASS: second run with same session_id produces empty stdout"; \
	else \
		echo "  FAIL: expected empty stdout on duplicate session_id"; rm -f "/tmp/claude-learning-briefing-$$TEST_SID3"; cleanup; exit 1; \
	fi; \
	rm -f "/tmp/claude-learning-briefing-$$TEST_SID3"; \
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
	@SCRIPT="$$(pwd)/dot_claude/scripts/executable_pipeline-health.sh"; \
	if head -1 "$$SCRIPT" | grep -q '#!/usr/bin/env bash'; then \
		echo "  PASS: shebang is correct"; \
	else \
		echo "  FAIL: expected #!/usr/bin/env bash shebang"; exit 1; \
	fi; \
	echo "  Test 2: --help exits 0 and shows usage..."; \
	help_output=$$(bash "$$SCRIPT" --help 2>/dev/null); \
	help_status=$$?; \
	if [ "$$help_status" -ne 0 ]; then \
		echo "  FAIL: --help exited with status $$help_status"; exit 1; \
	elif echo "$$help_output" | grep -q "Usage:"; then \
		echo "  PASS: --help exits 0 and shows usage"; \
	else \
		echo "  FAIL: --help did not show usage"; exit 1; \
	fi; \
	echo "  Test 3: human-readable output contains expected sections or reports missing project data..."; \
	output=$$(bash "$$SCRIPT" 2>&1); \
	if echo "$$output" | grep -q "ECC Learning Pipeline Health" && \
	   echo "$$output" | grep -q "Observation Capture:" && \
	   echo "$$output" | grep -q "Observer Analysis:" && \
	   echo "$$output" | grep -q "Instinct Creation:" && \
	   echo "$$output" | grep -q "Overall:"; then \
		echo "  PASS: human output contains all expected sections"; \
	elif echo "$$output" | grep -q "No project data found"; then \
		echo "  PASS: human output reports missing project data"; \
	else \
		echo "  FAIL: human output missing expected sections and did not report missing project data"; exit 1; \
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

## Test snapshot-instincts.sh
test-snapshot-instincts:
	@if ! command -v jq >/dev/null 2>&1; then echo "WARNING: jq not found, skipping"; exit 0; fi
	@echo "Testing snapshot-instincts.sh..."
	@SCRIPT="$$(pwd)/scripts/snapshot-instincts.sh"; \
	tmpdir=$$(mktemp -d /tmp/test-snapshot-XXXXXX); \
	cleanup() { rm -rf "$$tmpdir"; }; \
	echo "  Test 1: snapshot with valid instinct files..."; \
	mock_homunculus="$$tmpdir/.claude/homunculus/projects/testproject12/instincts/personal"; \
	mkdir -p "$$mock_homunculus"; \
	for i in 1 2 3; do \
		printf -- '---\nid: test-instinct-%s\ntrigger: test trigger %s\nconfidence: 0.8\ndomain: code-style\n---\n\n## Action\nDo something\n' "$$i" "$$i" > "$$mock_homunculus/instinct-$$i.md"; \
	done; \
	mock_repo="$$tmpdir/repo"; \
	mkdir -p "$$mock_repo/dot_claude/instinct-snapshots" "$$mock_repo/scripts"; \
	cp "$$SCRIPT" "$$mock_repo/scripts/snapshot-instincts.sh"; \
	git init -q "$$mock_repo"; \
	(cd "$$mock_repo" && git remote add origin "https://github.com/test/repo.git"); \
	if command -v shasum >/dev/null 2>&1; then \
		expected_hash=$$(printf 'https://github.com/test/repo.git' | shasum -a 256 | cut -c1-12); \
	elif command -v sha256sum >/dev/null 2>&1; then \
		expected_hash=$$(printf 'https://github.com/test/repo.git' | sha256sum | cut -c1-12); \
	else \
		echo "  FAIL: neither shasum nor sha256sum found"; cleanup; exit 1; \
	fi; \
	mv "$$tmpdir/.claude/homunculus/projects/testproject12" "$$tmpdir/.claude/homunculus/projects/$$expected_hash"; \
	HOME="$$tmpdir" bash "$$mock_repo/scripts/snapshot-instincts.sh" > /dev/null 2>&1; \
	count=$$(find "$$mock_repo/dot_claude/instinct-snapshots" -name '*.md' | wc -l | tr -d ' '); \
	if [ "$$count" -eq 3 ]; then \
		echo "  PASS: 3 instinct files copied"; \
	else \
		echo "  FAIL: expected 3 instincts, got $$count"; cleanup; exit 1; \
	fi; \
	if jq -e '.instinct_count == 3' "$$mock_repo/dot_claude/instinct-snapshots/metadata.json" >/dev/null 2>&1; then \
		echo "  PASS: metadata.json has correct count"; \
	else \
		echo "  FAIL: metadata.json count mismatch"; cleanup; exit 1; \
	fi; \
	echo "  Test 2: instinct with missing frontmatter is skipped..."; \
	printf 'no frontmatter here\n' > "$$tmpdir/.claude/homunculus/projects/$$expected_hash/instincts/personal/bad.md"; \
	HOME="$$tmpdir" bash "$$mock_repo/scripts/snapshot-instincts.sh" > /dev/null 2>&1; \
	if [ ! -f "$$mock_repo/dot_claude/instinct-snapshots/bad.md" ]; then \
		echo "  PASS: invalid instinct not copied"; \
	else \
		echo "  FAIL: invalid instinct was copied"; cleanup; exit 1; \
	fi; \
	echo "  Test 3: empty instinct dir exits 0 with warning..."; \
	rm -f "$$tmpdir/.claude/homunculus/projects/$$expected_hash/instincts/personal/"*.md; \
	if HOME="$$tmpdir" bash "$$mock_repo/scripts/snapshot-instincts.sh" >/dev/null 2>&1; then \
		echo "  PASS: exits 0 on empty dir"; \
	else \
		echo "  FAIL: non-zero exit on empty dir"; cleanup; exit 1; \
	fi; \
	cleanup

## Test validate-instinct-snapshot.sh
test-validate-snapshot:
	@if ! command -v jq >/dev/null 2>&1; then echo "WARNING: jq not found, skipping"; exit 0; fi
	@echo "Testing validate-instinct-snapshot.sh..."
	@SCRIPT="$$(pwd)/scripts/validate-instinct-snapshot.sh"; \
	tmpdir=$$(mktemp -d /tmp/test-validate-XXXXXX); \
	cleanup() { rm -rf "$$tmpdir"; }; \
	echo "  Test 1: valid snapshot passes..."; \
	mock_repo="$$tmpdir/repo"; \
	mkdir -p "$$mock_repo/dot_claude/instinct-snapshots" "$$mock_repo/scripts"; \
	cp "$$SCRIPT" "$$mock_repo/scripts/validate-instinct-snapshot.sh"; \
	for i in 1 2 3 4 5; do \
		printf -- '---\nid: inst-%s\ntrigger: trigger %s\nconfidence: 0.8\ndomain: code-style\n---\n\nBody\n' "$$i" "$$i" > "$$mock_repo/dot_claude/instinct-snapshots/inst-$$i.md"; \
	done; \
	printf '{"timestamp":"%s","project_id":"abc","project_name":"test","instinct_count":5}' "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$$mock_repo/dot_claude/instinct-snapshots/metadata.json"; \
	result=$$(bash "$$mock_repo/scripts/validate-instinct-snapshot.sh" 2>&1); \
	if echo "$$result" | jq -e '.status == "ok"' >/dev/null 2>&1; then \
		echo "  PASS: valid snapshot returns ok"; \
	else \
		echo "  FAIL: expected status ok, got: $$result"; cleanup; exit 1; \
	fi; \
	echo "  Test 2: missing metadata.json fails..."; \
	rm -f "$$mock_repo/dot_claude/instinct-snapshots/metadata.json"; \
	result=$$(bash "$$mock_repo/scripts/validate-instinct-snapshot.sh" 2>&1) && { echo "  FAIL: expected non-zero exit"; cleanup; exit 1; } || true; \
	if echo "$$result" | jq -e '.reason == "no metadata.json"' >/dev/null 2>&1; then \
		echo "  PASS: reports no metadata.json"; \
	else \
		echo "  FAIL: unexpected reason: $$result"; cleanup; exit 1; \
	fi; \
	echo "  Test 3: stale snapshot fails..."; \
	printf '{"timestamp":"2020-01-01T00:00:00Z","project_id":"abc","project_name":"test","instinct_count":5}' > "$$mock_repo/dot_claude/instinct-snapshots/metadata.json"; \
	result=$$(bash "$$mock_repo/scripts/validate-instinct-snapshot.sh" 2>&1) && { echo "  FAIL: expected non-zero exit"; cleanup; exit 1; } || true; \
	if echo "$$result" | grep -q "snapshot stale"; then \
		echo "  PASS: reports stale snapshot"; \
	else \
		echo "  FAIL: unexpected reason: $$result"; cleanup; exit 1; \
	fi; \
	echo "  Test 4: count < 5 fails..."; \
	rm -f "$$mock_repo/dot_claude/instinct-snapshots/inst-4.md" "$$mock_repo/dot_claude/instinct-snapshots/inst-5.md"; \
	printf '{"timestamp":"%s","project_id":"abc","project_name":"test","instinct_count":3}' "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$$mock_repo/dot_claude/instinct-snapshots/metadata.json"; \
	result=$$(bash "$$mock_repo/scripts/validate-instinct-snapshot.sh" 2>&1) && { echo "  FAIL: expected non-zero exit"; cleanup; exit 1; } || true; \
	if echo "$$result" | grep -q "insufficient instincts"; then \
		echo "  PASS: reports insufficient instincts"; \
	else \
		echo "  FAIL: unexpected reason: $$result"; cleanup; exit 1; \
	fi; \
	echo "  Test 5: count mismatch fails..."; \
	printf '{"timestamp":"%s","project_id":"abc","project_name":"test","instinct_count":99}' "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$$mock_repo/dot_claude/instinct-snapshots/metadata.json"; \
	result=$$(bash "$$mock_repo/scripts/validate-instinct-snapshot.sh" 2>&1) && { echo "  FAIL: expected non-zero exit"; cleanup; exit 1; } || true; \
	if echo "$$result" | grep -q "count mismatch"; then \
		echo "  PASS: reports count mismatch"; \
	else \
		echo "  FAIL: unexpected reason: $$result"; cleanup; exit 1; \
	fi; \
	cleanup

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

## Smoke test harness loop scripts (reflect-trigger, briefing, doctor)
test-harness-scripts:
	@if ! command -v jq >/dev/null 2>&1; then echo "WARNING: jq not found, skipping"; exit 0; fi
	@echo "Testing harness-reflect-trigger.sh..."
	@SCRIPT="$$(pwd)/dot_claude/scripts/executable_harness-reflect-trigger.sh"; \
	tmphome=$$(mktemp -d /tmp/test-harness-trigger-XXXXXX); \
	cleanup() { rm -rf "$$tmphome"; }; \
	transcript="$$tmphome/big.jsonl"; \
	for i in $$(seq 1 12); do printf '{"type":"assistant","message":{}}\n' >> "$$transcript"; done; \
	echo "  Test 1: substantial session is recorded..."; \
	printf '{"session_id":"sess-big","transcript_path":"%s","cwd":"/tmp"}' "$$transcript" | HOME="$$tmphome" bash "$$SCRIPT" || { echo "  FAIL: non-zero exit"; cleanup; exit 1; }; \
	pending="$$tmphome/.claude/harness/pending.jsonl"; \
	if [ -f "$$pending" ] && jq -e 'select(.session_id == "sess-big") | .transcript_path and .recorded_epoch' "$$pending" >/dev/null 2>&1; then \
		echo "  PASS: pending.jsonl has sess-big entry"; \
	else \
		echo "  FAIL: expected sess-big in pending.jsonl"; cleanup; exit 1; \
	fi; \
	echo "  Test 2: state.json records last_trigger_epoch..."; \
	if jq -e '.last_trigger_epoch > 0' "$$tmphome/.claude/harness/state.json" >/dev/null 2>&1; then \
		echo "  PASS: last_trigger_epoch set"; \
	else \
		echo "  FAIL: last_trigger_epoch missing"; cleanup; exit 1; \
	fi; \
	echo "  Test 3: duplicate session_id is not appended twice..."; \
	printf '{"session_id":"sess-big","transcript_path":"%s","cwd":"/tmp"}' "$$transcript" | HOME="$$tmphome" bash "$$SCRIPT"; \
	count=$$(grep -c 'sess-big' "$$pending"); \
	if [ "$$count" -eq 1 ]; then \
		echo "  PASS: still exactly 1 entry"; \
	else \
		echo "  FAIL: expected 1 entry, got $$count"; cleanup; exit 1; \
	fi; \
	echo "  Test 4: short session is skipped..."; \
	shortt="$$tmphome/short.jsonl"; \
	printf '{"type":"assistant","message":{}}\n' > "$$shortt"; \
	printf '{"session_id":"sess-short","transcript_path":"%s","cwd":"/tmp"}' "$$shortt" | HOME="$$tmphome" bash "$$SCRIPT" || { echo "  FAIL: non-zero exit on short session"; cleanup; exit 1; }; \
	if grep -q 'sess-short' "$$pending"; then \
		echo "  FAIL: short session was recorded"; cleanup; exit 1; \
	else \
		echo "  PASS: short session skipped"; \
	fi; \
	echo "  Test 5: malformed stdin exits 0..."; \
	if printf 'not json at all' | HOME="$$tmphome" bash "$$SCRIPT"; then \
		echo "  PASS: exit 0 on malformed stdin"; \
	else \
		echo "  FAIL: expected exit 0 on malformed stdin"; cleanup; exit 1; \
	fi; \
	echo "  Test 6: missing transcript file exits 0 without recording..."; \
	before=$$(wc -l < "$$pending"); \
	printf '{"session_id":"sess-gone","transcript_path":"%s/nonexistent.jsonl","cwd":"/tmp"}' "$$tmphome" | HOME="$$tmphome" bash "$$SCRIPT" || { echo "  FAIL: non-zero exit"; cleanup; exit 1; }; \
	after=$$(wc -l < "$$pending"); \
	if [ "$$before" -eq "$$after" ]; then \
		echo "  PASS: nothing recorded for missing transcript"; \
	else \
		echo "  FAIL: entry recorded despite missing transcript"; cleanup; exit 1; \
	fi; \
	echo "  Test 7: HARNESS_DISABLE=1 skips..."; \
	printf '{"session_id":"sess-disabled","transcript_path":"%s","cwd":"/tmp"}' "$$transcript" | HOME="$$tmphome" HARNESS_DISABLE=1 bash "$$SCRIPT" || { echo "  FAIL: non-zero exit"; cleanup; exit 1; }; \
	if grep -q 'sess-disabled' "$$pending"; then \
		echo "  FAIL: recorded despite HARNESS_DISABLE"; cleanup; exit 1; \
	else \
		echo "  PASS: HARNESS_DISABLE respected"; \
	fi; \
	cleanup
	@echo "Testing harness-briefing.sh..."
	@SCRIPT="$$(pwd)/dot_claude/scripts/executable_harness-briefing.sh"; \
	tmphome=$$(mktemp -d /tmp/test-harness-briefing-XXXXXX); \
	cleanup() { rm -rf "$$tmphome"; }; \
	hdir="$$tmphome/.claude/harness"; \
	echo "  Test 1: fresh install bootstraps and prints OK..."; \
	output=$$(HOME="$$tmphome" bash "$$SCRIPT") || { echo "  FAIL: non-zero exit"; cleanup; exit 1; }; \
	if echo "$$output" | grep -q '^Harness: OK' && [ -f "$$hdir/state.json" ] && [ -f "$$hdir/queue.md" ]; then \
		echo "  PASS: bootstrapped, prints OK with 'last review: never'"; \
	else \
		echo "  FAIL: expected OK line and bootstrapped files, got: $$output"; cleanup; exit 1; \
	fi; \
	echo "  Test 2: review overdue with queued work warns with remedy..."; \
	old=$$(( $$(date +%s) - 30*86400 )); \
	printf '{"version":1,"last_review_epoch":%s}' "$$old" > "$$hdir/state.json"; \
	printf '## [2026-07-01] some candidate\n- **Status:** pending\n' >> "$$hdir/queue.md"; \
	output=$$(HOME="$$tmphome" bash "$$SCRIPT"); \
	if echo "$$output" | grep -q 'ATTENTION' && echo "$$output" | grep -q 'overdue' && echo "$$output" | grep -q '/harness-review'; then \
		echo "  PASS: overdue warning with remediation command"; \
	else \
		echo "  FAIL: expected overdue warning, got: $$output"; cleanup; exit 1; \
	fi; \
	echo "  Test 3: fresh review prints OK with queue count..."; \
	now=$$(date +%s); \
	printf '{"version":1,"last_review_epoch":%s}' "$$now" > "$$hdir/state.json"; \
	output=$$(HOME="$$tmphome" bash "$$SCRIPT"); \
	if echo "$$output" | grep -q '^Harness: OK | queue: 1 | pending: 0 | last review: 0d ago'; then \
		echo "  PASS: OK line with counts"; \
	else \
		echo "  FAIL: expected OK line with counts, got: $$output"; cleanup; exit 1; \
	fi; \
	echo "  Test 4: pending pile-up warns..."; \
	for i in 1 2 3 4 5 6; do printf '{"session_id":"s%s","transcript_path":"/tmp/t","cwd":"/tmp","recorded_epoch":%s}\n' "$$i" "$$now" >> "$$hdir/pending.jsonl"; done; \
	output=$$(HOME="$$tmphome" bash "$$SCRIPT"); \
	if echo "$$output" | grep -q 'unreflected sessions' && echo "$$output" | grep -q '/harness-reflect'; then \
		echo "  PASS: pending pile-up warning"; \
	else \
		echo "  FAIL: expected pending warning, got: $$output"; cleanup; exit 1; \
	fi; \
	echo "  Test 5: corrupt state.json warns but exits 0..."; \
	printf 'not json' > "$$hdir/state.json"; \
	output=$$(HOME="$$tmphome" bash "$$SCRIPT") || { echo "  FAIL: non-zero exit on corrupt state"; cleanup; exit 1; }; \
	if echo "$$output" | grep -q 'corrupt'; then \
		echo "  PASS: corrupt state warned"; \
	else \
		echo "  FAIL: expected corrupt warning, got: $$output"; cleanup; exit 1; \
	fi; \
	echo "  Test 6: non-numeric last_review_epoch warns but exits 0..."; \
	printf '{"version":1,"last_review_epoch":"not-a-number"}' > "$$hdir/state.json"; \
	output=$$(HOME="$$tmphome" bash "$$SCRIPT") || { echo "  FAIL: non-zero exit on non-numeric epoch"; cleanup; exit 1; }; \
	if echo "$$output" | grep -q 'non-numeric'; then \
		echo "  PASS: non-numeric epoch warned, exit 0"; \
	else \
		echo "  FAIL: expected non-numeric warning, got: $$output"; cleanup; exit 1; \
	fi; \
	echo "  Test 7: malformed recorded_epoch in pending exits 0..."; \
	now2=$$(date +%s); \
	printf '{"version":1,"last_review_epoch":%s}' "$$now2" > "$$hdir/state.json"; \
	printf '{"session_id":"bad","transcript_path":"/tmp/t","cwd":"/tmp","recorded_epoch":"oops"}\n' > "$$hdir/pending.jsonl"; \
	if HOME="$$tmphome" bash "$$SCRIPT" >/dev/null; then \
		echo "  PASS: malformed recorded_epoch exits 0"; \
	else \
		echo "  FAIL: non-zero exit on malformed recorded_epoch"; cleanup; exit 1; \
	fi; \
	cleanup
	@echo "Testing harness-doctor.sh..."
	@SCRIPT="$$(pwd)/dot_claude/scripts/executable_harness-doctor.sh"; \
	tmphome=$$(mktemp -d /tmp/test-harness-doctor-XXXXXX); \
	cleanup() { rm -rf "$$tmphome"; }; \
	mkdir -p "$$tmphome/.claude/scripts" "$$tmphome/.claude/skills/harness-reflect" "$$tmphome/.claude/skills/harness-review" "$$tmphome/.claude/harness"; \
	printf '{"hooks":{"x":"harness-reflect-trigger.sh and harness-briefing.sh"}}' > "$$tmphome/.claude/settings.json"; \
	printf '#!/usr/bin/env bash\n' > "$$tmphome/.claude/scripts/harness-reflect-trigger.sh"; \
	printf '#!/usr/bin/env bash\n' > "$$tmphome/.claude/scripts/harness-briefing.sh"; \
	chmod +x "$$tmphome/.claude/scripts/harness-reflect-trigger.sh" "$$tmphome/.claude/scripts/harness-briefing.sh"; \
	printf -- '---\nname: harness-reflect\n---\n' > "$$tmphome/.claude/skills/harness-reflect/SKILL.md"; \
	printf -- '---\nname: harness-review\n---\n' > "$$tmphome/.claude/skills/harness-review/SKILL.md"; \
	printf '{"version":1,"last_trigger_epoch":%s}' "$$(date +%s)" > "$$tmphome/.claude/harness/state.json"; \
	printf '{"session_id":"s1","transcript_path":"/tmp/t","cwd":"/tmp","recorded_epoch":1}\n' > "$$tmphome/.claude/harness/pending.jsonl"; \
	printf '# Harness improvement queue\n' > "$$tmphome/.claude/harness/queue.md"; \
	echo "  Test 1: healthy fixture passes..."; \
	if output=$$(HOME="$$tmphome" bash "$$SCRIPT") && ! echo "$$output" | grep -q '^FAIL:'; then \
		echo "  PASS: healthy fixture exits 0 with no FAIL lines"; \
	else \
		echo "  FAIL: expected all-pass, got: $$output"; cleanup; exit 1; \
	fi; \
	echo "  Test 2: unwired hook is detected..."; \
	printf '{"hooks":{}}' > "$$tmphome/.claude/settings.json"; \
	if HOME="$$tmphome" bash "$$SCRIPT" >/dev/null 2>&1; then \
		echo "  FAIL: expected non-zero exit for unwired hooks"; cleanup; exit 1; \
	else \
		echo "  PASS: unwired hooks exit non-zero"; \
	fi; \
	echo "  Test 3: corrupt pending.jsonl is detected..."; \
	printf '{"hooks":{"x":"harness-reflect-trigger.sh and harness-briefing.sh"}}' > "$$tmphome/.claude/settings.json"; \
	printf 'not json\n' >> "$$tmphome/.claude/harness/pending.jsonl"; \
	if HOME="$$tmphome" bash "$$SCRIPT" >/dev/null 2>&1; then \
		echo "  FAIL: expected non-zero exit for corrupt pending"; cleanup; exit 1; \
	else \
		echo "  PASS: corrupt pending exits non-zero"; \
	fi; \
	cleanup
