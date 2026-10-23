# web-verify のテンプレートを scaffold した直後のスイートで、globalSetup が seed モジュール
# (seed/common.ts と seed/features/<feature>.ts)を読み込めることを確かめる。
# scaffold.md の生成の検証(`playwright test --list`)は globalSetup を実行しないので、ここでしか捕まらない。
# ブラウザもアプリも使わない: ダミー機能の setup() が目印のエラーを投げ、globalSetup をそこで止める。

setup() {
    load 'helpers/setup'
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    ASSETS="$REPO_ROOT/dot_claude/skills/web-verify/assets"
    SUITE="$BATS_TEST_TMPDIR/suite"

    # コピーするファイルは references/scaffold.md の「生成手順」に合わせる
    mkdir -p "$SUITE/scenarios/smoke" "$SUITE/seed/features" "$SUITE/support"
    cp "$ASSETS/playwright.config.ts" "$ASSETS/package.json" "$SUITE/"
    cp "$ASSETS/support/run.ts" "$SUITE/support/"
    cp "$ASSETS/auth.setup.ts" "$SUITE/scenarios/"
    cp "$ASSETS/seed/setup.ts" "$ASSETS/seed/cleanup.ts" "$ASSETS/seed/modules.ts" "$SUITE/seed/"
    cp "$ASSETS/seed/module.template.ts" "$SUITE/seed/common.ts"
    # scaffold の npm install の代わりに、リポジトリの devDependencies の Playwright を使う
    ln -s "$REPO_ROOT/node_modules" "$SUITE/node_modules"

    cat >"$SUITE/seed/features/smoke.ts" <<'EOF'
export async function setup(): Promise<void> {
  throw new Error("SMOKE-SEED-LOADED");
}
EOF
    # support/run.ts は、指定した機能の spec が無いと設定の読み込みで止める
    cat >"$SUITE/scenarios/smoke/smoke.spec.ts" <<'EOF'
import { test } from "@playwright/test";
test("smoke", async () => {});
EOF
}

run_smoke() {
    cd "$SUITE" || return 1
    VERIFY_FEATURE=smoke VERIFY_BASE_URL=http://localhost:9 VERIFY_REPO_DIR="$SUITE" \
        ./node_modules/.bin/playwright test
}

@test "globalSetup が common と機能の seed を読み込む" {
    run run_smoke
    assert_failure
    assert_output --partial 'SMOKE-SEED-LOADED'
}

# 古い Node で import() が落ちる理由は seed/modules.ts の loadSeedModules のコメントにある。
# CI の Node は同期の経路を通るので、Playwright の環境変数で非同期の ESM ローダーを強制して同じ条件を作る
@test "非同期の ESM ローダーでも globalSetup が seed を読み込む" {
    PLAYWRIGHT_FORCE_ASYNC_LOADER=1 run run_smoke
    assert_failure
    assert_output --partial 'SMOKE-SEED-LOADED'
}

# 振る舞いではなく、「非同期の ESM ローダーでも globalSetup が seed を読み込む」が成り立つ前提の検査。
# PLAYWRIGHT_FORCE_ASYNC_LOADER は Playwright 内部の環境変数なので、効かなくなるとそのテストは同期の経路で
# 黙って通る。import() で読む modules.ts がこの環境変数で落ちることを確かめ、効かなくなったらここで気づけるようにする
@test "PLAYWRIGHT_FORCE_ASYNC_LOADER で import() の seed 読み込みが落ちる" {
    sed -i.bak -e 's|require(\("./common"\))|(await import(\1))|' -e 's|require(file)|(await import(file))|' "$SUITE/seed/modules.ts"
    run grep -c 'await import(' "$SUITE/seed/modules.ts"
    assert_output '2'

    PLAYWRIGHT_FORCE_ASYNC_LOADER=1 run run_smoke
    assert_failure
    assert_output --partial "SyntaxError: Unexpected token 'export'"
    assert_output --partial 'at seed/modules.ts:'
    refute_output --partial 'SMOKE-SEED-LOADED'
}
