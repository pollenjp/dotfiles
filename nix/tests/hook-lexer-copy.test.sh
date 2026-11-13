#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/files/claude/hooks/install-iac-guard.sh が写した lexer (awk) の本文が、元の xref-guard.sh と同じかを確かめる。
#
#   bash nix/tests/hook-lexer-copy.test.sh [<nix/files/claude/hooks のパス>]
#
# flake の checks (hook-lexer-copy-test) が Nix のサンドボックスで、hooks/ を丸ごと渡して流す。使うのは bash・coreutils
# と awk だけ。lexer は hook ごとに写して持つ (配置が hook 1 つずつなので、共通のファイルを置かない) ので、片方だけを直すと
# 読み方が黙ってずれる。ずれていたら、どちらを直したかを見て、もう片方にも当てる (写しは代入の行だけが違ってよい)。
#
# ## 確かめること
#
#   - xref-guard.sh と install-iac-guard.sh の lexer の本文 (<<'AWK' の次の行から、終わりの印 AWK の行の手前まで) が同じ
#   - どちらの hook にも lexer の本文がある (取り出せなければ落ちる)

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
hooks=${1:-${here}/../files/claude/hooks}

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

# lexer_body <hook>: 最初の <<'AWK' の次の行から、終わりの印 AWK の行の手前までを出す (lexer は各 hook の最初の AWK の heredoc)
lexer_body() {
  awk 'started && $0 == "AWK" { exit } started { print } /<<.AWK.( \|\| true)?$/ { started = 1 }' "$1"
}

echo "== hook の lexer の写し: ${hooks}"

src=$(lexer_body "${hooks}/xref-guard.sh")
copy=$(lexer_body "${hooks}/install-iac-guard.sh")
if [[ -n ${src} && -n ${copy} ]]; then
  ok "xref-guard.sh と install-iac-guard.sh の両方から lexer の本文を取り出せる ($(wc -l <<<"${src}") 行)"
else
  ng "lexer の本文を取り出せる" "xref-guard=$(wc -c <<<"${src}") bytes install-iac-guard=$(wc -c <<<"${copy}") bytes"
fi
if [[ -n ${src} && ${src} == "${copy}" ]]; then
  ok "install-iac-guard.sh の lexer の本文は xref-guard.sh と同じ"
else
  ng "install-iac-guard.sh の lexer の本文は xref-guard.sh と同じ" "$(diff <(printf '%s\n' "${src}") <(printf '%s\n' "${copy}") | head -n 20)"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
