# ネイティブ Bash サンドボックスの smoke test(scripts/native-sandbox-smoke.sh と
# scripts/native-sandbox-probe.sh)の検査。
#
# 実物の claude もサンドボックスも使わない。サンドボックスが拒否する状況は chmod 000 の
# fixture で、claude は PATH 上のスタブで再現する。HOME は必ず $BATS_TEST_TMPDIR 配下に
# 差し替え、このマシンの認証情報ファイルには触れない。
# root はパーミッションを無視して読み書きできるので chmod では拒否を再現できない。拒否の
# 再現に頼るテストは require_chmod_denial で root のとき skip する。
setup() {
    load 'helpers/setup'
    # driver が「サンドボックスの内側」の印として読む変数を、このシェルから漏らさない
    unset INSIDE_NONO_SANDBOX CLAUDECODE SANDBOX_RUNTIME NATIVE_SANDBOX_SMOKE_BUDGET_USD STUB_SANDBOX STUB_CLAUDE_MODE STUB_CHEZMOI_FAIL
    REPO="$BATS_TEST_DIRNAME/.."
    DRIVER="$REPO/scripts/native-sandbox-smoke.sh"
    PROBE="$REPO/scripts/native-sandbox-probe.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.claude"
    WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK"
    STUBS="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUBS"
    export ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"
    export ENV_LOG="$BATS_TEST_TMPDIR/env.log"
    export PROBE_CWD_LOG="$BATS_TEST_TMPDIR/probe-cwd.log"

    # claude のスタブ。STUB_CLAUDE_MODE で振る舞いを切り替える:
    #   run-probe(既定) cwd の probe.sh を実行する(モデルがプローブを実行した状況)。
    #                   STUB_SANDBOX=reads で拒否側の読み取りを、=all でさらに $HOME 直下への
    #                   書き込みを、プローブの実行の直前に塞ぐ
    #   no-probe        何もせずに終わる(モデルがプローブを実行しなかった状況)
    #   empty-results   空の結果ファイルだけを作る
    #   exit1           エラー終了する(起動引数が不正だった状況)
    cat >"$STUBS/claude" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a"; done >"$ARGV_LOG"
printf 'HARNESS_DISABLE=%s\n' "${HARNESS_DISABLE:-}" >"$ENV_LOG"
pwd >"$PROBE_CWD_LOG"
case "${STUB_CLAUDE_MODE:-run-probe}" in
run-probe)
    # サンドボックスに入った状況の再現。driver(サンドボックスの外)からは読めたまま、
    # プローブからは拒否側が読めなくなる
    case "${STUB_SANDBOX:-}" in
    reads | all)
        chmod 000 "$HOME/.ssh/id_test" "$HOME/.netrc"
        chmod 311 "$HOME/.ssh"
        ;;
    esac
    [[ "${STUB_SANDBOX:-}" != all ]] || chmod 555 "$HOME"
    bash ./probe.sh >/dev/null 2>&1 || true
    ;;
no-probe) ;;
empty-results) : >results.tsv ;;
exit1)
    printf 'error: unknown option\n' >&2
    exit 1
    ;;
esac
printf '{"type":"result","is_error":false,"result":"stub reply"}\n'
EOF
    # chezmoi のスタブ。source のレンダリング結果として STUB_RENDERED を返す
    cat >"$STUBS/chezmoi" <<'EOF'
#!/usr/bin/env bash
[[ -n "${STUB_CHEZMOI_FAIL:-}" ]] && exit 1
cat "$STUB_RENDERED"
EOF
    chmod +x "$STUBS"/*
    export PATH="$STUBS:$PATH"

    # デプロイ済みの settings の fixture。~/.config/gh は denyRead と allowRead の両方にある
    # (テンプレートの現状と同じ重なり)
    cat >"$HOME/.claude/settings.json" <<'EOF'
{
  "permissions": {"defaultMode": "auto"},
  "sandbox": {
    "enabled": true,
    "filesystem": {
      "allowWrite": ["/tmp"],
      "denyRead": ["~/.aws/credentials", "~/.config/gh", "~/.netrc", "~/.ssh"],
      "allowRead": ["~/.ssh/config", "~/.ssh/known_hosts", "~/.config/gh"]
    }
  }
}
EOF
    export STUB_RENDERED="$BATS_TEST_TMPDIR/rendered.json"
    cp "$HOME/.claude/settings.json" "$STUB_RENDERED"

    mkdir -p "$HOME/.ssh" "$HOME/.config/gh"
    printf 'secret-key\n' >"$HOME/.ssh/id_test"
    printf 'Host x\n' >"$HOME/.ssh/config"
    printf 'token\n' >"$HOME/.netrc"
    printf 'host: x\n' >"$HOME/.config/gh/hosts.yml"
}

teardown() {
    # chmod 000 の fixture を戻して $BATS_TEST_TMPDIR を消せるようにする
    chmod -R u+rwx "$HOME" 2>/dev/null || true
}

# サンドボックスが拒否する状況の再現: 拒否側を読めなくする(probe を直接走らせるテスト用。
# driver のテストでは、driver から見える状態を変えないよう claude のスタブの中で塞ぐ)
require_chmod_denial() {
    [[ "$(id -u)" -ne 0 ]] || skip 'root では chmod による拒否を再現できない'
}

deny_reads() {
    require_chmod_denial
    chmod 000 "$HOME/.ssh/id_test" "$HOME/.netrc"
    chmod 311 "$HOME/.ssh"
}

# --- probe ------------------------------------------------------------------

write_manifest() {
    printf '%s\n' "$@" >"$WORK/targets.tsv"
}

run_probe() {
    cp "$PROBE" "$WORK/probe.sh"
    cd "$WORK"
    run bash ./probe.sh
}

@test "probe: 拒否側が読めず許可側が読めれば全項目 PASS で、終了コードは 0" {
    deny_reads
    write_manifest \
        "read-file	deny	$HOME/.netrc" \
        "read-dir	deny	$HOME/.ssh" \
        "read-file	allow	$HOME/.ssh/config" \
        "read-dir	allow	$HOME/.config/gh" \
        "write	allow	$BATS_TEST_TMPDIR/tmp-target" \
        "write	deny	$HOME/.unwritable/x"
    run_probe
    assert_success
    run cat "$WORK/results.tsv"
    refute_output --partial 'FAIL'
    # 拒否時の終了コードの値は実装で違う(ls は BSD が 1、GNU が 2)ので 0 以外だけを見る
    assert_line --regexp '^read-file:~/\.netrc	deny	[1-9][0-9]*	PASS$'
    assert_line --regexp '^read-dir:~/\.ssh	deny	[1-9][0-9]*	PASS$'
    assert_line "read-file:~/.ssh/config	allow	0	PASS"
    assert_line --regexp '^coverage:deny	deny	2	PASS$'
    assert_line --regexp '^coverage:allow	allow	2	PASS$'
}

@test "probe: 拒否されるはずの読み取りが成功したら FAIL にする" {
    write_manifest \
        "read-file	deny	$HOME/.netrc" \
        "read-file	allow	$HOME/.ssh/config"
    run_probe
    assert_failure
    run cat "$WORK/results.tsv"
    assert_line "read-file:~/.netrc	deny	0	FAIL"
}

@test "probe: 存在しないパスは SKIP にし、読み取りの失敗を拒否として数えない" {
    deny_reads
    write_manifest \
        "read-absent	deny	$HOME/.aws/credentials" \
        "read-file	deny	$HOME/.netrc" \
        "read-absent	allow	$HOME/.ssh/known_hosts" \
        "read-file	allow	$HOME/.ssh/config"
    run_probe
    assert_success
    run cat "$WORK/results.tsv"
    assert_line "read-absent:~/.aws/credentials	deny	-	SKIP"
    assert_line "read-absent:~/.ssh/known_hosts	allow	-	SKIP"
    assert_line --regexp '^coverage:deny	deny	1	PASS$'
}

@test "probe: 拒否側がすべて SKIP なら coverage を FAIL にして非 0 で終わる" {
    write_manifest \
        "read-absent	deny	$HOME/.aws/credentials" \
        "read-file	allow	$HOME/.ssh/config"
    run_probe
    assert_failure
    run cat "$WORK/results.tsv"
    assert_line --regexp '^coverage:deny	deny	0	FAIL$'
}

@test "probe: 許可側がすべて SKIP でも coverage を FAIL にする" {
    deny_reads
    write_manifest \
        "read-file	deny	$HOME/.netrc" \
        "read-absent	allow	$HOME/.ssh/known_hosts"
    run_probe
    assert_failure
    run cat "$WORK/results.tsv"
    assert_line --regexp '^coverage:allow	allow	0	FAIL$'
}

@test "probe: 拒否されるはずの書き込みが成功したら FAIL にし、作られたファイルは消す" {
    write_manifest \
        "read-file	allow	$HOME/.ssh/config" \
        "write	allow	$BATS_TEST_TMPDIR/tmp-target" \
        "write	deny	$HOME/.native-sandbox-probe.test"
    run_probe
    assert_failure
    run cat "$WORK/results.tsv"
    assert_line "write:~/.native-sandbox-probe.test	deny	0	FAIL"
    assert_line --regexp "^write:.*/tmp-target	allow	0	PASS$"
    assert [ ! -e "$HOME/.native-sandbox-probe.test" ]
    assert [ ! -e "$BATS_TEST_TMPDIR/tmp-target" ]
}

@test "probe: ラベルがあれば結果にはパスの代わりにラベルを書き、空ディレクトリと重ならない許可側は SKIP にする" {
    deny_reads
    write_manifest \
        "read-file	deny	$HOME/.ssh/id_test	~/.ssh/#1" \
        "read-empty	deny	$HOME/.aws" \
        "read-unscoped	allow	$HOME/.config/other" \
        "read-file	allow	$HOME/.ssh/config"
    run_probe
    assert_success
    run cat "$WORK/results.tsv"
    assert_line --regexp '^read-file:~/\.ssh/#1	deny	[1-9][0-9]*	PASS$'
    refute_output --partial 'id_test'
    assert_line "read-empty:~/.aws	deny	-	SKIP"
    assert_line "read-unscoped:~/.config/other	allow	-	SKIP"
    # SKIP の項目は coverage に数えない
    assert_line --regexp '^coverage:allow	allow	1	PASS$'
}

@test "probe: 認証情報ファイルの内容を出力にも結果ファイルにも出さない" {
    write_manifest \
        "read-file	deny	$HOME/.ssh/id_test" \
        "read-file	allow	$HOME/.netrc"
    run_probe
    refute_output --partial 'secret-key'
    refute_output --partial 'token'
    run cat "$WORK/results.tsv"
    refute_output --partial 'secret-key'
    refute_output --partial 'token'
}

# --- driver -----------------------------------------------------------------

@test "driver: 各サンドボックスの印が立っていると理由を表示して非 0 で終わり、claude を起動しない" {
    for var in INSIDE_NONO_SANDBOX CLAUDECODE SANDBOX_RUNTIME; do
        rm -f "$ARGV_LOG"
        run env "$var=1" bash "$DRIVER"
        assert_failure
        assert_output --partial "$var"
        assert [ ! -e "$ARGV_LOG" ]
    done
}

@test "driver: claude -p を haiku・予算・サンドボックス設定・プローブ限定のツールで起動する" {
    require_chmod_denial
    export STUB_SANDBOX=all
    run bash "$DRIVER"
    assert_success
    run cat "$ARGV_LOG"
    assert_line --index 0 '-p'
    assert_line '--model'
    assert_line 'haiku'
    assert_line '--max-budget-usd'
    assert_line '--permission-mode'
    assert_line 'default'
    assert_line '--tools'
    assert_line 'Bash'
    assert_line '--allowedTools'
    assert_line 'Bash(bash ./probe.sh)'
    # プロンプトが指示するコマンドと --allowedTools のパターンが一致していること
    assert_output --partial 'bash ./probe.sh'
    refute_output --partial '"enabled":false'
    settings=$(grep -A1 -x -- '--settings' "$ARGV_LOG" | tail -n 1)
    assert_equal "$(jq -c '.sandbox | {enabled, allowUnsandboxedCommands, autoAllowBashIfSandboxed}' <<<"$settings")" \
        '{"enabled":true,"allowUnsandboxedCommands":false,"autoAllowBashIfSandboxed":false}'
    # デプロイ済みの filesystem 設定を丸ごと渡す(merge の深さに依存しない)
    assert_equal "$(jq -c '.sandbox.filesystem.denyRead' <<<"$settings")" \
        '["~/.aws/credentials","~/.config/gh","~/.netrc","~/.ssh"]'
    run cat "$ENV_LOG"
    assert_output 'HARNESS_DISABLE=1'
}

@test "driver: 一時ディレクトリを cwd にして起動し、終了後に消す" {
    require_chmod_denial
    export STUB_SANDBOX=all
    run bash "$DRIVER"
    assert_success
    cwd=$(cat "$PROBE_CWD_LOG")
    assert [ "$(basename "$cwd")" != "$(basename "$(cd "$REPO" && pwd)")" ]
    assert_regex "$cwd" '/native-sandbox-smoke\.[A-Za-z0-9]+$'
    assert [ ! -e "$cwd" ]
}

@test "driver: プローブが全項目を満たせば PASS を表示して 0 で終わる" {
    require_chmod_denial
    export STUB_SANDBOX=all
    run bash "$DRIVER"
    assert_success
    assert_output --regexp 'read-file:~/\.netrc	deny	[1-9][0-9]*	PASS'
    assert_output --partial 'read-file:~/.ssh/config	allow	0	PASS'
    assert_output --partial 'read-absent:~/.aws/credentials	deny	-	SKIP'
    # 拒否側のディレクトリは列挙ではなく直下のファイルの読み取りを項目にする
    refute_output --partial 'read-dir:~/.ssh	deny'
    # denyRead と allowRead の両方にあるパスは許可側として扱う
    assert_output --partial 'read-dir:~/.config/gh	allow	0	PASS'
    refute_output --partial 'read-dir:~/.config/gh	deny'
    # 拒否側のディレクトリ直下のファイルも読み取りの項目にし、allowRead のものは除く。
    # ファイル名は出さず、settings の値と連番のラベルにする
    assert_output --regexp 'read-file:~/\.ssh/#1	deny	[1-9][0-9]*	PASS'
    refute_output --partial 'read-file:~/.ssh/#2'
    refute_output --partial 'id_test'
    refute_output --partial 'read-file:~/.ssh/config	deny'
    assert_output --partial 'native-sandbox-smoke: PASS'
    # source とデプロイ先が一致していれば警告しない(食い違いの警告テストの対)
    refute_output --partial 'warning'
    refute_output --partial 'secret-key'
}

@test "driver: 拒否されるはずの書き込みが成功したら fail し、ファイルを残さない" {
    export STUB_SANDBOX=reads
    run bash "$DRIVER"
    # $HOME を書き込み可のまま残す(サンドボックスが書き込みを塞いでいない状況の再現)
    assert_failure
    assert_output --regexp 'write:~/\.native-sandbox-probe\.[a-z0-9]+	deny	0	FAIL'
    run find "$HOME" -maxdepth 1 -name '.native-sandbox-probe.*'
    assert_output ''
}

@test "driver: プローブが実行されず結果ファイルが無ければ、claude の出力を表示して fail する" {
    STUB_CLAUDE_MODE=no-probe run bash "$DRIVER"
    assert_failure
    assert_output --partial 'results.tsv'
    assert_output --partial 'stub reply'
}

@test "driver: claude がエラー終了して結果ファイルが無ければ fail する" {
    STUB_CLAUDE_MODE=exit1 run bash "$DRIVER"
    assert_failure
    assert_output --partial 'unknown option'
}

@test "driver: 結果ファイルが空(期待する行が揃っていない)なら fail する" {
    STUB_CLAUDE_MODE=empty-results run bash "$DRIVER"
    assert_failure
    assert_output --partial 'incomplete'
}

@test "driver: デプロイ済みの settings でネイティブサンドボックスが無効なら claude を起動せずに fail する" {
    jq '.sandbox.enabled = false' "$STUB_RENDERED" >"$HOME/.claude/settings.json"
    run bash "$DRIVER"
    assert_failure
    assert_output --partial 'sandbox.enabled'
    assert [ ! -e "$ARGV_LOG" ]
}

@test "driver: allowRead が無くても途中で止まらず、許可側の coverage を FAIL として報告する" {
    jq 'del(.sandbox.filesystem.allowRead)' "$STUB_RENDERED" >"$HOME/.claude/settings.json"
    cp "$HOME/.claude/settings.json" "$STUB_RENDERED"
    export STUB_SANDBOX=all
    run bash "$DRIVER"
    assert_failure
    assert_output --partial 'coverage:allow	allow	0	FAIL'
}

@test "driver: source とデプロイ先の sandbox 設定が食い違っていれば警告する" {
    jq '.sandbox.filesystem.denyRead += ["~/.extra"]' "$HOME/.claude/settings.json" >"$STUB_RENDERED"
    run bash "$DRIVER"
    assert_output --partial 'warning'
    assert_output --partial 'differs'
}

@test "driver: source をレンダリングできなければ、比較できなかったことを警告する" {
    STUB_CHEZMOI_FAIL=1 run bash "$DRIVER"
    assert_output --partial 'warning'
    assert_output --partial 'could not compare'
}

@test "driver: 拒否側のディレクトリに数える子が無ければ、理由の分かる SKIP 行を出す" {
    require_chmod_denial
    rm "$HOME/.ssh/id_test"
    # 拒否側の読み取りはスタブが ~/.netrc で塞ぐ。driver より前に塞ぐと、サンドボックスの外でも
    # 読めないパスとして SKIP になる(スタブの id_test への chmod は失敗するが無害)
    export STUB_SANDBOX=all
    run bash "$DRIVER"
    assert_success
    assert_output --partial 'read-empty:~/.ssh	deny	-	SKIP'
}

@test "driver: denyRead と重ならない allowRead は許可側の coverage に数えない" {
    jq '.sandbox.filesystem.allowRead = ["~/.config/other"]' "$STUB_RENDERED" >"$HOME/.claude/settings.json"
    cp "$HOME/.claude/settings.json" "$STUB_RENDERED"
    mkdir -p "$HOME/.config/other"
    export STUB_SANDBOX=all
    run bash "$DRIVER"
    assert_failure
    assert_output --partial 'read-unscoped:~/.config/other	allow	-	SKIP'
    assert_output --partial 'coverage:allow	allow	0	FAIL'
}

@test "driver: サンドボックスの外でも読めない拒否側のファイルは SKIP にし、coverage に数えない" {
    require_chmod_denial
    printf 'other-key\n' >"$HOME/.ssh/id_other"
    chmod 000 "$HOME/.ssh/id_other"
    export STUB_SANDBOX=all
    run bash "$DRIVER"
    assert_success
    assert_output --partial 'read-unreadable:~/.ssh/!1	deny	-	SKIP'
    refute_output --partial 'id_other'
    # 数えるのは読めた id_test と ~/.netrc だけ
    assert_output --regexp 'read-file:~/\.ssh/#1	deny	[1-9][0-9]*	PASS'
    refute_output --partial 'read-file:~/.ssh/#2'
}

@test "driver: 拒否側がすべてサンドボックスの外でも読めなければ、空振りの PASS にせず coverage を FAIL にする" {
    require_chmod_denial
    jq '.sandbox.filesystem.denyRead = ["~/.netrc", "~/.config/gh"]' "$STUB_RENDERED" >"$HOME/.claude/settings.json"
    cp "$HOME/.claude/settings.json" "$STUB_RENDERED"
    chmod 000 "$HOME/.netrc"
    export STUB_SANDBOX=none
    run bash "$DRIVER"
    assert_failure
    assert_output --partial 'read-unreadable:~/.netrc	deny	-	SKIP'
    assert_output --partial 'coverage:deny	deny	0	FAIL'
}

@test "driver: denyRead / allowRead の末尾の / を落として照合する" {
    require_chmod_denial
    jq '.sandbox.filesystem.denyRead = ["~/.netrc", "~/.ssh/"] | .sandbox.filesystem.allowRead = ["~/.ssh/config/"]' \
        "$STUB_RENDERED" >"$HOME/.claude/settings.json"
    cp "$HOME/.claude/settings.json" "$STUB_RENDERED"
    export STUB_SANDBOX=all
    run bash "$DRIVER"
    assert_success
    refute_output --partial 'read-file:~/.ssh/config	deny'
    assert_output --partial 'read-file:~/.ssh/config	allow	0	PASS'
    assert_output --regexp 'read-file:~/\.ssh/#1	deny	[1-9][0-9]*	PASS'
    refute_output --partial 'read-file:~/.ssh/#2'
}
