# AWS profile switcher
# `awsp`           : fzf で profile を選び AWS_PROFILE をこのシェルに export する
# `awsp <name>`    : 指定した profile を直接設定する
# `awsp -u|--unset`: AWS_PROFILE をクリアする
# export なので bin/ スクリプトではなく関数として実装している（親シェルに反映するため）
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
    profile="$(_awsp_list_profiles | fzf --height=40% --reverse \
      --prompt='AWS profile> ' \
      --header="current: ${AWS_PROFILE:-none}")" || return 0
  fi

  [[ -z "$profile" ]] && return 0
  export AWS_PROFILE="$profile"
  echo "AWS_PROFILE=$AWS_PROFILE"
}

# profile 一覧を取得（awscli があれば優先、無ければ設定ファイルを解析）
_awsp_list_profiles() {
  if command -v aws &>/dev/null; then
    aws configure list-profiles
    return
  fi
  local config="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
  local creds="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
  {
    [[ -f "$config" ]] && sed -nE 's/^\[profile (.+)\]$/\1/p; s/^\[(default)\]$/\1/p' "$config"
    [[ -f "$creds" ]] && sed -nE 's/^\[(.+)\]$/\1/p' "$creds"
  } | awk 'NF && !seen[$0]++'
}
