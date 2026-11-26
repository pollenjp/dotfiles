#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-notion-tokens.sh が、Notion の API キーを宣言したプロファイル (状態ファイル
# ~/.local/state/dotfiles/notion-tokens.json) ごとに、~/.config/pjp/env の変数の行の有無とファイルの権限を、値を出さずに
# 確かめて知らせることを、使い捨ての HOME と作り物の値で確かめる。
#
#   bash nix/tests/bootstrap-notion-tokens.test.sh [<bootstrap-notion-tokens.sh のパス>]
#
# flake の checks (bootstrap-notion-tokens-test) が Nix のサンドボックスで流す。使うのは bash・jq・coreutils・findutils・grep だけ。
#
# ## 確かめること
#
#   - 宣言したプロファイルの変数の行 (行の頭が <var>= で、= の後ろが空でない行) があり、権限が 600 なら、警告を出さずに
#     「入っています」と変数名を出す (行の末尾の CR (CRLF で保存したファイル) は値に数えない)
#   - 行が無ければ、プロファイルごとに警告し、プロファイルの名前・種類・変数名と、入れ方 (ユーザーが自分の端末で
#     pjp notion-profile set-token <名前> を打つ) を出す。item があれば、その 1Password の項目の参照も出す。行の数えない形:
#     # で始まる行・頭に空白のある行・= の後ろが空か CR だけの行・名前の後ろが続く別の変数 (<var>X=)・export <var>= の行
#   - ~/.config/pjp/env が無くても、行が無いのと同じく警告する (ファイルは作らない)
#   - 2 つのプロファイルのうち 1 つだけ行が無ければ、その 1 つだけを警告する
#   - 権限が 600 より広い (644・640・604・700) なら、権限と chmod 600 の手を警告する。600 と、それより狭い 400 は警告しない
#     (symlink なら指す先の権限を見る)
#   - XDG_CONFIG_HOME があれば $XDG_CONFIG_HOME/pjp/env を見る (bash と fish のローダと同じ)
#   - 宣言が無い ({"tokens":{}}) なら、警告を出さずに「宣言はありません」と出す (~/.config/pjp/env が無くても)
#   - 状態ファイルが無い・形が違う (JSON でない・tokens が object でない・kind が知らない字・var が PJP_NOTION_TOKEN_ の形で
#     ない・item が欄まで書いた op:// の参照でない)・jq が無い・~/.config/pjp/env が普通のファイルでない・読めないときは、
#     警告して exit 0 (setup を止めない)。item に値が入っていても、その値は出さない
#   - どのときも終了コードは 0 で、~/.config/pjp/env を書き換えない (中身・権限・inode が変わらない)。値 (作り物の値) は
#     stdout・stderr・まとめ用のファイルのどれにも出さない
#   - setup から走るとき (DOTFILES_SETUP_WARNINGS がある) は、警告を続きの行ごとまとめ用のファイルにも残す。無ければ
#     まとめ用のファイルを作らずに stderr にだけ出す

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-notion-tokens.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-notion-tokens-test.XXXXXX")
trap 'chmod -R u+rwx "${work}" 2>/dev/null; rm -rf "${work}"' EXIT

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

# 作り物の値 (token の形でもない字)。どの出力にも出てはいけない
fake='fake-value-not-a-token-7f3a'
item='op://abcdefghijklmnopqrstuvwxyz/zyxwvutsrqponmlkjihgfedcba/credential'
item_section='op://abcdefghijklmnopqrstuvwxyz/zyxwvutsrqponmlkjihgfedcba/s0000000000000000000000000/credential'

one_integration='{"tokens":{"personal":{"kind":"integration","item":null,"var":"PJP_NOTION_TOKEN_PERSONAL"}}}'
two_profiles='{"tokens":{"personal":{"kind":"integration","item":"'"${item}"'","var":"PJP_NOTION_TOKEN_PERSONAL"},"my-ws":{"kind":"personal","item":"'"${item_section}"'","var":"PJP_NOTION_TOKEN_MY_WS"}}}'

# 1 ケースぶんの HOME を作る。$1: 名前、$2: 状態ファイルの中身 (空なら作らない)。~/.config も作る
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.config" "${h}/.local/state/dotfiles"
  if [[ -n $2 ]]; then printf '%s\n' "$2" >"${h}/.local/state/dotfiles/notion-tokens.json"; fi
  echo "${h}"
}

# ~/.config/pjp/env を $2 の中身 (printf の %b で \r などを読む) で書き、権限を $3 (既定 600) にする
put_env() {
  local f="$1/.config/pjp/env"
  mkdir -p "$1/.config/pjp"
  printf '%b' "$2" >"${f}"
  chmod "${3:-600}" "${f}"
}

# HOME を $1 にして流す。setup から走るときと同じく、まとめ用のファイル ($1/warnings。流すたびに空から) を
# DOTFILES_SETUP_WARNINGS で渡す。残りの引数は env に足す変数 (PATH・XDG_CONFIG_HOME・DOTFILES_SETUP_WARNINGS も上書きできる)。
# 手元の XDG_CONFIG_HOME は外す
run() {
  local h=$1
  shift
  rm -f "${h}/warnings"
  env -u XDG_CONFIG_HOME HOME="${h}" DOTFILES_SETUP_WARNINGS="${h}/warnings" "$@" \
    "${BASH}" "${script}" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
log() { echo "rc=$(rc "$1") out=$(cat "$1/out") err=$(cat "$1/err") warnings=$(cat "$1/warnings" 2>/dev/null)"; }
# 警告を何も出していない (stderr にもまとめにも)
quiet() { [[ ! -s $1/err && ! -s $1/warnings ]]; }
# 警告を出し、まとめにも残した
warned() { [[ -s $1/err && -s $1/warnings ]]; }
# まとめに残した警告の数 (1 行目は字下げなし、続きの行は字下げ)
count_warnings() { grep -c '^[^[:space:]]' "$1/warnings" 2>/dev/null || true; }
# 作り物の値がどれかの出力に出た
leaked() { grep -sqF -- "${fake}" "$1/out" "$1/err" "$1/warnings"; }
mode_is() { [[ -n $(find "$1" -prune -perm "$2") ]]; }
# env の中身・権限・inode の控え (書き換えていないことを比べる)
snapshot() { [[ -e $1 ]] && { stat -c '%a %i' "$1" && cat "$1"; } || echo missing; }

echo "== bootstrap-notion-tokens.sh: ${script}"

# 1. 行があり 600: 警告なしで「入っています」と変数名を出す。値は出さない。env は書き換えない
h=$(new_home t1 "${one_integration}")
put_env "${h}" "FOO=bar\nPJP_NOTION_TOKEN_PERSONAL=${fake}\n"
before=$(snapshot "${h}/.config/pjp/env")
run "${h}"
if [[ $(rc "${h}") == 0 ]] && quiet "${h}" && grep -q '入っています' "${h}/out" \
  && grep -qF 'PJP_NOTION_TOKEN_PERSONAL' "${h}/out" && ! leaked "${h}"; then
  ok "行があり 600 なら、警告なしで「入っています」と変数名を出す (値は出さない)"
else
  ng "行があり 600 なら、警告なしで「入っています」と変数名を出す" "$(log "${h}")"
fi
if [[ $(snapshot "${h}/.config/pjp/env") == "${before}" ]]; then
  ok "env のファイル (.config/pjp/env) を書き換えない (中身・権限・inode が同じ)"
else
  ng "env のファイル (.config/pjp/env) を書き換えない" "$(stat -c '%a %i' "${h}/.config/pjp/env")"
fi

# 1b. CRLF で保存した行 (値の後ろに CR) も、行があると数える
h=$(new_home t1b "${one_integration}")
put_env "${h}" "PJP_NOTION_TOKEN_PERSONAL=${fake}\r\n"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && quiet "${h}" && grep -q '入っています' "${h}/out" && ! leaked "${h}"; then
  ok "CRLF で保存した行も、行があると数える"
else
  ng "CRLF で保存した行も、行があると数える" "$(log "${h}")"
fi

# 2. ~/.config/pjp/env が無い: プロファイルの名前・種類・変数名と入れ方を警告する。ファイルは作らない
h=$(new_home t2 "${one_integration}")
run "${h}"
if [[ $(rc "${h}") == 0 ]] && warned "${h}" && grep -qF 'pjp notion-profile set-token personal' "${h}/warnings" \
  && grep -qF 'PJP_NOTION_TOKEN_PERSONAL' "${h}/warnings" && grep -q 'integration' "${h}/warnings" \
  && [[ ! -e ${h}/.config/pjp/env ]]; then
  ok "env が無ければ、名前・種類・変数名と pjp notion-profile set-token personal を警告する (ファイルは作らない)"
else
  ng "env が無ければ、名前・種類・変数名と入れ方を警告する (ファイルは作らない)" "$(log "${h}")"
fi

# 3. 数えない形の行だけ: 行が無いのと同じく警告する。値は出さない
h=$(new_home t3 "${one_integration}")
put_env "${h}" "# PJP_NOTION_TOKEN_PERSONAL=${fake}\n  PJP_NOTION_TOKEN_PERSONAL=${fake}\nPJP_NOTION_TOKEN_PERSONAL=\nPJP_NOTION_TOKEN_PERSONAL=\r\nPJP_NOTION_TOKEN_PERSONALX=${fake}\nexport PJP_NOTION_TOKEN_PERSONAL=${fake}\n"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && warned "${h}" && grep -qF 'pjp notion-profile set-token personal' "${h}/warnings" \
  && ! grep -q '入っています' "${h}/out" && ! leaked "${h}"; then
  ok "# の行・頭に空白・空か CR だけの値・<var>X=・export <var>= は数えず、行が無いと警告する (値は出さない)"
else
  ng "数えない形の行だけなら、行が無いと警告する" "$(log "${h}")"
fi

# 4. 2 つのプロファイルのうち my-ws だけ行が無い: my-ws だけを警告し、item の参照も出す
h=$(new_home t4 "${two_profiles}")
put_env "${h}" "PJP_NOTION_TOKEN_PERSONAL=${fake}\n"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && warned "${h}" && [[ $(count_warnings "${h}") == 1 ]] \
  && grep -qF 'pjp notion-profile set-token my-ws' "${h}/warnings" && grep -qF 'PJP_NOTION_TOKEN_MY_WS' "${h}/warnings" \
  && grep -qF "${item_section}" "${h}/warnings" && ! grep -qF 'set-token personal' "${h}/warnings" \
  && grep -qF 'PJP_NOTION_TOKEN_PERSONAL' "${h}/out" && ! leaked "${h}"; then
  ok "2 つのうち my-ws だけ行が無ければ、my-ws だけを (item の参照つきで) 警告する"
else
  ng "2 つのうち my-ws だけ行が無ければ、my-ws だけを警告する" "$(log "${h}")"
fi

# 5. 権限が 600 より広い: 権限と chmod 600 を警告する。権限は変えない
for m in 644 640 604 700; do
  h=$(new_home "t5-${m}" "${one_integration}")
  put_env "${h}" "PJP_NOTION_TOKEN_PERSONAL=${fake}\n" "${m}"
  run "${h}"
  if [[ $(rc "${h}") == 0 ]] && warned "${h}" && grep -qF "${m}" "${h}/warnings" && grep -qF 'chmod 600' "${h}/warnings" \
    && mode_is "${h}/.config/pjp/env" "${m}" && ! leaked "${h}"; then
    ok "権限が ${m} なら、権限と chmod 600 を警告する (権限は変えない)"
  else
    ng "権限が ${m} なら、権限と chmod 600 を警告する" "$(log "${h}") $(stat -c '%a' "${h}/.config/pjp/env")"
  fi
done

# 5b. 600 より狭い 400 は警告しない
h=$(new_home t5b "${one_integration}")
put_env "${h}" "PJP_NOTION_TOKEN_PERSONAL=${fake}\n" 400
run "${h}"
if [[ $(rc "${h}") == 0 ]] && quiet "${h}" && grep -q '入っています' "${h}/out"; then
  ok "600 より狭い 400 は警告しない"
else
  ng "600 より狭い 400 は警告しない" "$(log "${h}")"
fi

# 5c. symlink なら指す先の権限を見る (指す先が 644 なら警告する)
h=$(new_home t5c "${one_integration}")
mkdir -p "${h}/real" "${h}/.config/pjp"
printf '%s\n' "PJP_NOTION_TOKEN_PERSONAL=${fake}" >"${h}/real/env"
chmod 644 "${h}/real/env"
ln -s "${h}/real/env" "${h}/.config/pjp/env"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && warned "${h}" && grep -qF '644' "${h}/warnings" && grep -q '入っています' "${h}/out" \
  && ! leaked "${h}"; then
  ok "symlink なら指す先を読み、指す先の権限 (644) を警告する"
else
  ng "symlink なら指す先の権限を見る" "$(log "${h}")"
fi

# 6. XDG_CONFIG_HOME があれば $XDG_CONFIG_HOME/pjp/env を見る
h=$(new_home t6 "${one_integration}")
mkdir -p "${h}/xdg/pjp"
printf '%s\n' "PJP_NOTION_TOKEN_PERSONAL=${fake}" >"${h}/xdg/pjp/env"
chmod 600 "${h}/xdg/pjp/env"
run "${h}" XDG_CONFIG_HOME="${h}/xdg"
if [[ $(rc "${h}") == 0 ]] && quiet "${h}" && grep -q '入っています' "${h}/out" && grep -qF "${h}/xdg/pjp/env" "${h}/out"; then
  ok "XDG_CONFIG_HOME があれば \$XDG_CONFIG_HOME/pjp/env を見る"
else
  ng "XDG_CONFIG_HOME があれば \$XDG_CONFIG_HOME/pjp/env を見る" "$(log "${h}")"
fi

# 7. 宣言が無い: 警告なしで「宣言はありません」と出す (env が無くても)
h=$(new_home t7 '{"tokens":{}}')
run "${h}"
if [[ $(rc "${h}") == 0 ]] && quiet "${h}" && grep -q '宣言はありません' "${h}/out"; then
  ok "宣言が無ければ、警告なしで「宣言はありません」と出す (env が無くても)"
else
  ng "宣言が無ければ、警告なしで「宣言はありません」と出す" "$(log "${h}")"
fi

# 8. 状態ファイルが無い: 警告して exit 0
h=$(new_home t8 '')
put_env "${h}" "PJP_NOTION_TOKEN_PERSONAL=${fake}\n"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && warned "${h}" && grep -q '状態ファイルがありません' "${h}/warnings" \
  && grep -q 'home-manager switch' "${h}/warnings" && ! leaked "${h}"; then
  ok "状態ファイルが無ければ、switch を勧めて警告し exit 0"
else
  ng "状態ファイルが無ければ、警告して exit 0" "$(log "${h}")"
fi

# 9. 状態ファイルの形が違う: 警告して exit 0 (env は見ない)
i=0
for bad in 'not json' '{"tokens":[]}' '{"tokens":{"personal":{"kind":"api","item":null,"var":"PJP_NOTION_TOKEN_PERSONAL"}}}' \
  '{"tokens":{"personal":{"kind":"integration","item":null,"var":"X; touch pwned"}}}' \
  '{"tokens":{"personal":{"kind":"integration","item":null}}}' \
  '{"tokens":{"personal":{"kind":"integration","item":"'"${fake}"'","var":"PJP_NOTION_TOKEN_PERSONAL"}}}' \
  '{"tokens":{"personal":{"kind":"integration","item":"op://abcdefghijklmnopqrstuvwxyz/zyxwvutsrqponmlkjihgfedcba","var":"PJP_NOTION_TOKEN_PERSONAL"}}}'; do
  i=$((i + 1))
  h=$(new_home "t9-${i}" "${bad}")
  put_env "${h}" "PJP_NOTION_TOKEN_PERSONAL=${fake}\n"
  run "${h}"
  if [[ $(rc "${h}") == 0 ]] && warned "${h}" && grep -q '形が違います' "${h}/warnings" \
    && ! grep -q '入っています' "${h}/out" && ! leaked "${h}"; then
    ok "状態ファイルの形が違えば警告して exit 0: ${bad//${fake}/<作り物の値>}"
  else
    ng "状態ファイルの形が違えば警告して exit 0: ${bad//${fake}/<作り物の値>}" "$(log "${h}")"
  fi
done

# 10. jq が無い (PATH に何も無い): 警告して exit 0
h=$(new_home t10 "${one_integration}")
mkdir -p "${h}/empty-bin"
run "${h}" PATH="${h}/empty-bin"
if [[ $(rc "${h}") == 0 ]] && warned "${h}" && grep -q 'jq' "${h}/warnings"; then
  ok "jq が無ければ警告して飛ばす (exit 0)"
else
  ng "jq が無ければ警告して飛ばす" "$(log "${h}")"
fi

# 11. ~/.config/pjp/env が普通のファイルでない (ディレクトリ): 警告して exit 0
h=$(new_home t11 "${one_integration}")
mkdir -p "${h}/.config/pjp/env"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && warned "${h}" && grep -q '普通のファイルではない' "${h}/warnings"; then
  ok "env が普通のファイルでなければ、確かめられないと警告して exit 0"
else
  ng "env が普通のファイルでなければ、警告して exit 0" "$(log "${h}")"
fi

# 12. ~/.config/pjp/env を読めない (000): 警告して exit 0。root は読めてしまうので飛ばす
if [[ $(id -u) == 0 ]]; then
  echo "  skip env を読めないとき (root で流しているので、000 のファイルも読めてしまう)"
else
  h=$(new_home t12 "${one_integration}")
  put_env "${h}" "PJP_NOTION_TOKEN_PERSONAL=${fake}\n" 000
  run "${h}"
  if [[ $(rc "${h}") == 0 ]] && warned "${h}" && grep -q '読めない' "${h}/warnings" && ! leaked "${h}"; then
    ok "env を読めなければ、確かめられないと警告して exit 0"
  else
    ng "env を読めなければ、警告して exit 0" "$(log "${h}")"
  fi
fi

# 13. DOTFILES_SETUP_WARNINGS が無い: stderr にだけ出し、まとめ用のファイルを作らない
h=$(new_home t13 "${one_integration}")
rm -f "${h}/warnings"
env -u XDG_CONFIG_HOME -u DOTFILES_SETUP_WARNINGS HOME="${h}" "${BASH}" "${script}" >"${h}/out" 2>"${h}/err"
echo $? >"${h}/rc"
if [[ $(rc "${h}") == 0 && -s ${h}/err && ! -e ${h}/warnings ]] && grep -qF 'pjp notion-profile set-token personal' "${h}/err"; then
  ok "DOTFILES_SETUP_WARNINGS が無ければ、stderr にだけ出してまとめ用のファイルを作らない"
else
  ng "DOTFILES_SETUP_WARNINGS が無ければ、stderr にだけ出す" "$(log "${h}")"
fi

# 14. まとめ用のファイルの形: 1 行目は警告の 1 行目そのもの (「!! 」なし)、続きの行は字下げ (2 の警告で見る)
if [[ $(head -n 1 "${work}/t2/warnings" 2>/dev/null) != '!! '* ]] \
  && grep -qE '^[[:space:]]+.*pjp notion-profile set-token personal' "${work}/t2/warnings"; then
  ok "まとめ用のファイルには、警告を続きの行ごと字下げして残す"
else
  ng "まとめ用のファイルには、警告を続きの行ごと字下げして残す" "$(cat "${work}/t2/warnings" 2>/dev/null)"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
