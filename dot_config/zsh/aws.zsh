# AWS profile switcher
# `awsp`           : fzf で profile を選び AWS_PROFILE をこのシェルに export する
# `awsp <name>`    : 指定した profile を直接設定する
# `awsp -u|--unset`: AWS_PROFILE をクリアする
# export なので bin/ スクリプトではなく関数として実装している（親シェルに反映するため）
# profile 一覧の取得には aws CLI を前提とする（手書きの設定ファイル解析はしない）
awsp() {
  if [[ "$1" == "-u" || "$1" == "--unset" ]]; then
    unset AWS_PROFILE
    echo "AWS_PROFILE unset"
    return 0
  fi

  local profile="$1"
  if [[ -z "$profile" ]]; then
    if ! command -v fzf &>/dev/null; then
      echo "awsp: fzf is required but not installed" >&2
      return 1
    fi

    # 一覧取得を fzf 起動前に行い、失敗(非ゼロ)・空のどちらも明示的に扱う。
    # aws のエラーは fzf の TUI に混ざらず端末にそのまま出る。
    local profiles
    profiles="$(_awsp_list_profiles)" || return 1
    if [[ -z "$profiles" ]]; then
      echo "awsp: no AWS profiles found" >&2
      return 1
    fi

    profile="$(printf '%s\n' "$profiles" | fzf --height=40% --reverse \
      --prompt='AWS profile> ' \
      --header="current: ${AWS_PROFILE:-none}")" || return 0
  fi

  [[ -z "$profile" ]] && return 0
  export AWS_PROFILE="$profile"
  echo "AWS_PROFILE=$AWS_PROFILE"
}

# profile 一覧を取得（aws CLI のみを使う。stdout に一覧、失敗時は非ゼロを返す）
_awsp_list_profiles() {
  if ! command -v aws &>/dev/null; then
    echo "awsp: aws CLI is required but not installed" >&2
    return 1
  fi
  aws configure list-profiles
}
