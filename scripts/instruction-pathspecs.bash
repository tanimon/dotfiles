#!/usr/bin/env bash
# エージェントが指示として読み込むファイルと skill の本文を指す git の pathspec(source のパスで照合する)。
# source 専用。set は呼び出し側に従う。
#
# 読み手: scripts/check-instruction-size.sh(サイズの上限)と scripts/check-comment-noise.sh(経緯の記述)。
# 判定ごとの足し引き(harness/modules/ を含めるか、生成物を外すか)は読み手の側で行い、ここには共通の範囲だけを置く。
# skill の補助ファイル(references/ など)は必要なときにしか読み込まれないので入れない。
# shellcheck disable=SC2034
INSTRUCTION_PATHSPECS=(
    ':(glob)**/CLAUDE.md'
    ':(glob)**/AGENTS.md'
    ':(glob).claude/rules/**/*.md'
    ':(glob)dot_claude/rules/**/*.md'
    ':(glob).cursor/rules/*.mdc'
    'dot_claude/CLAUDE.md.tmpl'
    'dot_codex/AGENTS.md.tmpl'
    '.chezmoitemplates/agent-instructions-common'
    ':(glob)**/SKILL.md'
)
