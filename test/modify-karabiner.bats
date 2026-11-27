bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_config/karabiner/modify_karabiner.json"
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

modify() {
    printf '%s' "$1" | bash "$SCRIPT" 2>/dev/null
}

@test "machine_specific and profile metadata preserved, rules replaced and equal to source" {
    export CHEZMOI_SOURCE_DIR="$REPO_ROOT"
    input='{"machine_specific":{"krbn-test":{"external_editor_path":"/Applications/Code.app"}},"profiles":[{"complex_modifications":{"rules":[{"description":"old"}]},"name":"Default profile","selected":true,"virtual_hid_keyboard":{"keyboard_type_v2":"jis"}}]}'
    run modify "$input"
    assert_success
    assert jq -e '.machine_specific."krbn-test".external_editor_path == "/Applications/Code.app"' <<< "$output"
    assert jq -e '.profiles[0].name == "Default profile" and .profiles[0].selected == true' <<< "$output"
    assert jq -e '.profiles[0].virtual_hid_keyboard.keyboard_type_v2 == "jis"' <<< "$output"
    assert jq -e '.profiles[0].complex_modifications.rules | length == 1' <<< "$output"
    assert jq -e --slurpfile src "$REPO_ROOT/dot_config/karabiner/complex_modifications.json" '.profiles[0].complex_modifications.rules == $src[0]' <<< "$output"
}

@test "multi-profile rules replaced in both, name/selected/parameters preserved" {
    export CHEZMOI_SOURCE_DIR="$REPO_ROOT"
    input='{"profiles":[{"complex_modifications":{"rules":[]},"name":"P1","selected":true},{"complex_modifications":{"rules":[{"description":"old"}],"parameters":{"basic.simultaneous_threshold_milliseconds":100}},"name":"P2","selected":false}]}'
    run modify "$input"
    assert_success
    assert jq -e '.profiles | length == 2' <<< "$output"
    assert jq -e '.profiles[0].name == "P1" and .profiles[0].selected == true and .profiles[1].name == "P2" and .profiles[1].selected == false' <<< "$output"
    assert jq -e '.profiles[0].complex_modifications.rules | length == 1' <<< "$output"
    assert jq -e '.profiles[1].complex_modifications.rules | length == 1' <<< "$output"
    assert jq -e --slurpfile src "$REPO_ROOT/dot_config/karabiner/complex_modifications.json" '.profiles[0].complex_modifications.rules == $src[0] and .profiles[1].complex_modifications.rules == $src[0]' <<< "$output"
    assert jq -e '.profiles[1].complex_modifications.parameters."basic.simultaneous_threshold_milliseconds" == 100' <<< "$output"
}

@test "empty stdin produces valid JSON with rules equal to source and no machine_specific" {
    export CHEZMOI_SOURCE_DIR="$REPO_ROOT"
    run modify ''
    assert_success
    assert jq -e '.profiles | length == 1' <<< "$output"
    assert jq -e '.profiles[0].complex_modifications.rules | length == 1' <<< "$output"
    assert jq -e --slurpfile src "$REPO_ROOT/dot_config/karabiner/complex_modifications.json" '.profiles[0].complex_modifications.rules == $src[0]' <<< "$output"
    assert jq -e 'has("machine_specific") | not' <<< "$output"
}

@test "jq missing with empty stdin seeds the minimal shape, not a bare newline" {
    export CHEZMOI_SOURCE_DIR="$REPO_ROOT"
    # Only cat is on PATH: neither jq nor bash resolves there. Call bash by
    # absolute path, as the guard-contract suite does for its no-jq cases.
    stub="$BATS_TEST_TMPDIR/nojq"
    mkdir -p "$stub"
    ln -s "$(command -v cat)" "$stub/cat"
    run --separate-stderr env PATH="$stub" "$(command -v bash)" "$SCRIPT" </dev/null
    assert_success
    assert jq -e '.profiles | length == 1' <<< "$output"
    assert jq -e '.profiles[0].complex_modifications.rules == []' <<< "$output"
    assert jq -e '.profiles[0].virtual_hid_keyboard.keyboard_type_v2 == "ansi"' <<< "$output"
    assert jq -e 'has("machine_specific") | not' <<< "$output"
}

@test "jq missing with stdin passes it through unchanged" {
    export CHEZMOI_SOURCE_DIR="$REPO_ROOT"
    stub="$BATS_TEST_TMPDIR/nojq"
    mkdir -p "$stub"
    ln -s "$(command -v cat)" "$stub/cat"
    input='{"profiles":[{"name":"P","selected":true}]}'
    run --separate-stderr env PATH="$stub" "$(command -v bash)" "$SCRIPT" <<<"$input"
    assert_success
    assert jq -e --argjson i "$input" '. == $i' <<< "$output"
}

@test "missing source file passes through stdin" {
    export CHEZMOI_SOURCE_DIR="/tmp/nonexistent-dir"
    input='{"profiles":[{"complex_modifications":{"rules":[]},"name":"Default profile","selected":true}]}'
    run modify "$input"
    assert_success
    assert jq -e --argjson i "$input" '. == $i' <<< "$output"
}

@test "non-array source file passes through stdin" {
    src="$BATS_TEST_TMPDIR/source"
    mkdir -p "$src/dot_config/karabiner"
    printf '{"not": "an array"}' > "$src/dot_config/karabiner/complex_modifications.json"
    export CHEZMOI_SOURCE_DIR="$src"
    input='{"profiles":[{"complex_modifications":{"rules":[]},"name":"Default profile","selected":true}]}'
    run modify "$input"
    assert_success
    assert jq -e --argjson i "$input" '. == $i' <<< "$output"
}

@test "invalid-JSON source file passes through stdin" {
    src="$BATS_TEST_TMPDIR/source"
    mkdir -p "$src/dot_config/karabiner"
    printf '{not valid json' > "$src/dot_config/karabiner/complex_modifications.json"
    export CHEZMOI_SOURCE_DIR="$src"
    input='{"profiles":[{"complex_modifications":{"rules":[]},"name":"Default profile","selected":true}]}'
    run modify "$input"
    assert_success
    assert jq -e --argjson i "$input" '. == $i' <<< "$output"
}

@test "stdin without .profiles key passes through stdin" {
    export CHEZMOI_SOURCE_DIR="$REPO_ROOT"
    input='{"unrelated":"shape","no_profiles_key":true}'
    run modify "$input"
    assert_success
    assert jq -e --argjson i "$input" '. == $i' <<< "$output"
}
