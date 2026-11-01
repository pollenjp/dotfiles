#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-path-shadow.sh が、PATH で Nix の ntn より先に来る、Nix のものでない ntn を警告するところを、
# 使い捨ての HOME と偽の store で確かめる。
#
#   bash nix/tests/bootstrap-path-shadow.test.sh [<bootstrap-path-shadow.sh のパス>]
#
# flake の checks (bootstrap-path-shadow-test) が Nix のサンドボックスで流す。使うのは bash と coreutils・grep・awk だけ。
#
# ## 確かめること
#
#   - PATH に ntn が無ければ、警告せずに 0 で終わる (setup の最後のまとめにも載せない)
#   - Nix の ntn (実体が store の下) だけなら、警告せずに 0 で終わる
#   - Nix のものでない ntn (~/bin のふつうのファイル) が Nix の ntn より先にあれば、その path・Nix の ntn の path・
#     消すコマンド (rm) を 1 件の警告で stderr とまとめに出し、0 で終わる。ファイルは消さない
#   - Nix の ntn が先なら、後ろに Nix のものでない ntn があっても警告しない
#   - Nix のものでない ntn が 2 つ先にあれば (~/.local/bin と ~/bin)、1 件の警告に PATH の順で両方を並べ、rm の 1 行で
#     両方を消す
#   - PATH の要素が store の bin を指す symlink のディレクトリで、ntn がその中のふつうのファイルなら、Nix のものとみなす
#   - Nix の profile と同じ形 (~/.nix-profile から相対パスの symlink を何段か経て store に入る) の ntn も、Nix のものとみなす
#   - store の下でも実体の名前が ntn でないもの (Nix で入れた mise の shim: shims/ntn → store の bin/mise) は、Nix の ntn と
#     読まずに警告し、その後ろの Nix のものでない ntn も見落とさない
#   - 実行の bit の無いファイル・ntn という名前のディレクトリ・壊れた symlink は数えない (シェルが選ばないもの)
#   - store の外を指す symlink の ntn (npm の shim など。相対パスのリンクも) は警告し、rm にはリンクの path を出す
#   - PATH に同じディレクトリが 2 回 (末尾の / 違いも、symlink で別の名前になっているものも) あっても、1 度だけ出す
#   - PATH の空の要素と相対パスの要素は見ない (cwd に ntn があっても警告しない)
#   - Nix の ntn が PATH に無く、Nix のものでない ntn だけがあれば、別の見出しで警告し、Nix の ntn が PATH にあることを
#     確かめてから消すよう出す (消せば Nix の ntn が使われる、とは言わない)
#   - 空白を含むディレクトリの ntn でも、rm の行はそのまま貼って打てる形 (printf %q) で出す
#   - store の場所が symlink の下にあっても (macOS の /tmp のように)、実体で比べて Nix のものとみなす
#   - setup の外で単体で流しても (DOTFILES_SETUP_WARNINGS が無い)、警告を stderr に出して 0 で終わる
#   - 引数を渡すと、何も見ずに終了コード 2 で終わる
#
# 偽の store は <作業場所>/store で、BOOTSTRAP_PATH_SHADOW_STORE で script に渡す。Nix の ntn は、その下の
# <hash>-ntn-0.23.25/bin/ntn への symlink を、Nix の profile のように <HOME>/.nix-profile/bin に張る。script には env -i で
# HOME・PATH・BOOTSTRAP_PATH_SHADOW_STORE・DOTFILES_SETUP_WARNINGS だけを渡し、cwd は HOME にする。PATH の末尾には、
# script が使う readlink だけを置いたディレクトリを足す。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-path-shadow.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-path-shadow-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT
# 実体のパスにしておく (script は実体のパスで比べ、出す path は PATH の要素のまま)
work=$(cd -P -- "${work}" && pwd -P)

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

store="${work}/store"
# script に渡す store (ケースで差し替える)
run_store=${store}
# script が PATH から使う道具 (readlink だけ)
tools="${work}/tools"
mkdir -p "${tools}"
ln -s "$(command -v readlink)" "${tools}/readlink"

# $1 のパスに、実行できる偽の ntn を置く (shebang は $BASH。サンドボックスに /usr/bin/env は無い)
fake_ntn() {
  mkdir -p "$(dirname "$1")"
  printf '#!%s\necho fake-ntn\n' "${BASH}" >"$1"
  chmod +x "$1"
}

# 偽の store に Nix の ntn を置き、$1 (HOME) の .nix-profile/bin/ntn からそれへ symlink を張る
nix_profile_ntn() {
  local target="${store}/0000-ntn-0.23.25/bin/ntn"
  [[ -e ${target} ]] || fake_ntn "${target}"
  mkdir -p "$1/.nix-profile/bin"
  ln -s "${target}" "$1/.nix-profile/bin/ntn"
}

# $1: HOME、$2: PATH (末尾に道具のディレクトリを足す)、残り: script の引数。setup から走るときと同じく、まとめ用の
# ファイル (空) を DOTFILES_SETUP_WARNINGS で渡して流す。stdout・stderr・終了コード・まとめを
# <HOME>/{stdout,stderr,rc,warnings} に残す
run() {
  local h=$1 p=$2
  shift 2
  mkdir -p "${h}"
  : >"${h}/warnings"
  (cd "${h}" && env -i HOME="${h}" PATH="${p}:${tools}" BOOTSTRAP_PATH_SHADOW_STORE="${run_store}" \
    DOTFILES_SETUP_WARNINGS="${h}/warnings" "${BASH}" "${script}" "$@" >"${h}/stdout" 2>"${h}/stderr")
  echo $? >"${h}/rc"
}

# run と同じだが、DOTFILES_SETUP_WARNINGS を渡さない (setup の外で単体で流したとき)
run_alone() {
  local h=$1 p=$2
  mkdir -p "${h}"
  : >"${h}/warnings"
  (cd "${h}" && env -i HOME="${h}" PATH="${p}:${tools}" BOOTSTRAP_PATH_SHADOW_STORE="${run_store}" \
    "${BASH}" "${script}" >"${h}/stdout" 2>"${h}/stderr")
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
detail() {
  printf 'rc=%s\nstdout=%s\nstderr=%s\nwarnings=%s' "$(cat "$1/rc")" "$(cat "$1/stdout")" \
    "$(cat "$1/stderr")" "$(cat "$1/warnings")"
}
# 0 で終わり、警告を出さず、まとめにも載せなかった
quiet() {
  [[ $(rc "$1") == 0 && ! -s $1/stderr && ! -s $1/warnings ]]
}
# 警告の見出しの頭 (Nix の ntn が PATH にあるとき・無いとき)
head_shadow='PATH で、Nix の ntn より先に'
head_no_nix='PATH に Nix のものでない ntn があり、Nix の ntn は PATH にありません'
# 0 で終わり、1 件の警告 (見出しは $2 で始まる。既定は head_shadow) を stderr とまとめに出した
warned_once() {
  local want=${2:-${head_shadow}}
  [[ $(rc "$1") == 0 ]] || return 1
  [[ $(grep -c '^!! ' "$1/stderr") == 1 ]] || return 1
  [[ $(head -n 1 "$1/stderr") == "!! ${want}"* ]] || return 1
  # まとめは字下げの無い行が 1 件の見出し
  [[ $(grep -c '^[^[:space:]]' "$1/warnings") == 1 ]] || return 1
  [[ $(head -n 1 "$1/warnings") == "${want}"* ]]
}
# $1 のファイルに、$2 とちょうど同じ行がある
has_line() { grep -qxF -- "$2" "$1"; }
# $1 のファイルで、$2 の行が $3 の行より前にある (どちらもちょうど同じ行)
before() {
  awk -v a="$2" -v b="$3" '$0 == a && !ia { ia = NR } $0 == b && !ib { ib = NR } END { exit !(ia && ib && ia < ib) }' "$1"
}
# シェルにそのまま貼れる形 (script と同じ printf %q)
q() { printf '%q' "$1"; }

echo "== bootstrap-path-shadow.sh: ${script}"

# 1. PATH に ntn が無い
h="${work}/t1"
mkdir -p "${h}/bin"
run "${h}" "${h}/bin"
if quiet "${h}"; then
  ok "PATH に ntn が無ければ、警告せずに 0 で終わる"
else
  ng "PATH に ntn が無い" "$(detail "${h}")"
fi

# 2. Nix の ntn だけ
h="${work}/t2"
nix_profile_ntn "${h}"
run "${h}" "${h}/.nix-profile/bin"
if quiet "${h}"; then
  ok "Nix の ntn だけなら、警告せずに 0 で終わる"
else
  ng "Nix の ntn だけ" "$(detail "${h}")"
fi

# 3. ~/bin のふつうのファイルが Nix の ntn より先
h="${work}/t3"
fake_ntn "${h}/bin/ntn"
nix_profile_ntn "${h}"
run "${h}" "${h}/bin:${h}/.nix-profile/bin"
if warned_once "${h}" \
  && has_line "${h}/stderr" "   先に来るもの: ${h}/bin/ntn" \
  && has_line "${h}/stderr" "   Nix の ntn:   ${h}/.nix-profile/bin/ntn" \
  && has_line "${h}/stderr" "     rm $(q "${h}/bin/ntn")" \
  && has_line "${h}/warnings" "   先に来るもの: ${h}/bin/ntn" \
  && has_line "${h}/warnings" "     rm $(q "${h}/bin/ntn")" \
  && [[ -f ${h}/bin/ntn ]]; then
  ok "Nix のものでない ntn が先にあれば、その path・Nix の ntn・rm を 1 件の警告で出し、0 で終わる (消さない)"
else
  ng "HOME の bin の ntn が先" "$(detail "${h}")"
fi

# 4. Nix の ntn が先で、Nix のものでない ntn が後
h="${work}/t4"
fake_ntn "${h}/bin/ntn"
nix_profile_ntn "${h}"
run "${h}" "${h}/.nix-profile/bin:${h}/bin"
if quiet "${h}"; then
  ok "Nix の ntn が先なら、後ろに Nix のものでない ntn があっても警告しない"
else
  ng "Nix の ntn が先" "$(detail "${h}")"
fi

# 5. Nix のものでない ntn が 2 つ先にある
h="${work}/t5"
fake_ntn "${h}/.local/bin/ntn"
fake_ntn "${h}/bin/ntn"
nix_profile_ntn "${h}"
run "${h}" "${h}/.local/bin:${h}/bin:${h}/.nix-profile/bin"
if warned_once "${h}" \
  && before "${h}/stderr" "   先に来るもの: ${h}/.local/bin/ntn" "   先に来るもの: ${h}/bin/ntn" \
  && has_line "${h}/stderr" "     rm $(q "${h}/.local/bin/ntn") $(q "${h}/bin/ntn")"; then
  ok "Nix のものでない ntn が 2 つ先にあれば、1 件の警告に PATH の順で並べ、rm の 1 行で両方を消す"
else
  ng "2 つ先にある" "$(detail "${h}")"
fi

# 6. PATH の要素が store の bin を指す symlink のディレクトリ
h="${work}/t6"
fake_ntn "${store}/1111-home-manager-path/bin/ntn"
mkdir -p "${h}"
ln -s "${store}/1111-home-manager-path/bin" "${h}/per-user-bin"
run "${h}" "${h}/per-user-bin"
if quiet "${h}"; then
  ok "PATH の要素が store の bin を指す symlink のディレクトリなら、その中の ntn は Nix のもの"
else
  ng "store を指すディレクトリ" "$(detail "${h}")"
fi

# 6a. Nix の profile と同じ形: ~/.nix-profile → profiles/profile → (相対) profile-1-link → store の環境 → store の ntn
h="${work}/t6a"
fake_ntn "${store}/0000-ntn-0.23.25/bin/ntn"
mkdir -p "${store}/2222-user-environment/bin" "${h}/.local/state/nix/profiles"
ln -s "${store}/0000-ntn-0.23.25/bin/ntn" "${store}/2222-user-environment/bin/ntn"
ln -s "${store}/2222-user-environment" "${h}/.local/state/nix/profiles/profile-1-link"
ln -s profile-1-link "${h}/.local/state/nix/profiles/profile"
ln -s "${h}/.local/state/nix/profiles/profile" "${h}/.nix-profile"
run "${h}" "${h}/.nix-profile/bin"
if quiet "${h}"; then
  ok "Nix の profile と同じ形 (相対パスの symlink を何段か経て store に入る) の ntn も Nix のもの"
else
  ng "profile と同じ形" "$(detail "${h}")"
fi

# 6b. Nix で入れた mise の shim (shims/ntn → store の bin/mise) と ~/bin の ntn が Nix の ntn より先
h="${work}/t6b"
fake_ntn "${store}/3333-mise-2026.10.17/bin/mise"
mkdir -p "${h}/shims"
ln -s "${store}/3333-mise-2026.10.17/bin/mise" "${h}/shims/ntn"
fake_ntn "${h}/bin/ntn"
nix_profile_ntn "${h}"
run "${h}" "${h}/shims:${h}/bin:${h}/.nix-profile/bin"
if warned_once "${h}" \
  && before "${h}/stderr" "   先に来るもの: ${h}/shims/ntn" "   先に来るもの: ${h}/bin/ntn" \
  && has_line "${h}/stderr" "   Nix の ntn:   ${h}/.nix-profile/bin/ntn"; then
  ok "store の下でも実体の名前が ntn でないもの (mise の shim) は Nix の ntn と読まず、後ろの ntn も見落とさない"
else
  ng "mise の shim" "$(detail "${h}")"
fi

# 7. 実行の bit の無いファイル・ntn という名前のディレクトリ・壊れた symlink
h="${work}/t7"
mkdir -p "${h}/a" "${h}/b/ntn" "${h}/c"
printf 'echo not-executable\n' >"${h}/a/ntn"
ln -s "${h}/missing/ntn" "${h}/c/ntn"
run "${h}" "${h}/a:${h}/b:${h}/c"
if quiet "${h}"; then
  ok "実行の bit の無いファイル・ntn という名前のディレクトリ・壊れた symlink は数えない"
else
  ng "シェルが選ばないもの" "$(detail "${h}")"
fi

# 8. store の外を指す symlink (npm の shim のような、相対パスのリンク)
h="${work}/t8"
fake_ntn "${h}/node/lib/node_modules/ntn/bin/ntn.js"
mkdir -p "${h}/node/bin"
ln -s ../lib/node_modules/ntn/bin/ntn.js "${h}/node/bin/ntn"
nix_profile_ntn "${h}"
run "${h}" "${h}/node/bin:${h}/.nix-profile/bin"
if warned_once "${h}" \
  && has_line "${h}/stderr" "   先に来るもの: ${h}/node/bin/ntn" \
  && has_line "${h}/stderr" "     rm $(q "${h}/node/bin/ntn")"; then
  ok "store の外を指す symlink の ntn は警告し、rm にはリンクの path を出す"
else
  ng "store の外を指す symlink" "$(detail "${h}")"
fi

# 9. 同じディレクトリが 2 回 (末尾の / 違いも)
h="${work}/t9"
fake_ntn "${h}/bin/ntn"
nix_profile_ntn "${h}"
run "${h}" "${h}/bin:${h}/bin/:${h}/.nix-profile/bin"
if warned_once "${h}" \
  && [[ $(grep -c '先に来るもの:' "${h}/stderr") == 1 ]] \
  && has_line "${h}/stderr" "     rm $(q "${h}/bin/ntn")"; then
  ok "PATH に同じディレクトリが 2 回あっても、1 度だけ出す"
else
  ng "同じディレクトリが 2 回" "$(detail "${h}")"
fi

# 9a. symlink で別の名前になっている同じディレクトリ (/bin → /usr/bin のような)
h="${work}/t9a"
fake_ntn "${h}/usr/bin/ntn"
ln -s usr/bin "${h}/bin-link"
nix_profile_ntn "${h}"
run "${h}" "${h}/usr/bin:${h}/bin-link:${h}/.nix-profile/bin"
if warned_once "${h}" \
  && [[ $(grep -c '先に来るもの:' "${h}/stderr") == 1 ]] \
  && has_line "${h}/stderr" "     rm $(q "${h}/usr/bin/ntn")"; then
  ok "symlink で別の名前になっている同じディレクトリも、1 度だけ出す"
else
  ng "symlink で別の名前の同じディレクトリ" "$(detail "${h}")"
fi

# 10. 空の要素と相対パスの要素 (cwd は HOME。そこに bin/ntn と ntn を置く)
h="${work}/t10"
fake_ntn "${h}/bin/ntn"
fake_ntn "${h}/ntn"
nix_profile_ntn "${h}"
run "${h}" "::.:bin:${h}/.nix-profile/bin"
if quiet "${h}"; then
  ok "PATH の空の要素と相対パスの要素は見ない"
else
  ng "空の要素と相対パス" "$(detail "${h}")"
fi

# 11. Nix の ntn が PATH に無く、Nix のものでない ntn だけ
h="${work}/t11"
fake_ntn "${h}/bin/ntn"
run "${h}" "${h}/bin"
if warned_once "${h}" "${head_no_nix}" \
  && has_line "${h}/stderr" "   Nix のものでない ntn: ${h}/bin/ntn" \
  && has_line "${h}/stderr" "     rm $(q "${h}/bin/ntn")" \
  && grep -qF 'type -a ntn' "${h}/stderr" \
  && ! grep -qF '新しいシェルから Nix の ntn が使われる' "${h}/stderr"; then
  ok "Nix の ntn が PATH に無ければ、別の見出しで警告し、Nix の ntn が PATH にあることを確かめてから消すよう出す"
else
  ng "Nix の ntn が PATH に無い" "$(detail "${h}")"
fi

# 12. 空白を含むディレクトリ
h="${work}/t12"
fake_ntn "${h}/my bin/ntn"
nix_profile_ntn "${h}"
run "${h}" "${h}/my bin:${h}/.nix-profile/bin"
if warned_once "${h}" \
  && has_line "${h}/stderr" "   先に来るもの: ${h}/my bin/ntn" \
  && has_line "${h}/stderr" "     rm $(q "${h}/my bin/ntn")"; then
  ok "空白を含むディレクトリの ntn でも、rm の行はそのまま貼って打てる形で出す"
else
  ng "空白を含むディレクトリ" "$(detail "${h}")"
fi

# 13. store の場所が symlink の下にある
h="${work}/t13"
nix_profile_ntn "${h}"
ln -s "${store}" "${work}/store-link"
run_store="${work}/store-link"
run "${h}" "${h}/.nix-profile/bin"
run_store=${store}
if quiet "${h}"; then
  ok "store の場所が symlink の下にあっても、実体で比べて Nix のものとみなす"
else
  ng "store の場所が symlink の下" "$(detail "${h}")"
fi

# 14. setup の外で単体で流す
h="${work}/t14"
fake_ntn "${h}/bin/ntn"
nix_profile_ntn "${h}"
run_alone "${h}" "${h}/bin:${h}/.nix-profile/bin"
if [[ $(rc "${h}") == 0 && ! -s ${h}/warnings ]] \
  && [[ $(head -n 1 "${h}/stderr") == '!! PATH で、Nix の ntn より先に'* ]]; then
  ok "setup の外で単体で流しても、警告を stderr に出して 0 で終わる"
else
  ng "単体で流す" "$(detail "${h}")"
fi

# 15. 引数を渡す
h="${work}/t15"
fake_ntn "${h}/bin/ntn"
run "${h}" "${h}/bin" --check
if [[ $(rc "${h}") == 2 && ! -s ${h}/warnings ]] && ! grep -q '^!! ' "${h}/stderr"; then
  ok "引数を渡すと、何も見ずに終了コード 2 で終わる"
else
  ng "引数を渡す" "$(detail "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
