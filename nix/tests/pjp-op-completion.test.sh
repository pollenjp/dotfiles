#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/pkgs/pjp-op/op-completion.fish (WSL の op の wrapper を入れるマシンの、fish の op の補完) を、本物の fish と偽の op で
# 確かめる。
#
#   bash nix/tests/pjp-op-completion.test.sh [<op-completion.fish のパス>]
#
# flake の checks (pjp-op-completion-test) が Nix のサンドボックスで流す。使うのは bash・coreutils・fish。
#
# ## 確かめること
#
#   前提: 置き場に op.fish が無いと、fish に同梱の補完が op completion fish を打ち、op の stderr が出る (この補完が要る理由。
#     テストの fish が置き場の補完を読む作りかの確かめも兼ねる)
#   op を呼ばない: 下のどの行の補完でも、偽の op は 1 回も呼ばれず、fish の stderr は空
#   op <Tab>: --reason とトップのコマンド (item・read・run・vault・whoami・help など) を出し、ファイルは出さない
#   op --<Tab>: --reason と op の global の flag (--account・--format・--help・--version)
#   --reason: 一度書いたら (--reason X・--reason=X) もう出さない。--reason の値の補完では、コマンドもファイルも出さない
#   コマンドの並び: --reason・--account などの値をコマンドと読まずに 2 段目 (op item <Tab> → get・list・create…) を出す。
#     3 段目 (op connect vault <Tab>) に vault の 2 段目を出さない。op help <Tab> はトップのコマンド
#   flag: op item get --<Tab> は item get の flag (--vault・--fields・--reveal・--otp) と global の flag と --reason で、ほかの
#     コマンドの flag (--out-file) は出さない。op --format <Tab> は human-readable と json
#   ファイル: --out-file の値と、op document create の引数ではファイルを出す
#   -- の後ろ (op run の子のコマンド): そのコマンドの名前と、そのコマンドの補完 (flag) を出し、op の flag は出さない
#
# ## 作り
#
# 偽の op は、呼ばれた引数を work/op.calls に足し、stderr に断りの文を出して 2 で終わる (wrapper が理由なしで断るのと同じ)。
# fish は --no-config で起こし (fish_complete_path は空)、fish_complete_path の頭にテストする補完 (op.fish に写したもの) と
# 子のコマンドの補完の置き場を足して、complete -C で候補を出す。~/.config/fish/completions に置いたのと同じく、同梱の補完より
# 先に読まれる。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
completion=${1:-${here}/../pkgs/pjp-op/op-completion.fish}
work=$(mktemp -d "${TMPDIR:-/tmp}/pjp-op-completion-test.XXXXXX")
work=$(cd "${work}" && pwd -P)
trap 'rm -rf "${work}"' EXIT

export LC_ALL=C.UTF-8
export HOME=${work}/home
export XDG_CONFIG_HOME=${HOME}/.config XDG_DATA_HOME=${HOME}/.local/share XDG_CACHE_HOME=${HOME}/.cache
mkdir -p "${HOME}" "${work}/bin" "${work}/comp" "${work}/empty" "${work}/cwd"
export PATH=${work}/bin:${PATH}

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

cp "${completion}" "${work}/comp/op.fish"

cat >"${work}/bin/op" <<EOF
#!${BASH}
printf '%s\n' "\$*" >>"${work}/op.calls"
echo "op (pjp-op): 理由 (--reason) がありません。人が打つときも要ります。" >&2
exit 2
EOF
printf '#!%s\nexit 0\n' "${BASH}" >"${work}/bin/pjp-fake-child"
chmod +x "${work}/bin/op" "${work}/bin/pjp-fake-child"
echo 'complete -c pjp-fake-child -l child-flag -d "child flag"' >"${work}/comp/pjp-fake-child.fish"
touch "${work}/cwd/afile.txt"

# cands <行> [<補完の置き場>]: その行の補完の候補の名前を 1 行に 1 つ cand に、fish の stderr を cand_err に入れる
cands() {
  # shellcheck disable=SC2016 # fish の式 ($argv は fish が読む)
  cand=$(cd "${work}/cwd" && fish --no-config -c 'set -p fish_complete_path $argv[1]; complete -C $argv[2]' \
    "${2:-${work}/comp}" "$1" 2>"${work}/fish.err" | cut -f1)
  cand_err=$(<"${work}/fish.err")
}

# has <名前>…: 名前がどれも cand にある。lacks <名前>…: 名前がどれも cand に無い
has() {
  local w
  for w in "$@"; do
    [[ $'\n'${cand}$'\n' == *$'\n'"${w}"$'\n'* ]] || return 1
  done
}
lacks() {
  local w
  for w in "$@"; do
    [[ $'\n'${cand}$'\n' != *$'\n'"${w}"$'\n'* ]] || return 1
  done
}

shown() {
  printf 'cand=%s err=%s' "$(tr '\n' ' ' <<<"${cand}")" "${cand_err}"
}

echo "== 前提"
cands "op " "${work}/empty"
if [[ $(cat "${work}/op.calls" 2>/dev/null) == "completion fish" && ${cand_err} == *理由* ]]; then
  ok "置き場に op.fish が無いと、fish に同梱の補完が op completion fish を打ち、op の stderr が出る"
else
  ng "置き場に op.fish が無いと、fish に同梱の補完が op completion fish を打ち、op の stderr が出る" \
    "calls=$(cat "${work}/op.calls" 2>&1) $(shown)"
fi
rm -f "${work}/op.calls"

# 以降は op.fish を置いた補完。どの行でも fish の stderr は空で、最後に op が呼ばれていないことを見る
quiet() {
  [[ -z ${cand_err} ]]
}

echo "== トップ"
cands "op "
if has --reason item read run vault whoami help && lacks afile.txt && quiet; then
  ok "op <Tab> は --reason とトップのコマンドを出し、ファイルは出さない"
else
  ng "op <Tab> は --reason とトップのコマンドを出し、ファイルは出さない" "$(shown)"
fi
cands "op --"
if has --reason --account --format --help --version && quiet; then
  ok "op --<Tab> は --reason と global の flag を出す"
else
  ng "op --<Tab> は --reason と global の flag を出す" "$(shown)"
fi

echo "== --reason"
cands 'op --reason "a b" '
if has item read && lacks --reason && quiet; then
  ok "--reason \"a b\" の後ろはトップのコマンドを出し、--reason はもう出さない"
else
  ng "--reason \"a b\" の後ろはトップのコマンドを出し、--reason はもう出さない" "$(shown)"
fi
cands "op --reason "
if lacks item read afile.txt && quiet; then
  ok "--reason の値の補完では、コマンドもファイルも出さない"
else
  ng "--reason の値の補完では、コマンドもファイルも出さない" "$(shown)"
fi
cands "op --reason=x item get --"
if has --vault && lacks --reason && quiet; then
  ok "--reason=x を書いた行では --reason を出さない"
else
  ng "--reason=x を書いた行では --reason を出さない" "$(shown)"
fi

echo "== コマンドの並び"
cands 'op --reason "a b" item '
if has get list create edit delete && lacks read user && quiet; then
  ok "op --reason \"a b\" item <Tab> は item の 2 段目を出す (トップや vault の 2 段目は出さない)"
else
  ng "op --reason \"a b\" item <Tab> は item の 2 段目を出す (トップや vault の 2 段目は出さない)" "$(shown)"
fi
cands "op --account my vault "
if has list get create user && lacks item && quiet; then
  ok "--account の値をコマンドと読まず、op --account my vault <Tab> は vault の 2 段目を出す"
else
  ng "--account の値をコマンドと読まず、op --account my vault <Tab> は vault の 2 段目を出す" "$(shown)"
fi
cands "op connect vault "
if lacks create list user item && quiet; then
  ok "op connect vault <Tab> (3 段目) に vault の 2 段目もトップのコマンドも出さない"
else
  ng "op connect vault <Tab> (3 段目) に vault の 2 段目もトップのコマンドも出さない" "$(shown)"
fi
cands "op help "
if has item vault read && lacks get && quiet; then
  ok "op help <Tab> はトップのコマンドを出す"
else
  ng "op help <Tab> はトップのコマンドを出す" "$(shown)"
fi

echo "== flag"
cands "op item get --"
if has --vault --fields --reveal --otp --account --reason && lacks --out-file && quiet; then
  ok "op item get --<Tab> は item get の flag・global の flag・--reason を出し、ほかのコマンドの flag は出さない"
else
  ng "op item get --<Tab> は item get の flag・global の flag・--reason を出し、ほかのコマンドの flag は出さない" "$(shown)"
fi
cands "op --format "
if has human-readable json && lacks item && quiet; then
  ok "op --format <Tab> は human-readable と json"
else
  ng "op --format <Tab> は human-readable と json" "$(shown)"
fi

echo "== ファイル"
cands "op read --out-file "
if has afile.txt && quiet; then
  ok "--out-file の値ではファイルを出す"
else
  ng "--out-file の値ではファイルを出す" "$(shown)"
fi
cands "op document create "
if has afile.txt && quiet; then
  ok "op document create <Tab> はファイルを出す"
else
  ng "op document create <Tab> はファイルを出す" "$(shown)"
fi

echo "== -- の後ろ"
cands "op --reason x run -- pjp-fake-ch"
if has pjp-fake-child && quiet; then
  ok "op run -- の後ろは子のコマンドの名前を出す"
else
  ng "op run -- の後ろは子のコマンドの名前を出す" "$(shown)"
fi
cands "op --reason x run --env-file .env -- pjp-fake-child --"
if has --child-flag && lacks --reason --account --env-file && quiet; then
  ok "子のコマンドの flag を出し、op の flag は出さない"
else
  ng "子のコマンドの flag を出し、op の flag は出さない" "$(shown)"
fi

echo "== op を呼ばない"
if [[ ! -e ${work}/op.calls ]]; then
  ok "上のどの補完でも op は呼ばれない"
else
  ng "上のどの補完でも op は呼ばれない" "$(cat "${work}/op.calls")"
fi

echo
echo "pass=${pass} fail=${fail}"
[[ ${fail} == 0 ]]
