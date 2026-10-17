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
# 今あるファイルを書き直す (ADR 021 の B・C):
#
#   - 印の無い古いテンプレート (10 行) は欄に替わり、11 行目からはバイトで同じ。前の版は env.bak (600) に残る
#   - テンプレートが 1 文字でも違えば消さず、欄を頭に足すだけ (今の中身はバイトで同じまま欄の下に残る)
#   - 印が 1 組なら印の間だけが替わる。始まりの印より上と、終わりの印より下 (メモ・コメントアウトした値・
#     CRLF の行・末尾に改行の無い行) はバイトで同じ
#   - 印の間の # でない行は、元の順・元のバイトのまま終わりの印のすぐ下へ移り、変数名を warn で知らせる
#     (KEY=VALUE の形でない行は数だけ)
#   - 書き上がりが今と同じなら何も書かない (更新時刻も env.bak も変わらない)
#   - ファイルの頭の UTF-8 BOM があっても、古いテンプレートと印を見分け、書き直した欄の頭に BOM は付かない
#   - 空のファイルは欄だけになる
#   - 印が壊れている (始まりだけ・2 組・終わりが先)・symlink・ディレクトリに書けないときは、書かずに
#     warn で知らせて exit 0 (中身はバイトで同じ、env.bak も作らない)
#   - 中身が最新でもパーミッションが 600 でなければ 600 にする
#   - 値は out・err・警告のまとめのどれにも出さない
#   - 書き直した後にローダ (識別子で始まる KEY= の行) が読むのは、欄の外の行だけ
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

# 値を出していないかを確かめるための、テスト用の秘密の値
secret=ntn_test_secret_do_not_print
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

# 失敗の表示用に、ファイルの頭を od -c で出す (パイプの先に head を置かない)。$1: ファイル、$2: 行数
odump() {
  od -c "$1" >"$1.od" 2>&1
  head -n "$2" "$1.od"
}

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
  section "${f}" '# ---- skill: crlf ----' >"${work}/t1/crlf_section"
  ng "CRLF の断片" "$(odump "${work}/t1/crlf_section" 20)"
fi

# T5. 印に化ける断片は入れない
if grep -qF '!! ' "${work}/t1/err" && grep -qF 'bad/pjp-env.txt' "${work}/t1/err" \
  && grep -qF 'bad/pjp-env.txt' "${work}/t1/warnings" \
  && [[ $(grep -c '^# >>> dotfiles' "${f}") == 1 && $(grep -c '^# <<< dotfiles' "${f}") == 1 ]]; then
  ok "印として読まれる行を持つ断片は入れず、warn で知らせて警告のまとめにも残す"
else
  ng "印に化ける断片" "$(cat "${work}/t1/err")"$'\n'"$(cat "${work}/t1/warnings" 2>&1)"
fi

# T5b. 行の途中に制御文字がある断片は入れない。claude-skills の resolver (Python の str.splitlines) は
# CR・\v・\f・\x1c〜\x1e・U+0085・U+2028・U+2029 でも行を分けるので、欄の中に生きた変数が生まれうる
new_case t5b
s="${work}/t5b/home/.claude/skills"
mkdir -p "${s}/ctrl" "${s}/uline"
printf 'ctrl の変数。\rPJP_NOTION_TOKEN_PERSONAL=bogus\n' >"${s}/ctrl/pjp-env.txt"
printf 'uline の変数。\xe2\x80\xa8Z_INJECT=1\n' >"${s}/uline/pjp-env.txt"
run t5b
f=$(envf t5b)
if [[ $(rc t5b) == 0 ]] && grep -qF 'ctrl/pjp-env.txt' "${work}/t5b/err" \
  && grep -qF 'uline/pjp-env.txt' "${work}/t5b/err" \
  && ! grep -qF 'skill: ctrl' "${f}" && ! grep -qF 'skill: uline' "${f}" \
  && ! grep -q $'[\x01-\x08\x0b-\x1f\x7f]' "${f}" \
  && ! grep -qF -e $'\xc2\x85' -e $'\xe2\x80\xa8' -e $'\xe2\x80\xa9' "${f}"; then
  ok "行の途中に制御文字 (CR・U+2028 など) がある断片は入れず、欄に行の区切りになる文字は 1 つも無い"
else
  ng "制御文字の断片" "rc=$(rc t5b)"$'\n'"$(cat "${work}/t5b/err")"
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

# --- 今あるファイルを書き直す -----------------------------------------------

# 印の無い古いテンプレート (この ADR の前の script が置いたもの)
legacy_template() {
  cat <<'TEMPLATE'
# マシンローカルの環境変数。git にも /nix/store にも入らない。
# bash / fish の両方が起動時に読む (nix/README.md も参照)。
#
#   - 行頭から KEY=VALUE、1 行 1 個、改行は LF
#   - クォートしない。= の後ろは行末までそのまま値 (FOO='x' は 'x' になる)
#   - 展開もコマンド置換もしない ($X は文字列 "$X" のまま)
#   - 識別子で始まらない行は黙って無視される
#
# 例:
#   FOO_API_KEY=sk-xxxx
TEMPLATE
}

# ケースの env を $2 のバイト列で置き (600)、写しを <ケース>/before に取る
put() {
  local f
  f=$(envf "$1")
  mkdir -p "$(dirname "${f}")"
  printf '%s' "$2" >"${f}"
  chmod 600 "${f}"
  cp -p "${f}" "${work}/$1/before"
}

# 終わりの印 (1 つめ) の次の行から最後までを、バイトのまま出す。$1: ファイル
below_end() {
  local e
  e=$(awk 'index($0, "# <<< dotfiles") == 1 { print NR; exit }' "$1")
  tail -n +"$((e + 1))" "$1"
}

# 2 つのファイルがバイトで同じか
same() { cmp -s "$1" "$2"; }

# 値が out・err・警告のまとめに出たケースを貯める (T17 でまとめて見る)
leaks=""
check_leak() {
  local c="${work}/$1" x
  for x in out err warnings; do
    if [[ -f "${c}/${x}" ]] && grep -qF "${secret}" "${c}/${x}"; then
      leaks+=" $1/${x}"
    fi
  done
}

# ローダが読む行 (識別子で始まる KEY=) の名前を、上から順に出す。$1: ファイル
loader_names() {
  awk 'match($0, /^[A-Za-z_][A-Za-z0-9_]*=/) { print substr($0, 1, RLENGTH - 1) }' "$1"
}

# T7. 古いテンプレート
new_case t7
put t7 "$(legacy_template)"$'\n'"PJP_NOTION_TOKEN_PERSONAL=${secret}"$'\n'$'FOO=bar\r\n''# memo'
run t7
check_leak t7
f=$(envf t7)
below_end "${f}" >"${work}/t7/got_below"
tail -n +11 "${work}/t7/before" >"${work}/t7/want_below"
if [[ $(rc t7) == 0 ]] \
  && [[ $(grep -c '^# >>> dotfiles' "${f}") == 1 && $(grep -c '^# <<< dotfiles' "${f}") == 1 ]] \
  && same "${work}/t7/got_below" "${work}/t7/want_below" \
  && ! grep -qxF '# 例:' "${f}" \
  && grep -qF 'テンプレート 10 行' "${work}/t7/out" && ! grep -qF '移しました' "${work}/t7/err" \
  && same "$(dirname "${f}")/env.bak" "${work}/t7/before" \
  && [[ $(file_mode "$(dirname "${f}")/env.bak") == 600 ]]; then
  ok "古いテンプレートの 10 行は欄に替わり、11 行目からはバイトで同じ。前の版は env.bak (600)"
else
  ng "古いテンプレート" "rc=$(rc t7)"$'\n'"$(outerr t7)"$'\n'"$(odump "${work}/t7/got_below" 10)"
fi

# T8. テンプレートが 1 文字違えば消さない
new_case t8
put t8 "$(legacy_template | sed 's/^# 例:$/# 例 :/')"$'\n'"PJP_NOTION_TOKEN_PERSONAL=${secret}"$'\n'
run t8
check_leak t8
f=$(envf t8)
below_end "${f}" >"${work}/t8/got_below"
if [[ $(rc t8) == 0 ]] && same "${work}/t8/got_below" "${work}/t8/before" \
  && grep -qF '頭に足しました' "${work}/t8/out"; then
  ok "テンプレートが 1 文字でも違えば消さず、欄を頭に足すだけ"
else
  ng "違うテンプレート" "rc=$(rc t8)"$'\n'"$(outerr t8)"
fi

# T9. 印が 1 組なら印の間だけ
new_case t9
put t9 "# above"$'\n'"${begin_text}"$'\n''# old text'$'\n'"${end_text}"$'\n'"PJP_NOTION_TOKEN_PERSONAL=${secret}"$'\n''# 会社の PC 用'$'\n'"#PJP_NOTION_TOKEN_WORK=${secret}"$'\n'$'CRLF_VAR=1\r\n''LAST_VAR=2'
run t9
check_leak t9
f=$(envf t9)
below_end "${f}" >"${work}/t9/got_below"
below_end "${work}/t9/before" >"${work}/t9/want_below"
if [[ $(rc t9) == 0 ]] \
  && [[ $(head -n 1 "${f}") == '# above' && $(sed -n 2p "${f}") == "${begin_text}" ]] \
  && ! grep -qxF '# old text' "${f}" && grep -qxF '# ---- dotfiles ----' "${f}" \
  && same "${work}/t9/got_below" "${work}/t9/want_below" \
  && grep -qF '書き直しました' "${work}/t9/out" && ! grep -qF '移しました' "${work}/t9/err"; then
  ok "印が 1 組なら印の間だけが替わり、印より上と下はバイトで同じ (移す行が無ければ warn も無い)"
else
  ng "印が 1 組" "rc=$(rc t9)"$'\n'"$(outerr t9)"$'\n'"$(odump "${work}/t9/got_below" 10)"
fi

# T18 (t9). ローダが読むのは欄の外だけ
if [[ $(loader_names "${f}") == $'PJP_NOTION_TOKEN_PERSONAL\nCRLF_VAR\nLAST_VAR' ]]; then
  ok "書き直した後にローダが読むのは、欄の外の行だけ (印が 1 組)"
else
  ng "ローダが読む行 (印が 1 組)" "$(loader_names "${f}")"
fi

# T11. 2 回目は書かない
touch -d '2000-01-01 00:00:00' "${f}" "${work}/t9/ref"
cp -p "$(dirname "${f}")/env.bak" "${work}/t9/bak1"
run t9
check_leak t9
if [[ $(rc t9) == 0 ]] && grep -qF '最新' "${work}/t9/out" \
  && [[ $(stat -c '%Y' "${f}") == $(stat -c '%Y' "${work}/t9/ref") ]] \
  && same "$(dirname "${f}")/env.bak" "${work}/t9/bak1"; then
  ok "書き上がりが今と同じなら何も書かない (更新時刻も env.bak も変わらない)"
else
  ng "2 回目" "rc=$(rc t9)"$'\n'"$(outerr t9)"
fi

# T16. 中身が最新でもパーミッションは締める
chmod 644 "${f}"
cp -p "${f}" "${work}/t9/before2"
run t9
check_leak t9
if [[ $(rc t9) == 0 && $(file_mode "${f}") == 600 ]] && same "${f}" "${work}/t9/before2" \
  && grep -qF '最新' "${work}/t9/out"; then
  ok "中身が最新でも、パーミッションが 600 でなければ 600 にする"
else
  ng "パーミッション" "rc=$(rc t9) mode=$(file_mode "${f}")"$'\n'"$(outerr t9)"
fi

# T10. 欄の中の値を救う
new_case t10
put t10 "${begin_text}"$'\n'"FOO_API_KEY=${secret}"$'\n''# old'$'\n''export BAR=1'$'\n'"${end_text}"$'\n''MINE=1'$'\n'
run t10
check_leak t10
f=$(envf t10)
below_end "${f}" >"${work}/t10/got_below"
printf '%s\n' "FOO_API_KEY=${secret}" 'export BAR=1' 'MINE=1' >"${work}/t10/want_below"
if [[ $(rc t10) == 0 ]] && same "${work}/t10/got_below" "${work}/t10/want_below" \
  && grep -qF 'FOO_API_KEY' "${work}/t10/err" && grep -qF 'KEY=VALUE の形でない行 1 行' "${work}/t10/err" \
  && grep -qF 'FOO_API_KEY' "${work}/t10/warnings"; then
  ok "印の間の # でない行は、元の順のまま終わりの印のすぐ下へ移り、変数名を warn で知らせる"
else
  ng "欄の中の値" "rc=$(rc t10)"$'\n'"$(outerr t10)"$'\n'"$(odump "${work}/t10/got_below" 10)"
fi

# T18 (t10)
if [[ $(loader_names "${f}") == $'FOO_API_KEY\nMINE' ]]; then
  ok "書き直した後にローダが読むのは、欄の外の行だけ (欄の中から移した行を含む)"
else
  ng "ローダが読む行 (欄の中から移した)" "$(loader_names "${f}")"
fi

# T12. 頭の BOM
bom=$'\xef\xbb\xbf'
new_case t12a
put t12a "${bom}$(legacy_template)"$'\n''V=1'$'\n'
run t12a
f=$(envf t12a)
below_end "${f}" >"${work}/t12a/got_below"
printf 'V=1\n' >"${work}/t12a/want_below"
if [[ $(rc t12a) == 0 && $(head -n 1 "${f}") == "${begin_text}" ]] \
  && grep -qF 'テンプレート 10 行' "${work}/t12a/out" \
  && same "${work}/t12a/got_below" "${work}/t12a/want_below"; then
  ok "頭に BOM があっても古いテンプレートとして見分け、欄の頭に BOM は付かない"
else
  head -n 1 "${f}" >"${work}/t12a/first_line"
  ng "BOM と古いテンプレート" "rc=$(rc t12a)"$'\n'"$(outerr t12a)"$'\n'"$(odump "${work}/t12a/first_line" 3)"
fi
new_case t12b
put t12b "${bom}${begin_text}"$'\n''# old'$'\n'"${end_text}"$'\n''V=1'$'\n'
run t12b
f=$(envf t12b)
below_end "${f}" >"${work}/t12b/got_below"
if [[ $(rc t12b) == 0 && $(head -n 1 "${f}") == "${begin_text}" ]] \
  && grep -qF '書き直しました' "${work}/t12b/out" \
  && same "${work}/t12b/got_below" "${work}/t12a/want_below"; then
  ok "頭に BOM があっても印を見分け、欄の頭に BOM は付かない"
else
  ng "BOM と印" "rc=$(rc t12b)"$'\n'"$(outerr t12b)"
fi

# T13. 空のファイル
new_case t13
put t13 ''
run t13
f=$(envf t13)
if [[ $(rc t13) == 0 && $(head -n 1 "${f}") == "${begin_text}" && $(tail -n 1 "${f}") == "${end_text}" ]] \
  && grep -qF '0 行' "${work}/t13/out"; then
  ok "空のファイルは欄だけになる"
else
  ng "空のファイル" "rc=$(rc t13)"$'\n'"$(outerr t13)"
fi

# T14. 印が壊れている
broken_ok=1
broken_msg=""
for k in a b c; do
  new_case "t14${k}"
  case ${k} in
    a) put t14a "${begin_text}"$'\n'"V=${secret}"$'\n' ;;
    b) put t14b "${begin_text}"$'\n'"${end_text}"$'\n'"V=${secret}"$'\n'"${begin_text}"$'\n'"${end_text}"$'\n' ;;
    c) put t14c "${end_text}"$'\n'"V=${secret}"$'\n'"${begin_text}"$'\n' ;;
  esac
  run "t14${k}"
  check_leak "t14${k}"
  f=$(envf "t14${k}")
  if ! { [[ $(rc "t14${k}") == 0 ]] && same "${f}" "${work}/t14${k}/before" \
    && grep -qF '書き換えません' "${work}/t14${k}/err" && grep -qE '[0-9]' "${work}/t14${k}/err" \
    && [[ ! -e "$(dirname "${f}")/env.bak" ]]; }; then
    broken_ok=0
    broken_msg+="t14${k}: rc=$(rc "t14${k}") $(outerr "t14${k}")"$'\n'
  fi
done
if [[ ${broken_ok} == 1 ]]; then
  ok "印が壊れている (始まりだけ・2 組・終わりが先) なら、書かずに行番号を warn で知らせる"
else
  ng "印が壊れている" "${broken_msg}"
fi

# T15. symlink と書けないディレクトリ
new_case t15a
mkdir -p "${work}/t15a/home/.config/pjp"
printf 'V=%s\n' "${secret}" >"${work}/t15a/target"
cp -p "${work}/t15a/target" "${work}/t15a/before"
ln -s "${work}/t15a/target" "$(envf t15a)"
run t15a
check_leak t15a
if [[ $(rc t15a) == 0 && -L "$(envf t15a)" ]] && same "${work}/t15a/target" "${work}/t15a/before" \
  && grep -qF 'symlink' "${work}/t15a/err"; then
  ok "env が symlink なら、書かずに warn で知らせる"
else
  ng "symlink" "rc=$(rc t15a)"$'\n'"$(outerr t15a)"
fi
if [[ $(id -u) != 0 ]]; then
  new_case t15b
  put t15b "V=${secret}"$'\n'
  chmod 555 "$(dirname "$(envf t15b)")"
  run t15b
  check_leak t15b
  chmod 755 "$(dirname "$(envf t15b)")"
  if [[ $(rc t15b) == 0 ]] && same "$(envf t15b)" "${work}/t15b/before" \
    && grep -qF '!! ' "${work}/t15b/err"; then
    ok "ディレクトリに書けなければ、書かずに warn で知らせて exit 0"
  else
    ng "書けないディレクトリ" "rc=$(rc t15b)"$'\n'"$(outerr t15b)"
  fi
fi

# T17. 値を出さない
if [[ -z ${leaks} ]]; then
  ok "値は out・err・警告のまとめのどれにも出さない"
else
  ng "値が出た" "${leaks}"
fi

echo
echo "${pass} ok / ${fail} failed"
[[ ${fail} == 0 ]]
