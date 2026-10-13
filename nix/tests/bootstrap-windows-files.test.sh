#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-files.sh の振る舞いを、使い捨ての HOME と偽の nix-instantiate で確かめる。
#
#   bash nix/tests/bootstrap-windows-files.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-files-test) が Nix のサンドボックスで流す。
# 使うのは bash・jq・coreutils・diff・grep だけ。
#
# ## 確かめること
#
#   - 置き先が無ければコピーして記録する。同じ中身なら書かずに記録だけする
#   - 置き先が記録どおりなら (repo 側が更新された) 上書きして記録を更新する
#   - 置き先が記録と違えば (Windows 側で変わった) 衝突。触らずに diff と解き方を出し、exit 1
#   - 記録が無く、置き先が repo と違えば (この script が置く前から Windows 側にあった) 衝突。
#     「前回ここへ置いた中身と違う」とは出さず、置いた記録が無いことを出す
#   - --force は衝突でも上書きして記録する。--dry-run は置き先も記録も書かない
#   - script に実行ビットがある (setup.sh は -x でない bootstrap を流さずに止まる)
#
# ## 本物の nix-instantiate を見せない
#
# script は nix/lib/windows-files.nix を nix-instantiate で評価して計画 (置き先を解決した JSON) を
# 作るが、サンドボックスには nix-instantiate が無い。ケースごとの plan.json をそのまま出す偽物を置き、
# 要るコマンドだけを symlink で並べた PATH で流す。偽物の shebang は $BASH から作る (サンドボックスに
# /usr/bin/env が無い)。manifest の読み方と検証は、CI の `bootstrap-windows-files.sh --check` が受け持つ。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-files.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-files-test.XXXXXX")
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

# 要るコマンドだけを並べた PATH (nix-instantiate は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in jq sha256sum cut cat mkdir dirname mktemp cp chmod mv rm diff; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# 配る 1 ファイルの置き先 ($1: HOME)。Windows のホームに見立てるのは <HOME>/win
dst() { echo "$1/win/AppData/Local/App/config.json"; }
src() { echo "$1/repo/win/app/config.json"; }
record_file() { echo "$1/.local/state/dotfiles/windows-files.deployed.json"; }

# 1 ケースぶんの HOME を作る。repo 側の 1 ファイル (中身は $2) を dst へ配る計画にする。$1: 名前
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.local/state/dotfiles" "${h}/bin" "${h}/repo/win/app" "${h}/win"
  jq -n --arg home "${h}/win" '{enable: true, version: 1, windowsHome: $home}' \
    >"${h}/.local/state/dotfiles/windows-files.json"
  printf '%s\n' "$2" >"$(src "${h}")"
  jq -n --arg src "$(src "${h}")" --arg dst "$(dst "${h}")" \
    '{version: 1, files: [{src: $src, repoPath: "win/app/config.json", dst: $dst, hint: "アプリで読み直す"}]}' \
    >"${h}/plan.json"
  # 偽の nix-instantiate。引数は見ずに plan.json を出す
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$(<"${HOME}/plan.json")"
EOF
  } >"${h}/bin/nix-instantiate"
  chmod +x "${h}/bin/nix-instantiate"
  echo "${h}"
}

# Windows 側に置き先を作る ($1: HOME、$2: 中身)
put_dst() {
  mkdir -p "$(dirname "$(dst "$1")")"
  printf '%s\n' "$2" >"$(dst "$1")"
}

# 前回ここへ置いた中身の記録を作る ($1: HOME、$2: 置いた中身)
set_record() {
  local sum
  sum=$(printf '%s\n' "$2" | sha256sum | cut -d' ' -f1)
  jq -n --arg k "$(dst "$1")" --arg v "${sum}" '{($k): $v}' >"$(record_file "$1")"
}

# 記録にある置き先の sha256 (無ければ空)
recorded() { jq -r --arg k "$(dst "$1")" '.[$k] // ""' "$(record_file "$1")" 2>/dev/null; }
sha() { sha256sum <"$1" | cut -d' ' -f1; }
ino() { stat -c %i "$1"; }

# $1: HOME、残り: script の引数
run() {
  local h=$1
  shift
  env HOME="${h}" PATH="${h}/bin:${sys_bin}" "${BASH}" "${script}" "$@" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }

echo "== bootstrap-windows-files.sh: ${script}"

# 1. 置き先が無い: コピーして記録する
h=$(new_home t1 'repo v1')
run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "$(dst "${h}")") == 'repo v1' && $(recorded "${h}") == "$(sha "$(src "${h}")")" ]] \
  && outerr "${h}" | grep -qF "コピー: $(dst "${h}")"; then
  ok "置き先が無ければコピーして記録する"
else
  ng "置き先が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 2. 置き先が同じ中身で記録が無い (今の設定をそのまま取り込んだ): 書かずに記録だけする
h=$(new_home t2 'same')
put_dst "${h}" 'same'
before=$(ino "$(dst "${h}")")
run "${h}"
if [[ $(rc "${h}") == 0 && $(ino "$(dst "${h}")") == "${before}" && $(recorded "${h}") == "$(sha "$(src "${h}")")" ]] \
  && outerr "${h}" | grep -qF "同じです: $(dst "${h}")"; then
  ok "置き先が同じ中身なら書かずに記録だけする"
else
  ng "同じ中身" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 3. 置き先が記録どおりで、repo 側が変わった: 上書きして記録を更新する
h=$(new_home t3 'repo v2')
put_dst "${h}" 'repo v1'
set_record "${h}" 'repo v1'
run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "$(dst "${h}")") == 'repo v2' && $(recorded "${h}") == "$(sha "$(src "${h}")")" ]] \
  && outerr "${h}" | grep -qF '上書き (repo 側が更新された)'; then
  ok "置き先が記録どおりなら (repo 側が更新された) 上書きして記録を更新する"
else
  ng "repo 側が更新された" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 4. 置き先が記録と違う (Windows 側で変えた): 触らずに diff と解き方を出し、exit 1
h=$(new_home t4 'repo v2')
put_dst "${h}" 'edited on windows'
set_record "${h}" 'repo v1'
before=$(recorded "${h}")
run "${h}"
if [[ $(rc "${h}") == 1 && $(cat "$(dst "${h}")") == 'edited on windows' && $(recorded "${h}") == "${before}" ]] \
  && outerr "${h}" | grep -qF '前回ここへ置いた中身と違う' \
  && outerr "${h}" | grep -qxF -- '-edited on windows' && outerr "${h}" | grep -qxF -- '+repo v2' \
  && outerr "${h}" | grep -qF "cp '$(dst "${h}")'" && outerr "${h}" | grep -qF -- '--force'; then
  ok "置き先が記録と違えば衝突: 触らずに diff と解き方を出し、exit 1"
else
  ng "Windows 側で変えた" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 5. 記録が無く、置き先が repo と違う (この script が置く前からあった。手で同じ設定をした、など): 衝突。
#    一度も置いていないので「前回ここへ置いた中身と違う」とは出さず、置いた記録が無いことを出す
h=$(new_home t5 'repo v1')
put_dst "${h}" 'made by hand'
run "${h}"
if [[ $(rc "${h}") == 1 && $(cat "$(dst "${h}")") == 'made by hand' && -z $(recorded "${h}") ]] \
  && outerr "${h}" | grep -qF '置いた記録が無く' && ! outerr "${h}" | grep -qF '前回ここへ置いた中身と違う' \
  && outerr "${h}" | grep -qF "cp '$(dst "${h}")'" && outerr "${h}" | grep -qF -- '--force'; then
  ok "記録が無く中身が違えば衝突: 前回置いた中身とは言わず、置いた記録が無いと出す"
else
  ng "記録が無い衝突" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 6. --force: 衝突でも上書きして記録する
h=$(new_home t6 'repo v1')
put_dst "${h}" 'made by hand'
run "${h}" --force
if [[ $(rc "${h}") == 0 && $(cat "$(dst "${h}")") == 'repo v1' && $(recorded "${h}") == "$(sha "$(src "${h}")")" ]] \
  && outerr "${h}" | grep -qF '上書き (--force)'; then
  ok "--force なら衝突でも上書きして記録する"
else
  ng "--force" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 7. --dry-run: 置き先も記録も書かない
h=$(new_home t7 'repo v1')
run "${h}" --dry-run
if [[ $(rc "${h}") == 0 && ! -e $(dst "${h}") && ! -e $(record_file "${h}") ]] \
  && outerr "${h}" | grep -qF "[dry-run] コピー: $(dst "${h}")"; then
  ok "--dry-run は置き先も記録も書かない"
else
  ng "--dry-run" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 8. script に実行ビットがある (setup.sh は実行ビットの無い bootstrap を「実行できません」で止める)
if [[ -x ${script} ]]; then
  ok "script に実行ビットがある (setup.sh は実行できない bootstrap で止まる)"
else
  ng "script に実行ビットが無い" "$(ls -l "${script}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
