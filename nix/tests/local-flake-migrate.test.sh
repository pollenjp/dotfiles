#!/usr/bin/env bash
# shellcheck shell=bash
# 雛形の原文 (展開する前の ${nix_dir} など) を文字のまま書く所が多いので、ファイル全体で SC2016 を止める
# shellcheck disable=SC2016
#
# nix/scripts/local-flake-migrate.sh (旧いローカル flake を、値を引き継いで今の雛形へ移す) を、使い捨ての
# repo と偽の nix で確かめる。
#
#   bash nix/tests/local-flake-migrate.test.sh [<nix/scripts のパス>]
#
# flake の checks (local-flake-migrate-test) が Nix のサンドボックスで流す。
#
# ## 確かめること
#
#   - render は雛形の原文の ${nix_dir}・${template_id}・\$・\`・\\ を bash の heredoc と同じに描き、ほかの展開
#     ($NAME・${...}・$(...)・$[...]・`...`・特殊なパラメータ・行末の \) があれば描かずに 1 で終わる
#   - id は heredoc の原文から 8 桁の 16 進を出す。heredoc の中を変えると変わり、外を変えても変わらない。
#     開きの行 (`  cat >"${flake_file}" <<EOS`) が 1 つでない・閉じの EOS が無い script は、id も render も 1
#   - render --rev は、repo の履歴の setup-local-flake.sh の版を描く (古い版の script を実行しない)

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
dir=${1:-${here}/../scripts}
src=${dir}/local-flake-migrate.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/local-flake-migrate-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

if [[ ! -f ${src} ]]; then
  echo "見つからない: ${src}" >&2
  exit 1
fi

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

tgit() {
  HOME="${work}/githome" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    git -c user.name=tester -c user.email=tester@example.test -c init.defaultBranch=main -c commit.gpgsign=false "$@"
}
mkdir -p "${work}/githome"

# 偽の setup-local-flake.sh を書く。$1: パス、$2: heredoc の中身、$3: heredoc の外に置く行 (省略可)。
# 開きの行は本物と同じく `  cat >"${flake_file}" <<EOS` (2 字下げ)
fake_slf() {
  mkdir -p "$(dirname "$1")"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# 偽の setup-local-flake.sh\n'
    printf '%s\n' "${3:-echo 前の処理}"
    printf 'if true; then\n'
    printf '  cat >"${flake_file}" <<EOS\n'
    printf '%s\n' "$2"
    printf 'EOS\n'
    printf 'fi\n'
  } >"$1"
}

# 使い捨ての repo を作り、写した local-flake-migrate.sh の場所を出す。script は 2 つ上を repo と見る
new_repo() {
  local r="${work}/$1"
  mkdir -p "${r}/nix/scripts"
  cp "${src}" "${r}/nix/scripts/local-flake-migrate.sh"
  tgit -C "${r}" init -q
  echo "${r}"
}

# $1: repo、残り: script の引数。stdout・stderr・終了コードを <repo>/{out,err,rc} に残す
run() {
  local r=$1
  shift
  HOME="${work}/githome" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    "${BASH}" "${r}/nix/scripts/local-flake-migrate.sh" "$@" >"${r}/out" 2>"${r}/err"
  echo $? >"${r}/rc"
}
rc() { cat "$1/rc"; }
out() { cat "$1/out"; }
err() { cat "$1/err"; }

echo "== local-flake-migrate.sh (${src})"

# 1. render: 置き換える展開
r=$(new_repo r1)
fake_slf "${r}/nix/scripts/setup-local-flake.sh" '# 版: ${template_id}
  inputs.dotfiles.url = "path:${nix_dir}";
  # pwsh.exe -Command '"'"'\$env:USERNAME'"'"'
  a \`x\` b
  c\\d
  費用は $ 5 と $'"'"'x'"'"''
run "${r}" id "${r}/nix/scripts/setup-local-flake.sh"
id1=$(out "${r}")
run "${r}" render --file "${r}/nix/scripts/setup-local-flake.sh" --nix-dir /N
want="# 版: ${id1}
  inputs.dotfiles.url = \"path:/N\";
  # pwsh.exe -Command '\$env:USERNAME'
  a \`x\` b
  c\\d
  費用は \$ 5 と \$'x'"
if [[ $(rc "${r}") == 0 && $(out "${r}") == "${want}" ]]; then
  ok "render は \${nix_dir}・\${template_id}・\\\$・\\\`・\\\\ を heredoc と同じに描く"
else
  ng "render の置き換え" "rc=$(rc "${r}") out=$(out "${r}") err=$(err "${r}")"
fi
# 同じ偽の script を bash で流して heredoc を本当に展開させ、render と比べる (偽の script はこのテストが書いたもの)
flake_file="${r}/real.out" nix_dir=/N template_id="${id1}" "${BASH}" "${r}/nix/scripts/setup-local-flake.sh" >/dev/null
if [[ $(cat "${r}/real.out") == "$(out "${r}")" ]]; then
  ok "render の出力は、同じ heredoc を bash が展開したものと同じ"
else
  ng "render と bash の展開が違う" "bash=$(cat "${r}/real.out") render=$(out "${r}")"
fi
if [[ ${id1} =~ ^[0-9a-f]{8}$ ]]; then
  ok "id は 8 桁の 16 進"
else
  ng "id の形" "${id1}"
fi

# 2. render: 描けない展開
# shellcheck disable=SC1003 # 最後の 'x \' は、行末の \ を確かめる
for body in 'x $HOME y' 'x ${other} y' 'x $(date) y' 'x $[1+1] y' 'x `date` y' 'x $1 y' 'x $@ y' 'x \'; do
  fake_slf "${r}/nix/scripts/setup-local-flake.sh" "${body}"
  run "${r}" render --file "${r}/nix/scripts/setup-local-flake.sh" --nix-dir /N
  if [[ $(rc "${r}") == 1 ]] && grep -q '描けない' "${r}/err"; then
    ok "render は描けない展開で 1 を返す: ${body}"
  else
    ng "描けない展開: ${body}" "rc=$(rc "${r}") out=$(out "${r}") err=$(err "${r}")"
  fi
done

# 3. id: heredoc の中を変えると変わり、外を変えても変わらない。stdin でも同じ
fake_slf "${r}/a.sh" 'line 1
line 2' 'echo 外 A'
fake_slf "${r}/b.sh" 'line 1
line 2' 'echo 外 B'
fake_slf "${r}/c.sh" 'line 1
line 3' 'echo 外 A'
run "${r}" id "${r}/a.sh"
id_a=$(out "${r}")
run "${r}" id "${r}/b.sh"
id_b=$(out "${r}")
run "${r}" id "${r}/c.sh"
id_c=$(out "${r}")
HOME="${work}/githome" "${BASH}" "${r}/nix/scripts/local-flake-migrate.sh" id - <"${r}/a.sh" >"${r}/out" 2>"${r}/err"
id_stdin=$(out "${r}")
if [[ -n ${id_a} && ${id_a} == "${id_b}" ]]; then
  ok "id は heredoc の外を変えても変わらない"
else
  ng "id が heredoc の外で変わる" "a=${id_a} b=${id_b}"
fi
if [[ -n ${id_a} && ${id_a} != "${id_c}" ]]; then
  ok "id は heredoc の中を変えると変わる"
else
  ng "id が heredoc の中で変わらない" "a=${id_a} c=${id_c}"
fi
if [[ ${id_stdin} == "${id_a}" ]]; then
  ok "id - は stdin の script の印を出す"
else
  ng "id - (stdin)" "a=${id_a} stdin=${id_stdin}"
fi

# 4. 開きの行が 1 つでない・閉じの EOS が無い
printf '#!/usr/bin/env bash\necho 雛形が無い\n' >"${r}/none.sh"
{
  cat "${r}/a.sh"
  printf '  cat >"${flake_file}" <<EOS\nもう 1 つ\nEOS\n'
} >"${r}/two.sh"
printf '#!/usr/bin/env bash\n  cat >"${flake_file}" <<EOS\n閉じない\n' >"${r}/open.sh"
for f in none two open; do
  run "${r}" id "${r}/${f}.sh"
  rc_id=$(rc "${r}")
  run "${r}" render --file "${r}/${f}.sh" --nix-dir /N
  if [[ ${rc_id} == 1 && $(rc "${r}") == 1 ]]; then
    ok "開きの行か閉じの行がおかしい script (${f}) は、id も render も 1"
  else
    ng "おかしい script (${f})" "id rc=${rc_id} render rc=$(rc "${r}") err=$(err "${r}")"
  fi
done

# 5. render --rev: repo の履歴の版を描く
r=$(new_repo r5)
fake_slf "${r}/nix/scripts/setup-local-flake.sh" '版 1: ${nix_dir}'
tgit -C "${r}" add -A
tgit -C "${r}" commit -qm v1
v1=$(tgit -C "${r}" rev-parse HEAD)
fake_slf "${r}/nix/scripts/setup-local-flake.sh" '版 2: ${nix_dir}'
tgit -C "${r}" commit -qam v2
run "${r}" render --rev "${v1}" --nix-dir /N
if [[ $(rc "${r}") == 0 && $(out "${r}") == '版 1: /N' ]]; then
  ok "render --rev は履歴の版を描く"
else
  ng "render --rev" "rc=$(rc "${r}") out=$(out "${r}") err=$(err "${r}")"
fi
run "${r}" render --rev HEAD --nix-dir /N
if [[ $(rc "${r}") == 0 && $(out "${r}") == '版 2: /N' ]]; then
  ok "render --rev HEAD は今の commit の版を描く"
else
  ng "render --rev HEAD" "rc=$(rc "${r}") out=$(out "${r}") err=$(err "${r}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
