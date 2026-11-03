#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-claude-skill-overrides.sh の振る舞いを、使い捨ての HOME と偽の skill で確かめる。
#
#   bash nix/tests/bootstrap-claude-skill-overrides.test.sh [<nix/scripts のパス>]
#
# flake の checks (bootstrap-claude-skill-overrides-test) が Nix のサンドボックスで流す。setup.sh の手順の並びも見るので、
# nix/scripts を丸ごと渡す。使うのは bash・jq・coreutils・awk だけ。
#
# ## 確かめること
#
#   - host option の値 (claude-skill-overrides.json) を skillOverrides に上書きし、settings.json のほかのキーと手で足した
#     key は残す。host option のファイルが無ければ警告して (setup の最後のまとめにも残し)、ほかの分は書いて 0 で終わる。
#     --no-host-option では読まず、警告もしない
#   - SKILL.md の metadata の pjp-pack を持つ skill は、その pack の入口 (pjp-pack-<pack>/SKILL.md) があれば name-only に
#     し、控え (claude-skill-overrides.applied.json) に書く。pack の無い skill には書かない
#   - 入口の無い pack の skill は名前だけにしない。ほかの pack の入口があれば、その pack と skill の名前を警告し (setup の
#     最後のまとめにも残す)、入口が 1 つも無ければ stdout に 1 行出すだけ (警告しない)
#   - 入口の skill・mod を兼ねる skill (.claude-plugin/plugin.json) の pjp-pack と、pack の名前として読めない値は、
#     警告して名前だけにしない
#   - metadata の読み方: 値の引用符と後ろのコメント・metadata の中のコメントの行・CRLF の SKILL.md は受ける。metadata の
#     外の pjp-pack・description の中の文字・metadata の下の深い字下げの pjp-pack・flow の形・frontmatter の後ろは読まない
#   - claude.ai から同期された skill (~/.claude/skills/synced/*/<名前>/ と、claude-accounts.json のアカウントの
#     ~/.claude-<アカウント>/skills/synced/*/<名前>/) を anthropic-skills:<名前> の user-invocable-only にする。重なりは 1 つ
#   - host option の key と同じ名前の pack の skill は、host option の値だけを書き、控えない
#   - 書きたくなくなった key (入口が消えた・同期された skill が消えた) は、今の値が控えと同じなら消し、手で変えていれば
#     残す。どちらも控えから外す
#   - 書く前からあった別の値と、書いた後に手で変えた値には触らず、控えず、stdout に知らせる。書く前から同じ値があれば控え、
#     あとで戻す
#   - 控えた値 (前の版が書いた値) から書きたい値が変わったら、書き換える
#   - 同じ内容で流し直すと settings.json と控えを書き直さない (inode が変わらない)。書くものが無ければどちらも作らない
#   - settings.json が壊れている・skillOverrides が object でない・host option のファイルが object でないときは、何も書かずに
#     1 で終わる。控えが壊れていれば警告し、無いものとして進めて控えを書き直す
#   - --quiet は stdout に何も出さない。知らない引数は何も書かずに 2、--help は 0
#   - setup の手順の並び (setup.sh --list) で、claude-skills の skill を張る bootstrap-claude-skills より後に来る

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
scripts=${1:-${here}/../scripts}
script=${scripts}/bootstrap-claude-skill-overrides.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-claude-skill-overrides-test.XXXXXX")
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

# new_home <ケース>: そのケースの HOME を作って出す
new_home() {
  local h="${work}/$1/home"
  mkdir -p "${h}/.claude/skills" "${h}/.local/state/dotfiles"
  printf '%s' "${h}"
}
# host_file <HOME> <JSON>: host option の値 (home-manager が置くファイル) を置く
host_file() {
  printf '%s\n' "$2" >"$1/.local/state/dotfiles/claude-skill-overrides.json"
}
# settings_file <HOME> <JSON>: ~/.claude/settings.json を置く
settings_file() {
  printf '%s\n' "$2" >"$1/.claude/settings.json"
}
# skill <HOME> <skill の名前> [<pack>]: ~/.claude/skills/<名前>/SKILL.md を置く。pack があれば metadata に書く
skill() {
  local d="$1/.claude/skills/$2"
  mkdir -p "${d}"
  {
    printf -- '---\nname: %s\ndescription: x\n' "$2"
    if [[ -n ${3:-} ]]; then
      printf 'metadata:\n  pjp-pack: %s\n' "$3"
    fi
    printf -- '---\n\n# %s\n' "$2"
  } >"${d}/SKILL.md"
}
# raw_skill <HOME> <skill の名前>: SKILL.md の中身を stdin から置く
raw_skill() {
  mkdir -p "$1/.claude/skills/$2"
  cat >"$1/.claude/skills/$2/SKILL.md"
}
# entry <HOME> <pack>: 入口の skill pjp-pack-<pack> を置く
entry() {
  skill "$1" "pjp-pack-$2"
}
# synced <config dir> <bucket> <skill の名前>: claude.ai から同期された skill を置く
synced() {
  mkdir -p "$1/skills/synced/$2/$3"
  printf -- '---\nname: %s\ndescription: x\n---\n' "$3" >"$1/skills/synced/$2/$3/SKILL.md"
}
# run <HOME> [<script の引数>…]: HOME をそれにして流し、out・err・rc を HOME の隣に残す。手元の
# DOTFILES_SETUP_WARNINGS は外す (足すときは run_env に入れる)
run_env=()
run() {
  local h=$1
  shift
  env -u DOTFILES_SETUP_WARNINGS ${run_env[@]+"${run_env[@]}"} HOME="${h}" bash "${script}" "$@" \
    >"${h}/../out" 2>"${h}/../err" </dev/null
  echo $? >"${h}/../rc"
}
rc() { cat "$1/../rc"; }
out() { cat "$1/../out"; }
err() { cat "$1/../err"; }
# overrides <HOME>: settings.json の skillOverrides (キーの順に並べた 1 行)
overrides() {
  jq -S -c '.skillOverrides' "$1/.claude/settings.json" 2>&1
}
# recorded <HOME>: 控えの keys (キーの順に並べた 1 行)
recorded() {
  jq -S -c 'if .version == 1 then .keys else "version が違う" end' \
    "$1/.local/state/dotfiles/claude-skill-overrides.applied.json" 2>&1
}
# same <JSON> <JSON>: 2 つが同じ JSON か
same() {
  jq -e -n --argjson a "$1" --argjson b "$2" '$a == $b' >/dev/null 2>&1
}
# detail <HOME>: 失敗したときに出すもの
detail() {
  printf 'rc=%s\nout:\n%s\nerr:\n%s\noverrides: %s\nrecorded: %s' \
    "$(rc "$1")" "$(out "$1")" "$(err "$1")" "$(overrides "$1")" "$(recorded "$1")"
}

echo "== bootstrap-claude-skill-overrides.sh"

uio=user-invocable-only

# 1. host option・pack・同期された skill を書き、ほかのキーと手で足した key は残す。同じ内容なら書き直さない
h=$(new_home t1)
host_file "${h}" '{"pjp-dev-tracker":"off"}'
settings_file "${h}" '{"model":"x","skillOverrides":{"foo":"off","pjp-dev-tracker":"on"}}'
entry "${h}" diagram
skill "${h}" pjp-a diagram
skill "${h}" pjp-b diagram
skill "${h}" pjp-c
synced "${h}/.claude" b1 pdf
synced "${h}/.claude" b1 docx
synced "${h}/.claude-work" b2 pdf
synced "${h}/.claude-work" b2 xlsx
synced "${h}/.claude-other" b3 pptx
printf '["work"]\n' >"${h}/.local/state/dotfiles/claude-accounts.json"
run "${h}"
want_ov=$(jq -c -n --arg u "${uio}" '{"foo":"off","pjp-dev-tracker":"off","pjp-a":"name-only","pjp-b":"name-only",
  "anthropic-skills:pdf":$u,"anthropic-skills:docx":$u,"anthropic-skills:xlsx":$u}')
want_rec=$(jq -c -n --arg u "${uio}" '{"pjp-a":"name-only","pjp-b":"name-only",
  "anthropic-skills:pdf":$u,"anthropic-skills:docx":$u,"anthropic-skills:xlsx":$u}')
if [[ $(rc "${h}") == 0 && -z $(err "${h}") ]] && same "$(overrides "${h}")" "${want_ov}" \
  && same "$(recorded "${h}")" "${want_rec}" \
  && [[ $(jq -r '.model' "${h}/.claude/settings.json") == x ]]; then
  ok "host option・入口のある pack の skill・同期された skill (アカウントの dir の分も) を書き、ほかは残す"
else
  ng "初回の書き込み" "$(detail "${h}")"
fi
ino_settings=$(stat -c %i "${h}/.claude/settings.json")
ino_record=$(stat -c %i "${h}/.local/state/dotfiles/claude-skill-overrides.applied.json")
run "${h}"
if [[ $(rc "${h}") == 0 && -z $(err "${h}") ]] \
  && [[ $(stat -c %i "${h}/.claude/settings.json") == "${ino_settings}" ]] \
  && [[ $(stat -c %i "${h}/.local/state/dotfiles/claude-skill-overrides.applied.json") == "${ino_record}" ]] \
  && same "$(overrides "${h}")" "${want_ov}"; then
  ok "同じ内容で流し直すと settings.json と控えを書き直さない"
else
  ng "流し直し" "$(detail "${h}")"
fi

# 2. ほかの pack の入口はあるのに、その pack の入口が無い: 警告して (まとめにも残し) 名前だけにしない
h=$(new_home t2)
host_file "${h}" '{}'
entry "${h}" diagram
skill "${h}" pjp-a diagram
skill "${h}" pjp-m machine
run_env=("DOTFILES_SETUP_WARNINGS=${work}/t2/warnings")
run "${h}"
run_env=()
if [[ $(rc "${h}") == 0 ]] && same "$(overrides "${h}")" '{"pjp-a":"name-only"}' \
  && grep -q 'pack machine の入口' "${work}/t2/err" && grep -q 'pjp-m' "${work}/t2/err" \
  && grep -q 'pack machine の入口' "${work}/t2/warnings"; then
  ok "入口の無い pack の skill は名前だけにせず、ほかの入口があれば警告する (まとめにも残す)"
else
  ng "入口の無い pack" "$(detail "${h}")"
fi

# 3. 入口が 1 つも無い: stdout に 1 行出すだけ。書くものが無ければ settings.json も控えも作らない
h=$(new_home t3)
skill "${h}" pjp-a diagram
skill "${h}" pjp-m machine
run "${h}" --no-host-option
if [[ $(rc "${h}") == 0 && -z $(err "${h}") ]] && grep -q '1 つも無い' "${work}/t3/out" \
  && [[ ! -e ${h}/.claude/settings.json && ! -e ${h}/.local/state/dotfiles/claude-skill-overrides.applied.json ]]; then
  ok "入口が 1 つも無ければ警告せずに 1 行出し、書くものが無ければ何も作らない (--no-host-option は host option を読まない)"
else
  ng "入口が 1 つも無い" "$(detail "${h}")"
fi

# 4. host option のファイルが無い: 警告して (まとめにも残し)、ほかの分は書いて 0
h=$(new_home t4)
synced "${h}/.claude" b1 pdf
run_env=("DOTFILES_SETUP_WARNINGS=${work}/t4/warnings")
run "${h}"
run_env=()
if [[ $(rc "${h}") == 0 ]] && same "$(overrides "${h}")" "{\"anthropic-skills:pdf\":\"${uio}\"}" \
  && grep -q '生成ファイルがありません' "${work}/t4/err" && grep -q '生成ファイルがありません' "${work}/t4/warnings"; then
  ok "host option のファイルが無ければ警告し、ほかの分は書く"
else
  ng "host option のファイルが無い" "$(detail "${h}")"
fi

# 5. 入口の skill・mod を兼ねる skill・読めない pack の名前は、警告して名前だけにしない
h=$(new_home t5)
host_file "${h}" '{}'
skill "${h}" pjp-pack-diagram diagram
skill "${h}" pjp-mod diagram
mkdir -p "${h}/.claude/skills/pjp-mod/.claude-plugin"
printf '{"name":"pjp-mod"}\n' >"${h}/.claude/skills/pjp-mod/.claude-plugin/plugin.json"
skill "${h}" pjp-bad 'Diagram!'
skill "${h}" pjp-a diagram
run "${h}"
if [[ $(rc "${h}") == 0 ]] && same "$(overrides "${h}")" '{"pjp-a":"name-only"}' \
  && grep -q '入口の skill pjp-pack-diagram' "${work}/t5/err" && grep -q 'mod を兼ねる skill pjp-mod' "${work}/t5/err" \
  && grep -q 'pack の名前として読めません: Diagram!' "${work}/t5/err"; then
  ok "入口の skill・mod を兼ねる skill・読めない pack の名前は、警告して名前だけにしない"
else
  ng "入口・mod・読めない名前" "$(detail "${h}")"
fi

# 6. metadata の読み方
h=$(new_home t6)
host_file "${h}" '{}'
entry "${h}" diagram
raw_skill "${h}" pjp-quoted <<'EOF'
---
name: pjp-quoted
description: x
metadata:
  pjp-pack: "diagram"  # 図の pack
---
EOF
raw_skill "${h}" pjp-comment <<'EOF'
---
name: pjp-comment
metadata:
  # 割り当て
  owner: me
  pjp-pack: 'diagram'
description: x
---
EOF
printf -- '---\r\nname: pjp-crlf\r\ndescription: x\r\nmetadata:\r\n  pjp-pack: diagram\r\n---\r\n' \
  | raw_skill "${h}" pjp-crlf
raw_skill "${h}" pjp-top <<'EOF'
---
name: pjp-top
description: x
pjp-pack: diagram
---
EOF
raw_skill "${h}" pjp-desc <<'EOF'
---
name: pjp-desc
description: >-
  図を描く。
  pjp-pack: diagram
---
EOF
raw_skill "${h}" pjp-deep <<'EOF'
---
name: pjp-deep
description: x
metadata:
  other:
    pjp-pack: diagram
---
EOF
raw_skill "${h}" pjp-flow <<'EOF'
---
name: pjp-flow
description: x
metadata: {pjp-pack: diagram}
---
EOF
raw_skill "${h}" pjp-body <<'EOF'
---
name: pjp-body
description: x
---

metadata:
  pjp-pack: diagram
EOF
run "${h}"
if [[ $(rc "${h}") == 0 ]] \
  && same "$(overrides "${h}")" '{"pjp-quoted":"name-only","pjp-comment":"name-only","pjp-crlf":"name-only"}'; then
  ok "metadata の pjp-pack を決まった形だけ読む (引用符・コメント・CRLF は受け、外・深い所・flow・本文は読まない)"
else
  ng "metadata の読み方" "$(detail "${h}")"
fi

# 7. host option の key と同じ名前の pack の skill は、host option の値だけを書き、控えない
h=$(new_home t7)
host_file "${h}" '{"pjp-dev-tracker":"on"}'
entry "${h}" diagram
skill "${h}" pjp-dev-tracker diagram
run "${h}"
if [[ $(rc "${h}") == 0 ]] && same "$(overrides "${h}")" '{"pjp-dev-tracker":"on"}' \
  && [[ ! -e ${h}/.local/state/dotfiles/claude-skill-overrides.applied.json ]]; then
  ok "host option の key と同じ名前の skill は、host option の値だけを書く"
else
  ng "host option の key が勝つ" "$(detail "${h}")"
fi

# 8. 戻す: 入口が消えた pack の skill・消えた同期された skill は、控えと同じなら消し、手で変えていれば残す
h=$(new_home t8)
host_file "${h}" '{}'
entry "${h}" diagram
skill "${h}" pjp-a diagram
skill "${h}" pjp-b diagram
synced "${h}/.claude" b1 pdf
synced "${h}/.claude" b1 docx
run "${h}"
jq '.skillOverrides["pjp-b"] = "on"' "${h}/.claude/settings.json" >"${work}/t8/s.json"
mv "${work}/t8/s.json" "${h}/.claude/settings.json"
rm -rf "${h}/.claude/skills/pjp-pack-diagram" "${h}/.claude/skills/synced/b1/docx"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && same "$(overrides "${h}")" "{\"pjp-b\":\"on\",\"anthropic-skills:pdf\":\"${uio}\"}" \
  && same "$(recorded "${h}")" "{\"anthropic-skills:pdf\":\"${uio}\"}" \
  && grep -q '戻しました' "${work}/t8/out"; then
  ok "書かなくなった key は控えと同じなら消し、手で変えた key は残す (どちらも控えから外す)"
else
  ng "戻す" "$(detail "${h}")"
fi

# 9. 書く前からあった値: 別の値は残して控えず知らせる。同じ値は控え、あとで戻す
h=$(new_home t9)
host_file "${h}" '{}'
settings_file "${h}" '{"skillOverrides":{"pjp-a":"on","pjp-b":"name-only"}}'
entry "${h}" diagram
skill "${h}" pjp-a diagram
skill "${h}" pjp-b diagram
run "${h}"
first_ok=0
if [[ $(rc "${h}") == 0 ]] && same "$(overrides "${h}")" '{"pjp-a":"on","pjp-b":"name-only"}' \
  && same "$(recorded "${h}")" '{"pjp-b":"name-only"}' && grep -q '手で書いた値を残しました (on' "${work}/t9/out"; then
  first_ok=1
fi
first_detail=$(detail "${h}")
rm -rf "${h}/.claude/skills/pjp-pack-diagram"
run "${h}"
if [[ ${first_ok} == 1 && $(rc "${h}") == 0 ]] && same "$(overrides "${h}")" '{"pjp-a":"on"}' \
  && same "$(recorded "${h}")" '{}'; then
  ok "書く前からあった別の値は残して知らせ、同じ値は控えて、あとで戻す"
else
  ng "書く前からあった値" "${first_detail}"$'\n'"--- 2 回目"$'\n'"$(detail "${h}")"
fi

# 10. 控えた値 (前の版が書いた値) から書きたい値が変わったら、書き換える
h=$(new_home t10)
host_file "${h}" '{}'
settings_file "${h}" '{"skillOverrides":{"anthropic-skills:pdf":"off"}}'
printf '{"version":1,"keys":{"anthropic-skills:pdf":"off"}}\n' \
  >"${h}/.local/state/dotfiles/claude-skill-overrides.applied.json"
synced "${h}/.claude" b1 pdf
run "${h}"
if [[ $(rc "${h}") == 0 ]] && same "$(overrides "${h}")" "{\"anthropic-skills:pdf\":\"${uio}\"}" \
  && same "$(recorded "${h}")" "{\"anthropic-skills:pdf\":\"${uio}\"}"; then
  ok "控えた値から書きたい値が変わったら書き換える"
else
  ng "控えた値からの書き換え" "$(detail "${h}")"
fi

# 11. 読めない入力: settings.json・skillOverrides・host option のファイルは何も書かずに 1。控えは警告して進める
broken_ok=1
broken_detail=""
for c in 'settings:{' 'overrides:{"skillOverrides":[]}' 'host:[]'; do
  kind=${c%%:*}
  body=${c#*:}
  h=$(new_home "t11-${kind}")
  synced "${h}/.claude" b1 pdf
  if [[ ${kind} == host ]]; then
    host_file "${h}" "${body}"
    settings_file "${h}" '{}'
  else
    host_file "${h}" '{}'
    settings_file "${h}" "${body}"
  fi
  cp "${h}/.claude/settings.json" "${work}/t11-${kind}/before.json"
  run "${h}"
  if [[ $(rc "${h}") != 1 ]] || ! cmp -s "${h}/.claude/settings.json" "${work}/t11-${kind}/before.json" \
    || [[ -e ${h}/.local/state/dotfiles/claude-skill-overrides.applied.json ]]; then
    broken_ok=0
    broken_detail+="${kind}: $(detail "${h}")"$'\n'
  fi
done
if [[ ${broken_ok} == 1 ]]; then
  ok "settings.json・skillOverrides・host option のファイルが読めなければ、何も書かずに 1 で終わる"
else
  ng "読めない入力" "${broken_detail}"
fi
h=$(new_home t11-record)
host_file "${h}" '{}'
synced "${h}/.claude" b1 pdf
printf 'garbage\n' >"${h}/.local/state/dotfiles/claude-skill-overrides.applied.json"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && grep -q '控えが読めません' "${work}/t11-record/err" \
  && same "$(overrides "${h}")" "{\"anthropic-skills:pdf\":\"${uio}\"}" \
  && same "$(recorded "${h}")" "{\"anthropic-skills:pdf\":\"${uio}\"}"; then
  ok "控えが読めなければ警告し、無いものとして進めて書き直す"
else
  ng "読めない控え" "$(detail "${h}")"
fi

# 12. --quiet・知らない引数・--help
h=$(new_home t12)
host_file "${h}" '{}'
synced "${h}/.claude" b1 pdf
run "${h}" --quiet
quiet_ok=0
if [[ $(rc "${h}") == 0 && -z $(out "${h}") ]] && same "$(overrides "${h}")" "{\"anthropic-skills:pdf\":\"${uio}\"}"; then
  quiet_ok=1
fi
h2=$(new_home t12-unknown)
synced "${h2}/.claude" b1 pdf
run "${h2}" --dry-run
h3=$(new_home t12-help)
run "${h3}" --help
if [[ ${quiet_ok} == 1 && $(rc "${h2}") == 2 && ! -e ${h2}/.claude/settings.json && $(rc "${h3}") == 0 ]]; then
  ok "--quiet は stdout に何も出さず、知らない引数は何も書かずに 2、--help は 0"
else
  ng "--quiet・知らない引数・--help" "$(detail "${h}")"$'\n'"unknown: $(detail "${h2}")"$'\n'"help: $(detail "${h3}")"
fi

# 13. setup の手順の並び: bootstrap-claude-skills より後に来る。使い捨ての checkout に setup.sh と 2 つの bootstrap を写し、
# 登録簿を置いて --list で並べる
o="${work}/order"
mkdir -p "${o}/repo/nix/scripts" "${o}/repo/nix/hosts" "${o}/home"
cp "${scripts}/setup.sh" "${scripts}/bootstrap-claude-skills.sh" "${script}" "${o}/repo/nix/scripts/"
printf '{ mkHome }:\n{\n  testhost = mkHome {\n    username = "test";\n  };\n}\n' >"${o}/repo/nix/hosts/default.nix"
listed=$(env HOME="${o}/home" TMPDIR="${work}" "${BASH}" "${o}/repo/nix/scripts/setup.sh" --list 2>&1 </dev/null)
ids=$(awk '$1 ~ /^bootstrap-/ { print $1 }' <<<"${listed}")
if [[ ${ids} == $'bootstrap-claude-skills\nbootstrap-claude-skill-overrides' ]]; then
  ok "setup の手順の並びで、bootstrap-claude-skills より後に来る"
else
  ng "setup の並び" "${listed}"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
