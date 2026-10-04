#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/setup.sh の claude_env_gh_problem (「残りの手作業」に gh の件を出すかの判定) を
# 切り出して確かめる。
#
#   bash nix/tests/setup-post-notes.test.sh [<setup.sh のパス>]
#
# setup.sh は読み込むと最後まで実行されるので、関数の定義だけを awk で取り出して呼ぶ。
# flake の checks (setup-post-notes-test) が Nix のサンドボックスで流す。
#
# gh の有無は、要るコマンドだけを symlink で並べた PATH に、偽の gh を足すか足さないかで
# 作る (理由は bootstrap-claude-env.test.sh の冒頭と同じ)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
setup=${1:-${here}/../scripts/setup.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/setup-post-notes-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "  ok   $1"
}
ng() {
  fail=$((fail + 1))
  echo "  FAIL $1"
  if [[ -n ${2:-} ]]; then
    echo "       ${2//$'\n'/$'\n'       }"
  fi
}
check() { # $1: 名前、$2: 期待 (空 = 何も出さない / それ以外 = 含む文字列)、$3: 実際
  if [[ -z $2 && -z $3 ]] || [[ -n $2 && $3 == *"$2"* ]]; then
    ok "$1"
  else
    ng "$1" "got=$3"
  fi
}

echo "== setup.sh: claude_env_gh_problem (${setup})"

fn=$(awk '/^claude_env_gh_problem\(\) \{/ { f = 1 } f { print } f && /^\}/ { exit }' "${setup}")
if [[ -z ${fn} ]]; then
  ng "claude_env_gh_problem が定義されている" "(見つからない)"
  echo "== ${pass} passed, ${fail} failed"
  exit 1
fi

# gh だけを持たない PATH
nogh_bin="${work}/nogh-bin"
mkdir -p "${nogh_bin}"
if ! jq_path=$(command -v jq); then
  echo "見つからない: jq" >&2
  exit 1
fi
ln -s "${jq_path}" "${nogh_bin}/jq"

state_true='{"managed":["credential.https://github.com.helper"],"gitConfig":[{"k":"credential.https://github.com.helper","v":"!gh auth git-credential"}]}'
state_false='{"managed":["credential.https://github.com.helper"],"gitConfig":[{"k":"commit.gpgsign","v":"false"}]}'

# $1: 名前、$2: 状態ファイル (空なら無し)、$3: gh (in = ログイン済み / out = 未ログイン / none = 無い)
case_run() {
  local h="${work}/$1" p="${nogh_bin}"
  mkdir -p "${h}/.local/state/dotfiles" "${h}/bin"
  if [[ -n $2 ]]; then printf '%s\n' "$2" >"${h}/.local/state/dotfiles/claude-env.json"; fi
  if [[ $3 != none ]]; then
    {
      printf '#!%s\n' "${BASH}"
      printf 'state=%s\n' "$3"
      cat <<'EOF'
if [[ $1 == auth && $2 == token ]]; then
  [[ ${state} == in ]]
  exit
fi
exit 0
EOF
    } >"${h}/bin/gh"
    chmod +x "${h}/bin/gh"
    p="${h}/bin:${p}"
  fi
  HOME="${h}" PATH="${p}" "${BASH}" -c "${fn}"$'\n''claude_env_gh_problem'
}

check "gh が無ければ「gh が見つからない」" 'gh が見つからない' "$(case_run a "${state_true}" none)"
check "未ログインなら「gh にログインしていない」" 'gh にログインしていない' "$(case_run b "${state_true}" out)"
check "ログイン済みなら何も出さない" '' "$(case_run c "${state_true}" in)"
check "gh を使わない設定なら何も出さない" '' "$(case_run d "${state_false}" none)"
check "状態ファイルが無ければ何も出さない" '' "$(case_run e "" none)"

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
