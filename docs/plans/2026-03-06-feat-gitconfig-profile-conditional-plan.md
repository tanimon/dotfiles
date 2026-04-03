---
title: "feat: Add profile-based conditional settings to dot_gitconfig"
type: feat
date: 2026-03-06
brainstorm: docs/brainstorms/2026-03-06-gitconfig-profile-management-brainstorm.md
---

# feat: Add profile-based conditional settings to dot_gitconfig

chezmoi の `profile` 変数 (work/personal) に基づき、`dot_gitconfig` の会社用設定を条件分岐で出力する。

## Acceptance Criteria

- [ ] `dot_gitconfig` が `dot_gitconfig.tmpl` にリネームされている
- [ ] `profile = "work"` のとき、会社用設定（URL書き換え, gtr, credential）が出力される
- [ ] `profile = "personal"` のとき、会社用設定が出力されない
- [ ] 共通設定（署名含む）は両プロファイルで出力される
- [ ] `docs/` が `.chezmoiignore` に追加されている
- [ ] `chezmoi execute-template` でテンプレートが正しくレンダリングされる

## Implementation

### 1. `dot_gitconfig` → `dot_gitconfig.tmpl` にリネーム

```bash
git mv dot_gitconfig dot_gitconfig.tmpl
```

### 2. テンプレート条件分岐を追加

`dot_gitconfig.tmpl` の会社用設定セクション（現在の54行目以降）を `{{ if }}` で囲む。

```gitconfig
# dot_gitconfig.tmpl

# ... 共通設定 (alias, branch, commit, core, diff, etc.) ...

[user]
  name = tanimon
  email = <noreply-email>
  signingkey = ssh-ed25519 <key-fingerprint>

[gpg]
  format = ssh
[gpg "ssh"]
  program = /Applications/1Password.app/Contents/MacOS/op-ssh-sign

{{ if eq .profile "work" -}}
### 会社用設定
[url "git@github.com:"]
  insteadOf = https://github.com/
[gtr "copy"]
  include = **/.envrc
  include = tmp/scripts/**
  include = .claude/settings.local.json
[gtr "editor"]
  default = code
[credential]
  helper =
  helper = /usr/local/share/gcm-core/git-credential-manager
[credential "https://dev.azure.com"]
  useHttpPath = true
{{ end -}}
```

### 3. `.chezmoiignore` に `docs/` を追加

```
docs/
```

### 4. 動作確認

```bash
# work プロファイルの出力確認
chezmoi execute-template < dot_gitconfig.tmpl

# personal プロファイルでの確認（一時的に .chezmoi.toml の profile を変更）
chezmoi diff
```

## Edge Cases

- **初回セットアップ**: `chezmoi init` 時に profile が未設定の場合、`promptStringOnce` が "work" or "personal" を尋ねる（既存の `.chezmoi.toml.tmpl` の仕組み）
- **profile 値の変更**: `chezmoi edit-config` で profile を変更後、`chezmoi apply` で即反映される
- **空文字列の profile**: `{{ if eq .profile "work" }}` なので、空文字や "personal" では会社用設定は出力されない（安全側に倒れる）

## References

- Brainstorm: `docs/brainstorms/2026-03-06-gitconfig-profile-management-brainstorm.md`
- Template pattern: `.chezmoiscripts/run_onchange_darwin-install-packages.sh.tmpl:1`
- Variable usage: `dot_claude/settings.json.tmpl:69,143`
- Data definition: `.chezmoi.toml.tmpl:1-6`
