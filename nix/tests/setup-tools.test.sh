#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/setup.sh が、設定グループ (ADR 057) で off の道具の手順 (bootstrap-*.sh の冒頭の `# tool: <key> (<option>)`) を
# ~/.local/state/dotfiles/group.json の tools を見て飛ばすことと、対象ホストのグループを 1 行出すことを、使い捨ての checkout・
# HOME と偽の bootstrap・nix で確かめる。
#
#   bash nix/tests/setup-tools.test.sh [<nix/scripts のパス>]
#
# flake の checks (setup-tools-test) が Nix のサンドボックスで流す。本物の nix と bootstrap は使わない。
#
# ## 確かめること
#
#   - group.json の tools で false の key を見出しに書いた手順は流さず、「このホストでは <option> が off なので飛ばします」と、
#     結果に「↷ … (このホストでは off)」を出す。見出しの無い手順・true の key の手順は流す。終了コードは 0
#   - group.json が無い (この仕組みの前の世代)・読めない形なら、見出しによらず全部流す
#   - key は文字で見るが、名前の頭が同じ別の key (claude と claudePrivateSkills) を取り違えない
#   - --dry-run でも、off の手順は「飛ばします」と出し、ほかの手順はコマンド (「+ …/bootstrap-<名前>.sh」) を見せるだけ (どれも流さない)
#   - 冒頭の 40 行より後ろの `# tool:` の行は読まない (order と同じ)
#   - 対象ホストが決まっていれば、実行の頭に nix eval でそのホストのグループを 1 行 (「グループ: …」) 出す。nix eval が落ちれば
#     何も出さずに進む。対象ホストが決まっていなければ nix を呼ばない
#   - switch の手順の頭でもう一度評価し、実行の頭に出した行と同じなら出さない (1 回だけ)。変わっていれば (取得でグループが
#     変わった) 「グループ (前に出したものから変わった): …」と出し直す
#
# ## 作り
#
# setup-system-units.test.sh と同じく、使い捨ての checkout (<ケース>/repo/nix/scripts/) に setup.sh と偽の bootstrap を置き、
# 要るコマンドだけを並べた PATH で --steps を流す。偽の bootstrap は流れたら <ケース>/home/ran-<名前> を作る。偽の nix は
# 引数を <ケース>/home/nix-calls に書き、グループの 1 行の eval (--apply hc: …) なら FAKE_GROUP_LINE を出す (2 回目からは
# FAKE_GROUP_LINE2 があればそれ)。FAKE_NIX_FAIL があれば 1 で終わる。ほかの eval (config.warnings) には何も出さない。偽の
# home-manager は何もせず 0 を返す。shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
scripts=${1:-${here}/../scripts}
setup=${scripts}/setup.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/setup-tools-test.XXXXXX")
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

# 要るコマンドだけを並べた PATH (git・gh・本物の nix・home-manager は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env awk sed grep sort head tr cat dirname basename readlink uname id mktemp mkdir rm chmod cksum touch; do
  if ! p=$(type -P "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

fake_bin="${work}/fake-bin"
mkdir -p "${fake_bin}"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/nix-calls"
[[ -z ${FAKE_NIX_FAIL-} ]] || exit 1
case "$*" in
  *'--apply hc:'*)
    n=$(grep -c -- '--apply hc:' "${HOME}/nix-calls")
    if ((n >= 2)) && [[ -n ${FAKE_GROUP_LINE2-} ]]; then
      printf '%s' "${FAKE_GROUP_LINE2}"
    else
      printf '%s' "${FAKE_GROUP_LINE-}"
    fi
    ;;
esac
EOF
} >"${fake_bin}/nix"
printf '#!%s\nexit 0\n' "${BASH}" >"${fake_bin}/home-manager"
chmod +x "${fake_bin}/nix" "${fake_bin}/home-manager"

# 偽の bootstrap を書く。$1: ケース、$2: 名前 (bootstrap-<名前>.sh)、$3: 見出しの行 (空なら書かない)、$4: 見出しの前に置く
# コメントの行数 (省けば 0)
fake_bootstrap() {
  local f="$1/repo/nix/scripts/bootstrap-$2.sh" i
  {
    printf '#!%s\n' "${BASH}"
    printf '#\n# 偽の bootstrap (%s)。\n#\n' "$2"
    for ((i = 0; i < ${4:-0}; i++)); do
      printf '# 埋め草の行 %d\n' "${i}"
    done
    if [[ -n $3 ]]; then
      printf '%s\n' "$3"
    fi
    # shellcheck disable=SC2016 # 偽の bootstrap が流れたときに展開する ${HOME} をそのまま書く
    printf ': >"${HOME}/ran-%s"\n' "$2"
  } >"${f}"
  chmod +x "${f}"
}

# 1 ケースぶんの checkout と HOME を作り、その場所を出す。$2: group.json の中身 (空なら作らない)
new_case() {
  local c="${work}/$1"
  mkdir -p "${c}/repo/nix/scripts" "${c}/repo/nix/hosts" "${c}/home/.local/state/dotfiles" "${c}/tmp"
  cp "${setup}" "${c}/repo/nix/scripts/setup.sh"
  printf '{ mkHome }:\n{\n  testhost = mkHome {\n    username = "test";\n  };\n}\n' >"${c}/repo/nix/hosts/default.nix"
  if [[ -n $2 ]]; then
    printf '%s\n' "$2" >"${c}/home/.local/state/dotfiles/group.json"
  fi
  fake_bootstrap "${c}" claude '# tool: claude (dotfiles.claude.enable)'
  fake_bootstrap "${c}" skills '# tool: claudePrivateSkills (dotfiles.claude.privateSkills.enable)'
  fake_bootstrap "${c}" plain ''
  fake_bootstrap "${c}" late '# tool: claude (dotfiles.claude.enable)' 40
  echo "${c}"
}

steps=bootstrap-claude,bootstrap-skills,bootstrap-plain,bootstrap-late

# $1: ケース、残り: setup.sh の引数。stdout・stderr・終了コードを <ケース>/{out,err,rc} に残す
run() {
  local c=$1
  shift
  env -i HOME="${c}/home" USER=test TMPDIR="${c}/tmp" NO_COLOR=1 PATH="${fake_bin}:${sys_bin}" \
    DOTFILES_LOCAL_DIR="${c}/local" FAKE_GROUP_LINE="${FAKE_GROUP_LINE-}" ${FAKE_GROUP_LINE2+"FAKE_GROUP_LINE2=${FAKE_GROUP_LINE2}"} \
    ${FAKE_NIX_FAIL+"FAKE_NIX_FAIL=1"} \
    "${BASH}" "${c}/repo/nix/scripts/setup.sh" "$@" >"${c}/out" 2>"${c}/err" </dev/null
  echo $? >"${c}/rc"
}

rc() { cat "$1/rc"; }
ran() { [[ -e $1/home/ran-$2 ]]; }
show() {
  printf 'rc=%s\nout=%s\nerr=%s\nran=%s\nnix=%s' "$(rc "$1")" "$(cat "$1/out")" "$(cat "$1/err")" \
    "$(cd "$1/home" && printf '%s ' ran-* 2>/dev/null)" "$(cat "$1/home/nix-calls" 2>/dev/null)"
}

off_claude='{"group":"client","tiers":{"aiTools":false,"personalAccounts":false},"tools":{"claude":false,"claudePrivateSkills":true},"version":1}'
all_on='{"group":"personal","tiers":{"aiTools":true,"personalAccounts":true},"tools":{"claude":true,"claudePrivateSkills":true},"version":1}'
off_skills='{"group":"company","tiers":{"aiTools":true,"personalAccounts":false},"tools":{"claude":true,"claudePrivateSkills":false},"version":1}'

echo "== setup.sh: 設定グループで手順を飛ばす (${setup})"

# 1. off の key の手順は飛ばし、結果に ↷ を出す。見出しの無い手順・true の手順・40 行より後ろの見出しの手順は流す
c=$(new_case off "${off_claude}")
run "${c}" --steps "${steps}"
if [[ $(rc "${c}") == 0 ]] && ! ran "${c}" claude && ran "${c}" skills && ran "${c}" plain && ran "${c}" late \
  && grep -Fq 'このホストでは dotfiles.claude.enable が off なので飛ばします' "${c}/out" \
  && grep -Fq '↷ ./nix/scripts/bootstrap-claude.sh (このホストでは off)' "${c}/out"; then
  ok "group.json で false の道具の手順は飛ばして ↷ を出し、見出しの無い・true の・40 行より後ろに見出しのある手順は流す"
else
  ng "off の道具" "$(show "${c}")"
fi

# 2. 名前の頭が同じ別の key を取り違えない (claudePrivateSkills だけが false)
c=$(new_case off-skills "${off_skills}")
run "${c}" --steps "${steps}"
if [[ $(rc "${c}") == 0 ]] && ran "${c}" claude && ! ran "${c}" skills && ran "${c}" plain \
  && grep -Fq 'このホストでは dotfiles.claude.privateSkills.enable が off なので飛ばします' "${c}/out"; then
  ok "claudePrivateSkills だけが false なら、その手順だけを飛ばす (claude と取り違えない)"
else
  ng "名前の頭が同じ key" "$(show "${c}")"
fi

# 3. group.json が無い・読めない形・全部 true なら全部流す
all_ran=1
for spec in "absent:" "broken:{" "on:${all_on}"; do
  c=$(new_case "${spec%%:*}" "${spec#*:}")
  run "${c}" --steps "${steps}"
  if ! { [[ $(rc "${c}") == 0 ]] && ran "${c}" claude && ran "${c}" skills && ran "${c}" plain \
    && ! grep -Fq '飛ばします' "${c}/out"; }; then
    all_ran=0
    ng "group.json が ${spec%%:*}" "$(show "${c}")"
  fi
done
if [[ ${all_ran} == 1 ]]; then
  ok "group.json が無い・読めない形・全部 true なら、見出しによらず全部流す"
fi

# 4. --dry-run: off の手順は「飛ばします」、ほかはコマンドを見せるだけ
c=$(new_case dry "${off_claude}")
run "${c}" --dry-run --steps "${steps}"
if [[ $(rc "${c}") == 0 ]] && ! ran "${c}" claude && ! ran "${c}" plain \
  && grep -Fq 'このホストでは dotfiles.claude.enable が off なので飛ばします' "${c}/out" \
  && grep -Fxq "+ ${c}/repo/nix/scripts/bootstrap-plain.sh" "${c}/out" \
  && ! grep -Fq "+ ${c}/repo/nix/scripts/bootstrap-claude.sh" "${c}/out"; then
  ok "--dry-run でも off の手順は「飛ばします」と出し、どの手順も流さない"
else
  ng "--dry-run" "$(show "${c}")"
fi

# 5. 対象ホストが決まっていれば、実行の頭にグループを 1 行出す (1 回だけ)。nix eval が落ちれば黙って進む
c=$(new_case group-line "${all_on}")
FAKE_GROUP_LINE='client (ホストで選んだ) · ① エンジニアの道具 on · ② AI の道具 off · ③ 個人のアカウント off' \
  run "${c}" --host testhost --steps bootstrap-plain
lines=$(grep -c '^  グループ: client (ホストで選んだ)' "${c}/out" || true)
evals=$(grep -c '^eval --raw --no-write-lock-file .*homeConfigurations\."testhost"' "${c}/home/nix-calls" 2>/dev/null || true)
c2=$(new_case group-line-fail "${all_on}")
FAKE_NIX_FAIL=1 run "${c2}" --host testhost --steps bootstrap-plain
c3=$(new_case group-line-nohost "${all_on}")
FAKE_GROUP_LINE='client' run "${c3}" --steps bootstrap-plain
if [[ $(rc "${c}") == 0 && ${lines} == 1 && ${evals} == 1 ]] && ran "${c}" plain \
  && [[ $(rc "${c2}") == 0 ]] && ! grep -Fq 'グループ:' "${c2}/out" && ran "${c2}" plain \
  && [[ $(rc "${c3}") == 0 && ! -e ${c3}/home/nix-calls ]]; then
  ok "対象ホストが決まっていれば実行の頭にグループを 1 回出し、nix eval が落ちれば黙る。決まっていなければ nix を呼ばない"
else
  ng "グループの 1 行" "lines=${lines} evals=${evals}"$'\n'"$(show "${c}")"$'\n'"--- 落ちる nix"$'\n'"$(show "${c2}")"$'\n'"--- ホストなし"$'\n'"$(show "${c3}")"
fi

# 6. switch の頭でもう一度評価し、同じ行なら出さない (1 回だけ)。変わっていれば「前に出したものから変わった」と出し直す
c=$(new_case group-switch "${all_on}")
FAKE_GROUP_LINE='company (ホストで選んだ) · ① エンジニアの道具 on · ② AI の道具 on · ③ 個人のアカウント off' \
  run "${c}" --host testhost --steps switch
same_lines=$(grep -c 'グループ' "${c}/out" || true)
same_evals=$(grep -c -- '--apply hc:' "${c}/home/nix-calls" 2>/dev/null || true)
c2=$(new_case group-switch-changed "${all_on}")
FAKE_GROUP_LINE='personal (選んでいない。既定) · ① エンジニアの道具 on · ② AI の道具 on · ③ 個人のアカウント on' \
  FAKE_GROUP_LINE2='company (ホストで選んだ) · ① エンジニアの道具 on · ② AI の道具 on · ③ 個人のアカウント off' \
  run "${c2}" --host testhost --steps switch
if [[ $(rc "${c}") == 0 && ${same_lines} == 1 && ${same_evals} == 2 && $(rc "${c2}") == 0 ]] \
  && grep -Fq '  グループ: personal (選んでいない。既定)' "${c2}/out" \
  && grep -Fq '  グループ (前に出したものから変わった): company (ホストで選んだ)' "${c2}/out"; then
  ok "switch の頭で評価し直し、同じ行なら出さず (1 回だけ)、変わっていれば「前に出したものから変わった」と出し直す"
else
  ng "switch の頭のグループ" "lines=${same_lines} evals=${same_evals}"$'\n'"$(show "${c}")"$'\n'"--- 変わる"$'\n'"$(show "${c2}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
