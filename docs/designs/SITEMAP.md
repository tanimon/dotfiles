# Design Sitemap

EGM(`/egm:egm-draft`)で作った設計書の索引。設計書は `docs/designs/<feature>.md` にフラットに置き、ここに 1 行で登録する。ブリーフ・草稿・レビューのレポートなどの作業中の成果物は、EGM の artifact directory(`.dev/egm/`)に置き、ここには載せない。

| Design | Date | Author | Status | Components | Description |
| --- | --- | --- | --- | --- | --- |
| [独立検証ゲート(Phase 3-0〜3-1)](independent-verification-gate.md) | 2026-11-15 | tanimon | Proposed | `.github/workflows/`、`scripts/issue-gate*.sh`、`docs/agents/`、`test/`、issue-linkage スキル | ライターの PR を、Issue 本文の [cmd] の再実行と必須チェックで検査するゲート |
