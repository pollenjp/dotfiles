#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-claude-env.sh の振る舞いを、使い捨ての HOME と偽の gh で確かめる。
#
#   bash nix/tests/bootstrap-claude-env.test.sh [<bootstrap-claude-env.sh のパス>]
#
# flake の checks (bootstrap-claude-env-test) が Nix のサンドボックスで流す。CI の
# `nix flake check` もこれを通る。使うのは bash・jq・git・coreutils だけ。
#
# ## 確かめること
#
#   - option の true / false どおりに env の GIT_CONFIG_* を書き直す。true → false で
#     HTTPS の組が消え、管理しない組は順序ごと残り、再実行では変わらない
#   - 状態ファイルが無い・形が違う・settings.json が無いときの扱い
#   - gh が無い / 未ログイン / 設定ファイルに別の credential helper があるときの警告
#
# ## 「gh が無い」の作り方
#
# 要るコマンドだけを symlink で並べた PATH で流す。PATH から gh のあるディレクトリを
# 抜く形にしないのは、GitHub の runner の /usr/bin や Nix の profile では gh が
# bash・jq・git と同じディレクトリにあって抜けないため。
#
# 偽の gh の shebang は $BASH から作る。Nix のサンドボックスには /usr/bin/env が無い。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-claude-env.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-claude-env-test.XXXXXX")
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

managed='["commit.gpgsign","tag.gpgsign","url.https://github.com/.insteadOf","credential.https://github.com.helper"]'
base_pairs='[{"k":"commit.gpgsign","v":"false"},{"k":"tag.gpgsign","v":"false"}]'
gh_pairs='[{"k":"url.https://github.com/.insteadOf","v":"git@github.com:"},{"k":"url.https://github.com/.insteadOf","v":"ssh://git@github.com/"},{"k":"credential.https://github.com.helper","v":"!gh auth git-credential"}]'
all_pairs=$(jq -cn --argjson b "${base_pairs}" --argjson g "${gh_pairs}" '$b + $g')
state_true=$(jq -cn --argjson m "${managed}" --argjson p "${all_pairs}" '{managed: $m, gitConfig: $p}')
state_false=$(jq -cn --argjson m "${managed}" --argjson p "${base_pairs}" '{managed: $m, gitConfig: $p}')

# 無署名の 2 組だけが入った settings.json の env (gitViaGh より前の形)
env_current='{"GIT_CONFIG_COUNT":"2","GIT_CONFIG_KEY_0":"commit.gpgsign","GIT_CONFIG_VALUE_0":"false","GIT_CONFIG_KEY_1":"tag.gpgsign","GIT_CONFIG_VALUE_1":"false"}'

# 組の配列 → 期待する env (GIT_CONFIG_* だけ)
expect_env() {
  jq -cn --argjson p "$1" '
    {GIT_CONFIG_COUNT: ($p | length | tostring)}
    + ([$p | to_entries[] | {("GIT_CONFIG_KEY_" + (.key | tostring)): .value.k, ("GIT_CONFIG_VALUE_" + (.key | tostring)): .value.v}] | add // {})'
}

# gh だけを持たない PATH。要るコマンドを symlink で並べる。
nogh_bin="${work}/nogh-bin"
mkdir -p "${nogh_bin}"
for c in env jq git awk sed grep tr cat mkdir mktemp mv rm dirname chmod; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${nogh_bin}/${c}"
done

# 1 ケースぶんの HOME を作る。$2: settings.json の中身 (空なら作らない)、$3: 状態ファイル (空なら作らない)
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.claude" "${h}/.local/state/dotfiles" "${h}/bin"
  if [[ -n $2 ]]; then printf '%s\n' "$2" >"${h}/.claude/settings.json"; fi
  if [[ -n $3 ]]; then printf '%s\n' "$3" >"${h}/.local/state/dotfiles/claude-env.json"; fi
  # 偽の gh。GH_FAKE_LOGGED_IN=1 なら auth token が成功する
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
if [[ $1 == auth && $2 == token ]]; then
  if [[ ${GH_FAKE_LOGGED_IN:-1} == 1 ]]; then
    echo gho_fake
    exit 0
  fi
  echo "no oauth token found for github.com" >&2
  exit 1
fi
exit 0
EOF
  } >"${h}/bin/gh"
  chmod +x "${h}/bin/gh"
  echo "${h}"
}

# $1: HOME、残り: 足す環境変数。git の global / system の設定は偽の HOME に閉じ込める
run() {
  local h=$1
  shift
  env HOME="${h}" XDG_CONFIG_HOME="${h}/.config" GIT_CONFIG_NOSYSTEM=1 PATH="${h}/bin:${PATH}" "$@" \
    "${BASH}" "${script}" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
git_env() { jq -cS '.env // {} | with_entries(select(.key | startswith("GIT_CONFIG_")))' "$1/.claude/settings.json"; }
same() { [[ $(jq -cS . <<<"$1") == $(jq -cS . <<<"$2") ]]; }

echo "== bootstrap-claude-env.sh: ${script}"

# 1. true: 無署名の 2 組から 5 組になる
h=$(new_home t1 "{\"env\":${env_current}}" "${state_true}")
run "${h}"
if [[ $(rc "${h}") == 0 ]] && same "$(git_env "${h}")" "$(expect_env "${all_pairs}")"; then
  ok "true: 無署名の 2 組に HTTPS の 3 組が足されて 5 組になる"
else
  ng "true: 5 組になる" "rc=$(rc "${h}") got=$(git_env "${h}")"
fi

# 2. 冪等: もう一度流しても変わらない
before=$(jq -cS . "${h}/.claude/settings.json")
run "${h}"
if [[ $(rc "${h}") == 0 && $(jq -cS . "${h}/.claude/settings.json") == "${before}" ]] && grep -q '登録済み' "${h}/out"; then
  ok "true を 2 回流しても変わらない"
else
  ng "true を 2 回流しても変わらない" "rc=$(rc "${h}") out=$(cat "${h}/out")"
fi

# 3. true → false: HTTPS の 3 組が消え、無署名の 2 組だけ残る
printf '%s\n' "${state_false}" >"${h}/.local/state/dotfiles/claude-env.json"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && same "$(git_env "${h}")" "$(expect_env "${base_pairs}")"; then
  ok "true → false で HTTPS の 3 組が消える"
else
  ng "true → false で HTTPS の 3 組が消える" "got=$(git_env "${h}")"
fi

# 4. false → true: また 5 組に戻る
printf '%s\n' "${state_true}" >"${h}/.local/state/dotfiles/claude-env.json"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && same "$(git_env "${h}")" "$(expect_env "${all_pairs}")"; then
  ok "false → true で 5 組に戻る"
else
  ng "false → true で 5 組に戻る" "got=$(git_env "${h}")"
fi

# 5. 管理しない組は順序ごと残り、管理するキーの古い値は捨てられる
init='{"env":{"FOO":"bar","GIT_CONFIG_COUNT":"3","GIT_CONFIG_KEY_0":"core.hooksPath","GIT_CONFIG_VALUE_0":"/x","GIT_CONFIG_KEY_1":"commit.gpgsign","GIT_CONFIG_VALUE_1":"true","GIT_CONFIG_KEY_2":"url.https://github.com/.insteadOf","GIT_CONFIG_VALUE_2":"foo:"},"permissions":{"allow":["x"]}}'
h=$(new_home t5 "${init}" "${state_true}")
run "${h}"
want=$(expect_env "$(jq -cn --argjson p "${all_pairs}" '[{"k":"core.hooksPath","v":"/x"}] + $p')")
if same "$(git_env "${h}")" "${want}"; then
  ok "管理しない組 (core.hooksPath) は先頭に残り、管理キーの古い値は消える"
else
  ng "管理しない組は残り、管理キーの古い値は消える" "got=$(git_env "${h}")"
fi
if [[ $(jq -r '.env.FOO' "${h}/.claude/settings.json") == bar && $(jq -c '.permissions' "${h}/.claude/settings.json") == '{"allow":["x"]}' ]]; then
  ok "env の他のキーと settings の他のキーは残る"
else
  ng "env の他のキーと settings の他のキーは残る" "$(jq -c . "${h}/.claude/settings.json")"
fi

# 6. 状態ファイルが無い: 警告して exit 0、settings.json は変えない
h=$(new_home t6 "{\"env\":${env_current}}" "")
before=$(jq -cS . "${h}/.claude/settings.json")
run "${h}"
if [[ $(rc "${h}") == 0 && $(jq -cS . "${h}/.claude/settings.json") == "${before}" ]] && grep -q 'claude-env.json' "${h}/err"; then
  ok "状態ファイルが無ければ警告して飛ばす (exit 0、変更なし)"
else
  ng "状態ファイルが無ければ警告して飛ばす" "rc=$(rc "${h}") err=$(cat "${h}/err")"
fi

# 7. 状態ファイルの形が違う: exit 1、settings.json は変えない
h=$(new_home t7 "{\"env\":${env_current}}" '{"managed":"x"}')
before=$(jq -cS . "${h}/.claude/settings.json")
run "${h}"
if [[ $(rc "${h}") == 1 && $(jq -cS . "${h}/.claude/settings.json") == "${before}" ]]; then
  ok "状態ファイルの形が違えば exit 1 で止まり、変更しない"
else
  ng "状態ファイルの形が違えば exit 1" "rc=$(rc "${h}") err=$(cat "${h}/err")"
fi

# 8. settings.json が無い: 作って 5 組を書く
h=$(new_home t8 "" "${state_true}")
run "${h}"
if [[ $(rc "${h}") == 0 ]] && same "$(git_env "${h}")" "$(expect_env "${all_pairs}")"; then
  ok "settings.json が無ければ作って書く"
else
  ng "settings.json が無ければ作って書く" "rc=$(rc "${h}") err=$(cat "${h}/err")"
fi

# 9. true で gh が未ログイン: 警告を出す。env は書き、exit 0
h=$(new_home t9 "{\"env\":${env_current}}" "${state_true}")
run "${h}" GH_FAKE_LOGGED_IN=0
if [[ $(rc "${h}") == 0 ]] && same "$(git_env "${h}")" "$(expect_env "${all_pairs}")" \
  && grep -q 'gh auth login' "${h}/err" && grep -q 'gitViaGh' "${h}/err"; then
  ok "true で gh 未ログインなら警告 (gh auth login / gitViaGh を案内)、env は書く"
else
  ng "true で gh 未ログインなら警告" "rc=$(rc "${h}") err=$(cat "${h}/err")"
fi

# 10. 登録済みでも gh 未ログインなら警告する
run "${h}" GH_FAKE_LOGGED_IN=0
if [[ $(rc "${h}") == 0 ]] && grep -q 'gh auth login' "${h}/err"; then
  ok "登録済みでも gh 未ログインなら警告する"
else
  ng "登録済みでも gh 未ログインなら警告する" "err=$(cat "${h}/err")"
fi

# 11. true で gh がログイン済み: 警告しない
h=$(new_home t11 "{\"env\":${env_current}}" "${state_true}")
run "${h}" GH_FAKE_LOGGED_IN=1
if [[ $(rc "${h}") == 0 ]] && ! grep -q 'gh auth login' "${h}/err"; then
  ok "true で gh ログイン済みなら警告しない"
else
  ng "true で gh ログイン済みなら警告しない" "err=$(cat "${h}/err")"
fi

# 12. false では gh を見ない (未ログインでも警告しない)
h=$(new_home t12 "{\"env\":${env_current}}" "${state_false}")
run "${h}" GH_FAKE_LOGGED_IN=0
if [[ $(rc "${h}") == 0 ]] && ! grep -q 'gh auth login' "${h}/err"; then
  ok "false なら gh 未ログインでも警告しない"
else
  ng "false なら gh 未ログインでも警告しない" "err=$(cat "${h}/err")"
fi

# 13. true で gh が PATH に無い: 「見つかりません」と出す (「ログインしていません」ではない)
h=$(new_home t13 "{\"env\":${env_current}}" "${state_true}")
env HOME="${h}" XDG_CONFIG_HOME="${h}/.config" GIT_CONFIG_NOSYSTEM=1 PATH="${nogh_bin}" \
  "${BASH}" "${script}" >"${h}/out" 2>"${h}/err"
echo $? >"${h}/rc"
if [[ $(rc "${h}") == 0 ]] && grep -q 'gh が見つかりません' "${h}/err" && ! grep -q 'ログインしていません' "${h}/err"; then
  ok "true で gh が無ければ「見つかりません」と出す"
else
  ng "true で gh が無ければ「見つかりません」と出す" "rc=$(rc "${h}") err=$(cat "${h}/err")"
fi

# 14. 未ログインのときは「見つかりません」とは言わない
h=$(new_home t14 "{\"env\":${env_current}}" "${state_true}")
run "${h}" GH_FAKE_LOGGED_IN=0
if grep -q 'ログインしていません' "${h}/err" && ! grep -q '見つかりません' "${h}/err"; then
  ok "未ログインなら「ログインしていません」だけを出す"
else
  ng "未ログインなら「ログインしていません」だけを出す" "err=$(cat "${h}/err")"
fi

# 15. true で git の設定ファイルに別の credential helper がある: 1 行ずつ字下げして警告する
h=$(new_home t15 "{\"env\":${env_current}}" "${state_true}")
printf '[credential]\n\thelper = store\n' >"${h}/.gitconfig"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && grep -q 'credential helper' "${h}/err" \
  && grep -qx '     global credential.helper store' "${h}/err"; then
  ok "true で設定ファイルに別の helper (store) があれば、scope と一緒に警告する"
else
  ng "true で設定ファイルに別の helper があれば警告する" "rc=$(rc "${h}") err=$(cat "${h}/err")"
fi

# 16. false なら設定ファイルの helper は見ない
h=$(new_home t16 "{\"env\":${env_current}}" "${state_false}")
printf '[credential]\n\thelper = store\n' >"${h}/.gitconfig"
run "${h}"
if ! grep -q 'credential helper' "${h}/err"; then
  ok "false なら設定ファイルの helper を見ない"
else
  ng "false なら設定ファイルの helper を見ない" "err=$(cat "${h}/err")"
fi

# 17. gh auth setup-git が書く形 (空のリセット + gh) は警告しない
h=$(new_home t17 "{\"env\":${env_current}}" "${state_true}")
printf '[credential "https://github.com"]\n\thelper = \n\thelper = !/nix/store/xxx-gh/bin/gh auth git-credential\n' >"${h}/.gitconfig"
run "${h}"
if ! grep -q 'credential helper' "${h}/err"; then
  ok "gh auth setup-git の形 (空 + gh) は警告しない"
else
  ng "gh auth setup-git の形は警告しない" "err=$(cat "${h}/err")"
fi

# 18. env (command scope) の helper は見ない (Claude のセッションの中から流した場合)
h=$(new_home t18 "{\"env\":${env_current}}" "${state_true}")
run "${h}" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=store
if ! grep -q 'credential helper' "${h}/err"; then
  ok "env で渡された helper は設定ファイルの helper として扱わない"
else
  ng "env の helper は扱わない" "err=$(cat "${h}/err")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
