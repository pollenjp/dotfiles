#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/ の script が持つ warn() と summary_warn() を、script ごとに切り出して確かめる。
#
#   bash nix/tests/warn-helpers.test.sh [<nix/scripts のパス>]
#
# flake の checks (warn-helpers-test) が Nix のサンドボックスで流す。
#
# setup.sh は、手順を止めない警告を最後の「結果」の後にまとめて出し直す (TKT-146。setup.sh の
# 「警告のまとめ」の節)。子の script は単体で配り・テストするので、warn() / summary_warn() を
# 共通のファイルにせず各 script に同じ形で持つ。どれか 1 つが崩れると、その script の警告だけが
# まとめから黙って落ちるので、warn() を持つ script を全部並べて同じように振る舞うかを見る。
#
# ## 確かめること (warn() を持つ script ごと)
#
#   - warn は 1 行目に「!! 」を付け、2 つ目からの引数 (と引数の中の改行の後) を 3 文字字下げして
#     stderr に出す。stdout には出さない
#   - DOTFILES_SETUP_WARNINGS があれば、同じ行を (「!! 」を付けずに) そのファイルへ足す。無ければ書かない
#   - summary_warn は、その場には出さずにファイルへだけ足す
#   - ファイルへ書けなくても warn は失敗せず、余計なエラーも出さない (手順を止めない)
#   - 定義の書き方 (`warn() {`・`warn () {`・`function warn {`) を問わず、warn() を持つ script を全部見る。
#     1 つも見つからなければ落ちる (取り違えた場所を渡して、何も見ずに通さない)

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
dir=${1:-${here}/../scripts}
work=$(mktemp -d "${TMPDIR:-/tmp}/warn-helpers-test.XXXXXX")
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

# script から warn() と summary_warn() の定義だけを取り出す (読み込むと script が最後まで走るため)。
# 定義の 1 行目は `warn() {`・`warn () {`・`function warn {` のどれでもよい
helpers_of() {
  awk '
    /^(function[[:space:]]+)?(warn|summary_warn)[[:space:]]*(\(\))?[[:space:]]*\{/ {
      f = 1; print; if ($0 ~ /\}[[:space:]]*$/) f = 0; next
    }
    f { print; if ($0 ~ /^\}$/) f = 0 }
  ' "$1"
}

# 取り出した定義を読み込んで、$2 のコマンドを流す。色の変数 (setup.sh などが使う) は空にする。
# stderr は <ケース>/err、stdout は <ケース>/out、終了コードは <ケース>/rc に残す
call() {
  local c=$1
  mkdir -p "${c}"
  c_yellow="" c_reset="" "${BASH}" -c "${fns}"$'\n'"$2" >"${c}/out" 2>"${c}/err"
  echo $? >"${c}/rc"
}

# 期待する stderr とファイル (手で書いた値)
want_err=$'!! 見出し\n   続き 1\n     続き 2\n   改行の前\n   改行の後'
want_file=$'見出し\n   続き 1\n     続き 2\n   改行の前\n   改行の後'
# warn に渡す引数: 見出し / 続き 1 / "  続き 2" / 改行を含む 1 つ (改行の後も続きの行になる)
args="'見出し' '続き 1' '  続き 2' \$'改行の前\\n改行の後'"

checked=0
for f in "${dir}"/*.sh; do
  name=$(basename "${f}")
  # warn の定義が無い script は見ない。書き方 (`warn() {`・`warn () {`・`function warn {`) は問わず、
  # 定義があるのに取り出せなければ、下の 1 で落ちる (黙って見逃さない)
  if ! grep -qE '^(function[[:space:]]+)?warn[[:space:]]*(\(\))?[[:space:]]*\{' "${f}"; then
    continue
  fi
  fns=$(helpers_of "${f}")
  checked=$((checked + 1))
  c="${work}/${name%.sh}"

  # 1. setup.sh から走るとき: その場 (stderr) と、まとめ用のファイルの両方に出す
  call "${c}/a" "DOTFILES_SETUP_WARNINGS='${c}/a/w' warn ${args}"
  if [[ $(cat "${c}/a/rc") == 0 && $(cat "${c}/a/err") == "${want_err}" && ! -s ${c}/a/out ]] \
    && [[ -f ${c}/a/w && $(cat "${c}/a/w") == "${want_file}" ]]; then
    ok "${name}: warn は「!! 」と字下げで stderr に出し、同じ行をまとめ用のファイルへ足す"
  else
    ng "${name}: warn (DOTFILES_SETUP_WARNINGS あり)" "rc=$(cat "${c}/a/rc") err=$(cat "${c}/a/err") file=$(cat "${c}/a/w" 2>/dev/null)"
  fi

  # 2. 単体で流したとき (変数が無い): その場にだけ出す
  call "${c}/b" "cd '${c}/b' && warn ${args}"
  if [[ $(cat "${c}/b/rc") == 0 && $(cat "${c}/b/err") == "${want_err}" ]] \
    && [[ -z $(find "${c}/b" -mindepth 1 ! -name out ! -name err ! -name rc) ]]; then
    ok "${name}: DOTFILES_SETUP_WARNINGS が無ければ、その場にだけ出す"
  else
    ng "${name}: warn (DOTFILES_SETUP_WARNINGS なし)" "rc=$(cat "${c}/b/rc") err=$(cat "${c}/b/err") $(ls -A "${c}/b")"
  fi

  # 3. ファイルへ書けない: 失敗せず、余計なエラーも出さない
  call "${c}/c" "DOTFILES_SETUP_WARNINGS='${c}/c/無い/w' warn ${args}"
  if [[ $(cat "${c}/c/rc") == 0 && $(cat "${c}/c/err") == "${want_err}" ]]; then
    ok "${name}: まとめ用のファイルへ書けなくても、失敗せず余計なエラーも出さない"
  else
    ng "${name}: 書けないとき" "rc=$(cat "${c}/c/rc") err=$(cat "${c}/c/err")"
  fi

  # 4. summary_warn: その場には出さず、ファイルへだけ足す (同じファイルへ続けて足せる)
  if grep -qE '^(function[[:space:]]+)?summary_warn[[:space:]]*(\(\))?[[:space:]]*\{' <<<"${fns}"; then
    call "${c}/d" "DOTFILES_SETUP_WARNINGS='${c}/d/w' summary_warn ${args}; DOTFILES_SETUP_WARNINGS='${c}/d/w' summary_warn '2 件目'"
    if [[ $(cat "${c}/d/rc") == 0 && ! -s ${c}/d/err && ! -s ${c}/d/out ]] \
      && [[ $(cat "${c}/d/w" 2>/dev/null) == "${want_file}"$'\n2 件目' ]]; then
      ok "${name}: summary_warn はその場に出さず、まとめ用のファイルへだけ足す"
    else
      ng "${name}: summary_warn" "rc=$(cat "${c}/d/rc") err=$(cat "${c}/d/err") file=$(cat "${c}/d/w" 2>/dev/null)"
    fi
  fi
done

# 取り違えた場所を渡して 1 つも見ていない、を通さない
if ((checked > 0)); then
  ok "warn() を持つ script を ${checked} 個見た"
else
  ng "warn() を持つ script が 1 つも無い (${dir})"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
