#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-local-env.sh の振る舞いを、使い捨ての HOME と偽の checkout で確かめる。
#
#   bash nix/tests/bootstrap-local-env.test.sh [<script のパス>] [<dotfiles.txt のパス>]
#
# flake の checks (bootstrap-local-env-test) が Nix のサンドボックスで流す。
# 使うのは bash・coreutils・awk・grep・cmp だけ。
#
# ## 確かめること
#
# 欄を組む (ADR 021 の A・E):
#
#   - ファイルが無ければ、欄だけのファイルを 600 で作る。1 行目と最後の行は印で、すべての行が # で始まり、
#     ローダが読む形 (識別子で始まる KEY=) の行は 1 つも無い
#   - 節は dotfiles が先、skill は ~/.claude/skills/ のディレクトリ名の順。pjp-env.txt の無い skill・空の
#     断片・切れた symlink は節を作らず、切れた symlink では何も言わない
#   - 断片の各行に「# 」を付ける (空行は「#」、先頭と末尾の空行は落とす)。FOO=bar と書いても欄では # FOO=bar
#   - CRLF の断片でも欄の行に CR は混ざらず、末尾に改行の無い最後の行も落ちない
#   - 印として読まれてしまう行 (>>> dotfiles / <<< dotfiles で始まる) を持つ断片は入れず、warn で知らせる
#     (setup の最後の警告のまとめにも残す)
#   - repo の dotfiles.txt (第 2 引数) は、警告なしに欄に入る
#
# ## 偽の checkout
#
# script は自分のいる checkout の nix/files/pjp-env/dotfiles.txt を読むので、ケースごとに
# <ケース>/repo/nix/scripts/ へ写して流す。HOME は <ケース>/home、XDG_CONFIG_HOME は <ケース>/home/.config。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-local-env.sh}
real_fragment=${2:-}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-local-env-test.XXXXXX")
trap 'chmod -R u+w "${work}" 2>/dev/null; rm -rf "${work}"' EXIT

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

begin_text='# >>> dotfiles が書く欄 (setup --update のたびに書き直す。ここには書かない) >>>'
end_text='# <<< dotfiles が書く欄ここまで。この行より下に生の KEY=VALUE を書く (setup はここから下を書き換えない) <<<'

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# 1 ケースぶんを作る。$1: 名前
new_case() {
  local c="${work}/$1" s
  s="${c}/home/.claude/skills"
  mkdir -p "${c}/repo/nix/scripts" "${c}/repo/nix/files/pjp-env" "${s}" "${c}/clone/skills/linked"
  cp "${script}" "${c}/repo/nix/scripts/bootstrap-local-env.sh"
  printf '%s\n' \
    'テスト用の 1 つめの変数。取り得る値: 何でも。' \
    'TEST_DOTFILES_ONE=xxxxxx' \
    '' \
    'テスト用の 2 つめの変数。取り得る値: 0, 1。' \
    'TEST_DOTFILES_TWO=1' >"${c}/repo/nix/files/pjp-env/dotfiles.txt"
  mkdir -p "${s}/alpha" "${s}/zeta" "${s}/empty" "${s}/noenv" "${s}/bad" "${s}/crlf"
  printf '%s\n' 'alpha が読む変数。取り得る値: パス。' 'ALPHA_PATH=xxxxxx' >"${s}/alpha/pjp-env.txt"
  printf '%s\n' '' '' 'zeta が読む変数。取り得る値: 何でも。' 'FOO=bar' '' 'zeta の 2 つめ。' 'ZETA_TWO=xxxxxx' '' \
    >"${s}/zeta/pjp-env.txt"
  printf '\n  \n\n' >"${s}/empty/pjp-env.txt"
  printf '%s\n' 'bad の変数。' '<<< dotfiles を足す' 'BAD=xxxxxx' >"${s}/bad/pjp-env.txt"
  printf 'crlf の変数。\r\nCRLF_LAST=xxxxxx' >"${s}/crlf/pjp-env.txt"
  printf '%s\n' 'linked が読む変数。' 'LINKED=xxxxxx' >"${c}/clone/skills/linked/pjp-env.txt"
  ln -s "${c}/clone/skills/linked" "${s}/linked"
  ln -s "${c}/no-such-dir" "${s}/broken"
}

# script を流し、out・err・rc をケースの dir に落とす。$1: 名前
run() {
  local c="${work}/$1"
  env HOME="${c}/home" XDG_CONFIG_HOME="${c}/home/.config" DOTFILES_SETUP_WARNINGS="${c}/warnings" \
    "${BASH}" "${c}/repo/nix/scripts/bootstrap-local-env.sh" >"${c}/out" 2>"${c}/err"
  echo $? >"${c}/rc"
}

envf() { printf '%s' "${work}/$1/home/.config/pjp/env"; }
rc() { cat "${work}/$1/rc"; }
outerr() { cat "${work}/$1/out" "${work}/$1/err"; }

# 欄の中の 1 節 (見出しの行から、次の見出しか ##### の行の手前まで) を出す。$1: ファイル、$2: 見出しの行
section() {
  awk -v h="$2" '
    $0 == h { on = 1; print; next }
    on && (/^# ---- / || /^#####/) { exit }
    on { print }
  ' "$1"
}

echo "== bootstrap-local-env.sh: ${script}"

# --- 欄を組む ---------------------------------------------------------------

# T1. 無ければ作る
new_case t1
run t1
f=$(envf t1)
if [[ $(rc t1) == 0 && -f ${f} ]] \
  && [[ $(file_mode "${f}") == 600 ]] \
  && [[ $(head -n 1 "${f}") == "${begin_text}" && $(tail -n 1 "${f}") == "${end_text}" ]] \
  && ! grep -qv '^#' "${f}" \
  && ! grep -qE '^[A-Za-z_][A-Za-z0-9_]*=' "${f}" \
  && grep -qF '作りました' "${work}/t1/out" \
  && [[ ! -e "$(dirname "${f}")/env.bak" ]]; then
  ok "無ければ、印で始まって印で終わる、# だけの欄を 600 で作る"
else
  ng "無ければ作る" "rc=$(rc t1) mode=$(file_mode "${f}" 2>&1)"$'\n'"$(outerr t1)"$'\n'"$(cat "${f}" 2>&1)"
fi

# T2. 節の並び
grep '^# ---- ' "${f}" >"${work}/t1/headings"
want_headings=$'# ---- dotfiles ----\n# ---- skill: alpha ----\n# ---- skill: crlf ----\n# ---- skill: linked ----\n# ---- skill: zeta ----'
if [[ $(cat "${work}/t1/headings") == "${want_headings}" ]] && ! grep -qF 'broken' "${work}/t1/err"; then
  ok "節は dotfiles が先、skill は名前の順。空・pjp-env.txt 無し・切れた symlink は節を作らない"
else
  ng "節の並び" "$(cat "${work}/t1/headings")"$'\n'"$(cat "${work}/t1/err")"
fi

# T3. 断片から生きた変数は生まれない。空行は #、先頭と末尾の空行は落とす
want_zeta=$'# ---- skill: zeta ----\n#\n# zeta が読む変数。取り得る値: 何でも。\n# FOO=bar\n#\n# zeta の 2 つめ。\n# ZETA_TWO=xxxxxx\n#'
got_zeta=$(section "${f}" '# ---- skill: zeta ----')
if [[ ${got_zeta} == "${want_zeta}" ]]; then
  ok "断片の FOO=bar は # FOO=bar になり、空行は #、先頭と末尾の空行は落ちる"
else
  ng "断片の行の付け方" "${got_zeta}"
fi

# T4. CRLF と末尾に改行の無い断片
if ! grep -q $'\r' "${f}" && grep -qxF '# CRLF_LAST=xxxxxx' "${f}"; then
  ok "CRLF の断片でも欄に CR は混ざらず、末尾に改行の無い最後の行も落ちない"
else
  ng "CRLF の断片" "$(section "${f}" '# ---- skill: crlf ----' | od -c | head -n 20)"
fi

# T5. 印に化ける断片は入れない
if grep -qF '!! ' "${work}/t1/err" && grep -qF 'bad/pjp-env.txt' "${work}/t1/err" \
  && grep -qF 'bad/pjp-env.txt' "${work}/t1/warnings" \
  && [[ $(grep -c '^# >>> dotfiles' "${f}") == 1 && $(grep -c '^# <<< dotfiles' "${f}") == 1 ]]; then
  ok "印として読まれる行を持つ断片は入れず、warn で知らせて警告のまとめにも残す"
else
  ng "印に化ける断片" "$(cat "${work}/t1/err")"$'\n'"$(cat "${work}/t1/warnings" 2>&1)"
fi

# T6. 本物の dotfiles.txt
if [[ -n ${real_fragment} ]]; then
  new_case t6
  cp "${real_fragment}" "${work}/t6/repo/nix/files/pjp-env/dotfiles.txt"
  rm -rf "${work}/t6/home/.claude/skills/bad"
  run t6
  f=$(envf t6)
  missing=""
  while IFS= read -r line || [[ -n ${line} ]]; do
    line=${line%$'\r'}
    [[ ${line} =~ ^[[:space:]]*$ ]] && continue
    grep -qxF -- "# ${line}" "${f}" || missing+="${line}"$'\n'
  done <"${real_fragment}"
  if [[ $(rc t6) == 0 && ! -s "${work}/t6/err" && -z ${missing} ]]; then
    ok "repo の dotfiles.txt は、警告なしに 1 行ずつ欄に入る"
  else
    ng "repo の dotfiles.txt" "rc=$(rc t6) missing=${missing}"$'\n'"$(cat "${work}/t6/err")"
  fi
fi

echo
echo "${pass} ok / ${fail} failed"
[[ ${fail} == 0 ]]
