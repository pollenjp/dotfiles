#!/usr/bin/env bash
# shellcheck shell=bash
# jq の式 ($in など) を文字のまま書く所が多いので、ファイル全体で SC2016 を止める
# shellcheck disable=SC2016
#
# nix/scripts/bootstrap-windows-international.sh の振る舞いを、使い捨ての HOME と偽の checkout・偽の pwsh.exe で確かめる。
#
#   bash nix/tests/bootstrap-windows-international.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-international-test) が Nix のサンドボックスで流す。
# CI の `nix flake check` もこれを通る。使うのは bash・jq・git・coreutils・grep・sed・awk だけ。
#
# ## 確かめること
#
#   - --check は managed.json だけを見る (pwsh.exe を呼ばない)。知らない名前・文字列でない値・空・長すぎる値・
#     制御文字・object でない・ファイルが無い・jq --indent 4 の形でない、のどれでも止まる。引数の組み合わせの誤りは exit 2
#
# ## 偽の checkout と偽の pwsh.exe
#
# script は自分のいる checkout の win/international/managed.json を読むので、ケースごとに <ケース>/repo/nix/scripts/ へ
# 写して流す。要るコマンドだけを symlink で並べた PATH で流し、本物の pwsh.exe と Windows には触らない。出力は
# <ケース>/stdout と <ケース>/stderr に残し、grep には直にファイルを渡す (パイプの grep -q は、pipefail の下で
# SIGPIPE を拾って落ちることがある。TKT-155)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-international.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-international-test.XXXXXX")
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

# 要るコマンドだけを並べた PATH (script と偽の pwsh.exe が使うもの。pwsh.exe は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in jq git cat mkdir mktemp mv cp rm date sort sed cmp dirname od base64 tr timeout awk; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# 持つ値 (jq --indent 4 の形)。引数は「名前=値」を並べる。無ければ repo と同じ 3 つ
managed_json() {
  if (($# == 0)); then
    set -- sShortDate=yyyy-MM-dd sTimeFormat=HH:mm:ss sShortTime=HH:mm
  fi
  printf '%s\n' "$@" | jq -R 'capture("^(?<k>[^=]*)=(?<v>.*)$")' | jq -s --indent 4 'map({(.k): .v}) | add // {}'
}

# 1 ケースぶんを作る。$1: 名前
new_case() {
  local c="${work}/$1"
  mkdir -p "${c}/home/.local/state/dotfiles" "${c}/home/bin" "${c}/repo/nix/scripts" "${c}/repo/win/international"
  cp "${script}" "${c}/repo/nix/scripts/bootstrap-windows-international.sh"
  jq -n --arg home "${c}/win" '{enable: true, version: 1, windowsHome: $home}' \
    >"${c}/home/.local/state/dotfiles/windows-files.json"
  managed_json >"${c}/repo/win/international/managed.json"
  echo "${c}"
}

managed() { printf '%s' "$1/repo/win/international/managed.json"; }

# $1: ケース、残り: script の引数。環境変数は呼び出し側で付ける
run() {
  local c=$1
  shift
  env HOME="${c}/home" PATH="${c}/home/bin:${sys_bin}" "${BASH}" "${c}/repo/nix/scripts/bootstrap-windows-international.sh" "$@" \
    >"${c}/stdout" 2>"${c}/stderr"
  echo $? >"${c}/rc"
}
rc() { cat "$1/rc"; }
outerr() { cat "$1/stdout" "$1/stderr"; }
# 出力 (stdout か stderr) に $2 があるか
has() { grep -qF -- "$2" "$1/stdout" "$1/stderr"; }
# 偽の pwsh.exe が呼ばれたか
called() { [[ -e $1/home/pwsh-modes ]]; }

echo "== bootstrap-windows-international.sh: ${script}"

# c1. 3 つの値: OK。pwsh.exe は呼ばない
c=$(new_case c1)
run "${c}" --check
if [[ $(rc "${c}") == 0 ]] && has "${c}" 'win/international/managed.json: OK (持つ値 3 件)' && ! called "${c}"; then
  ok "--check は 3 つの値の managed.json を通し、pwsh.exe を呼ばない"
else
  ng "--check (3 つの値)" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# c2. 知らない名前
c=$(new_case c2)
managed_json sShortDate=yyyy-MM-dd 'sLongDate=dddd, MMMM d, yyyy' >"$(managed "${c}")"
run "${c}" --check
if [[ $(rc "${c}") == 1 ]] && has "${c}" '知らない名前です: sLongDate'; then
  ok "--check は知らない名前で止まる"
else
  ng "--check (知らない名前)" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# c3. 値の誤り: 文字列でない・空・長すぎる・制御文字
check_bad_value() {
  local label=$1 json=$2 want=$3
  c=$(new_case "c3-${label}")
  jq --indent 4 . <<<"${json}" >"$(managed "${c}")"
  run "${c}" --check
  if [[ $(rc "${c}") == 1 ]] && has "${c}" "${want}"; then
    ok "--check は値の誤り (${label}) で止まる"
  else
    ng "--check (${label})" "rc=$(rc "${c}") $(outerr "${c}")"
  fi
}
check_bad_value number '{"sShortDate": 1}' 'sShortDate の値が文字列ではありません'
check_bad_value empty '{"sShortDate": ""}' 'sShortDate の値が空です'
check_bad_value long "$(jq -n '{sShortDate: ([range(80)] | map("y") | join(""))}')" 'sShortDate の値が長すぎます (80 字。79 字まで)'
check_bad_value control '{"sShortTime": "HH:\tmm"}' 'sShortTime の値に制御文字があります'

# c4. object でない・ファイルが無い
c=$(new_case c4-array)
echo '[]' >"$(managed "${c}")"
run "${c}" --check
if [[ $(rc "${c}") == 1 ]] && has "${c}" 'JSON の object ではありません'; then
  ok "--check は object でない managed.json で止まる"
else
  ng "--check (object でない)" "rc=$(rc "${c}") $(outerr "${c}")"
fi
c=$(new_case c4-missing)
rm -f "$(managed "${c}")"
run "${c}" --check
if [[ $(rc "${c}") == 1 ]] && has "${c}" 'win/international/managed.json がありません'; then
  ok "--check は managed.json が無ければ止まる"
else
  ng "--check (ファイルが無い)" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# c5. 中身は正しいが jq --indent 4 の形でない
c=$(new_case c5)
jq -c . <<<"$(managed_json)" >"$(managed "${c}")"
run "${c}" --check
if [[ $(rc "${c}") == 1 ]] && has "${c}" 'jq --indent 4 の出力と違います' && has "${c}" 'jq --indent 4 . win/international/managed.json'; then
  ok "--check は jq --indent 4 の形でない managed.json で止まり、整えるコマンドを出す"
else
  ng "--check (形)" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# a1. 引数の組み合わせの誤り・知らない引数
c=$(new_case a1)
bad_args=0
for args in '--check --force' '--check --dry-run' '--import --force' '--import --dry-run' '--bogus'; do
  # shellcheck disable=SC2086  # 引数を語に分けて渡す
  run "${c}" ${args}
  if [[ $(rc "${c}") != 2 ]]; then
    bad_args=1
    ng "引数 ${args} が exit 2 にならない" "rc=$(rc "${c}") $(outerr "${c}")"
  fi
done
if ((bad_args == 0)); then
  ok "引数の組み合わせの誤りと知らない引数は exit 2"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
