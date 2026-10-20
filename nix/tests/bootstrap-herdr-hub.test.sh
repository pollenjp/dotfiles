#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-herdr-hub.sh が、claude-skills の skill pjp-herdr-hub の hub-init.sh を打つところを、使い捨ての
# HOME と偽の hub-init.sh で確かめる。
#
#   bash nix/tests/bootstrap-herdr-hub.test.sh [<nix/scripts のパス>]
#
# flake の checks (bootstrap-herdr-hub-test) が Nix のサンドボックスで流す。setup.sh の手順の並びも見るので、
# nix/scripts を丸ごと渡す。使うのは bash・coreutils・grep だけ (本物の hub-init.sh は private な claude-skills に
# あり、サンドボックスに無い)。
#
# ## 確かめること
#
#   - ~/.claude/skills/pjp-herdr-hub が無い (claude-skills を取れないマシン・まだ張っていない) なら、何も作らずに
#     0 で終わり、警告は出さない (setup の最後のまとめにも載せない)
#   - pjp-herdr-hub が張られていれば、その hub-init.sh を引数なしで (既定の ~/h に) 1 回打ち、出力を見せて 0 で終わる。
#     警告は出さない
#   - hub-init.sh が止まったら (終了コード 1。~/h が別の repo の中・雛形の外のものがある、など)、その出力を続きの行に
#     した警告と、この手順だけを流し直すコマンド (--steps bootstrap-herdr-hub) を setup の最後のまとめにも残し、0 で
#     終わる (setup の後ろの手順を止めない)。1 以外の終了コード (git の失敗など) でも同じ
#   - pjp-herdr-hub はあるのに hub-init.sh が無ければ (claude-skills の側で名前や場所が変わった)、警告して 0 で終わる
#   - 知らない引数 (--dry-run・--check など) では hub-init.sh を打たずに終了コード 2 で終わる (書かないつもりの引数で
#     書かない)
#   - setup の手順の並び (setup.sh --list) で、claude-skills の skill を張る bootstrap-claude-skills より後に来る
#
# 偽の hub-init.sh は、引数と HOME を書き留め、決めた行を stdout・stderr に出して FAKE_RC で終わる。pjp-herdr-hub は、
# setup と同じく claude-skills の clone の中の skill への symlink として張る。偽のコマンドの shebang は $BASH から作る
# (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
scripts=${1:-${here}/../scripts}
script=${scripts}/bootstrap-herdr-hub.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-herdr-hub-test.XXXXXX")
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

# $1: HOME。claude-skills の clone (<HOME>/clone) の中に skill pjp-herdr-hub を作り、~/.claude/skills へ symlink で張る
# (hub-init.sh はまだ置かない)
link_skill() {
  mkdir -p "$1/clone/skills/pjp-herdr-hub/scripts" "$1/.claude/skills"
  ln -s "$1/clone/skills/pjp-herdr-hub" "$1/.claude/skills/pjp-herdr-hub"
}

# $1: HOME。張った pjp-herdr-hub に偽の hub-init.sh を置く。打たれるたびに引数と HOME を <HOME>/calls に 1 行足し、
# stdout に「書いた: CLAUDE.md」、FAKE_ERR があれば stderr にそれを出して、FAKE_RC (既定 0) で終わる
fake_hub_init() {
  local f="$1/clone/skills/pjp-herdr-hub/scripts/hub-init.sh"
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf 'args=[%s] home=%s\n' "$*" "${HOME}" >>"${HOME}/calls"
echo "書いた: CLAUDE.md"
if [[ -n ${FAKE_ERR-} ]]; then
  echo "${FAKE_ERR}" >&2
fi
exit "${FAKE_RC:-0}"
EOF
  } >"${f}"
  chmod +x "${f}"
}

# $1: HOME、残り: script の引数。setup から走るときと同じく、まとめ用のファイル (空) を DOTFILES_SETUP_WARNINGS で
# 渡して流す。stdout・stderr・終了コード・まとめ用のファイルを <HOME>/{stdout,stderr,rc,warnings} に残す
run() {
  local h=$1
  shift
  mkdir -p "${h}"
  : >"${h}/warnings"
  env HOME="${h}" DOTFILES_SETUP_WARNINGS="${h}/warnings" "${BASH}" "${script}" "$@" \
    >"${h}/stdout" 2>"${h}/stderr" </dev/null
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
detail() {
  printf 'rc=%s\nstdout=%s\nstderr=%s\nwarnings=%s\ncalls=%s' "$(cat "$1/rc")" "$(cat "$1/stdout")" \
    "$(cat "$1/stderr")" "$(cat "$1/warnings")" "$(cat "$1/calls" 2>/dev/null)"
}

echo "== bootstrap-herdr-hub.sh: ${script}"

# 1. pjp-herdr-hub が張られていない: 何も作らずに 0 で終わり、警告しない
h="${work}/t1"
run "${h}"
if [[ $(rc "${h}") == 0 && ! -s ${h}/warnings && ! -s ${h}/stderr && ! -e ${h}/h ]]; then
  ok "pjp-herdr-hub が張られていなければ、何も作らずに 0 で終わり、警告しない"
else
  ng "pjp-herdr-hub が無い" "$(detail "${h}")"
fi

# 2. 張られている: hub-init.sh を引数なしで 1 回打ち、出力を見せて 0 で終わる
h="${work}/t2"
link_skill "${h}"
fake_hub_init "${h}"
run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "${h}/calls" 2>/dev/null) == "args=[] home=${h}" && ! -s ${h}/warnings ]] \
  && grep -qF '書いた: CLAUDE.md' "${h}/stdout"; then
  ok "pjp-herdr-hub が張られていれば hub-init.sh を引数なしで 1 回打ち、出力を見せて 0 で終わる"
else
  ng "hub-init.sh を打つ" "$(detail "${h}")"
fi

# 3. hub-init.sh が止まった (終了コード 1): 出力を続きの行にした警告と流し直し方をまとめにも残し、0 で終わる
h="${work}/t3"
link_skill "${h}"
fake_hub_init "${h}"
err="hub-init.sh: ${h}/h は repo ${h} の中。ハブは repo の外に作る"
FAKE_RC=1 FAKE_ERR=${err} run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "${h}/calls" 2>/dev/null) == "args=[] home=${h}" ]] \
  && [[ $(head -n 1 "${h}/warnings") == [![:space:]]* ]] \
  && grep -qxF "   ${err}" "${h}/warnings" && grep -qxF '   書いた: CLAUDE.md' "${h}/warnings" \
  && grep -qF -- '--steps bootstrap-herdr-hub' "${h}/warnings" && grep -q '^!! ' "${h}/stderr"; then
  ok "hub-init.sh が止まったら、その出力と流し直し方を警告にしてまとめにも残し、0 で終わる"
else
  ng "hub-init.sh が止まった" "$(detail "${h}")"
fi

# 4. 1 以外の終了コード (git の失敗など) でも、警告して 0 で終わる
h="${work}/t4"
link_skill "${h}"
fake_hub_init "${h}"
FAKE_RC=128 FAKE_ERR='fatal: unable to auto-detect email address' run "${h}"
if [[ $(rc "${h}") == 0 ]] && grep -qxF '   fatal: unable to auto-detect email address' "${h}/warnings"; then
  ok "hub-init.sh が 1 以外の終了コードで終わっても、警告して 0 で終わる"
else
  ng "終了コード 128" "$(detail "${h}")"
fi

# 5. pjp-herdr-hub はあるのに hub-init.sh が無い: 警告して 0 で終わる
h="${work}/t5"
link_skill "${h}"
run "${h}"
if [[ $(rc "${h}") == 0 && -s ${h}/warnings && ! -e ${h}/h ]] && grep -q '^!! ' "${h}/stderr"; then
  ok "pjp-herdr-hub はあるのに hub-init.sh が無ければ、警告して 0 で終わる"
else
  ng "hub-init.sh が無い" "$(detail "${h}")"
fi

# 6. 知らない引数: hub-init.sh を打たずに終了コード 2 で終わる
h="${work}/t6"
link_skill "${h}"
fake_hub_init "${h}"
run "${h}" --dry-run
if [[ $(rc "${h}") == 2 && ! -e ${h}/calls ]]; then
  ok "知らない引数では hub-init.sh を打たずに終了コード 2 で終わる"
else
  ng "知らない引数" "$(detail "${h}")"
fi

# 7. setup の手順の並び: bootstrap-claude-skills より後に来る。使い捨ての checkout に setup.sh と 2 つの bootstrap を写し、
# 登録簿を置いて --list で並べる
o="${work}/order"
mkdir -p "${o}/repo/nix/scripts" "${o}/repo/nix/hosts" "${o}/home"
cp "${scripts}/setup.sh" "${scripts}/bootstrap-claude-skills.sh" "${script}" "${o}/repo/nix/scripts/"
printf '{ mkHome }:\n{\n  testhost = mkHome {\n    username = "test";\n  };\n}\n' >"${o}/repo/nix/hosts/default.nix"
listed=$(env HOME="${o}/home" TMPDIR="${work}" "${BASH}" "${o}/repo/nix/scripts/setup.sh" --list 2>&1 </dev/null)
ids=$(awk '$1 ~ /^bootstrap-/ { print $1 }' <<<"${listed}")
if [[ ${ids} == $'bootstrap-claude-skills\nbootstrap-herdr-hub' ]]; then
  ok "setup の手順の並びで、bootstrap-claude-skills より後に来る"
else
  ng "setup の並び" "${listed}"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
