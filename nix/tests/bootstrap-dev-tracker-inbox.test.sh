#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-dev-tracker-inbox.sh が、Dev Tracker のコメントの見回り役 (systemd の user service
# pjp-dev-tracker-inbox) を起こし直すところを、使い捨ての HOME と偽の systemctl・journalctl で確かめる。
#
#   bash nix/tests/bootstrap-dev-tracker-inbox.test.sh [<nix/scripts のパス>]
#
# flake の checks (bootstrap-dev-tracker-inbox-test) が Nix のサンドボックスで流す。setup.sh の手順の並びも見るので、
# nix/scripts を丸ごと渡す。使うのは bash と coreutils・grep・sed・awk だけ (user の systemd はサンドボックスに無い)。
#
# ## 確かめること
#
#   - unit (~/.config/systemd/user/pjp-dev-tracker-inbox.service) が置かれていない (option が false の) マシンでは、
#     systemctl を呼ばずに 0 で終わり、警告しない
#   - unit があれば daemon-reload・reset-failed・restart の順に呼び、3 秒のうちに止まらなければ「起こし直した」と出して
#     0 で終わる。警告しない。systemctl に stdin を渡さない
#   - 起こした見回り役が終了コード 2 で止まったら (設定の誤り・ticket.sh に inbox がまだ無い)、journal の末尾と、
#     この手順だけを流し直すコマンド (--steps bootstrap-dev-tracker-inbox) を setup の最後のまとめにも残し、0 で終わる
#   - 2 以外で落ちて起こし直しを待っている (auto-restart) ときも、警告して 0 で終わる
#   - ticket.sh か ~/h が無くて unit の条件で起動が飛んだら (ConditionResult=no)、1 行出して 0 で終わり、警告しない
#   - restart が失敗したら、その出力を続きの行にした警告を残して 0 で終わる
#   - unit はあるのに user の systemd に届かない (show-environment が落ちる) なら、restart を呼ばずに警告して 0 で終わる
#   - 知らない引数 (--dry-run など) では systemctl を呼ばずに終了コード 2 で終わる
#   - setup の手順の並び (setup.sh --list) で、bootstrap-claude-skills・bootstrap-herdr-hub より後に来る
#
# 偽の systemctl は、引数と stdin から読めた 1 行を <HOME>/calls に 1 行ずつ書き留め、show では FAKE_SHOW の中身
# (KEY=VALUE の行) を出す。restart は FAKE_RESTART_RC (既定 0) で終わり、show-environment は FAKE_NO_SESSION があれば
# 1 で終わる。偽の journalctl は FAKE_JOURNAL を出す。script には、読めば中身の出る stdin を渡す。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
scripts=${1:-${here}/../scripts}
script=${scripts}/bootstrap-dev-tracker-inbox.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-dev-tracker-inbox-test.XXXXXX")
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

unit=pjp-dev-tracker-inbox.service

# script に渡す stdin。systemctl へ渡ってしまえば、偽物がこの 1 行を読む
printf 'y\n' >"${work}/stdin"

# 偽の systemctl と journalctl (shebang はサンドボックスに /usr/bin/env が無いので $BASH から作る)
mkdir -p "${work}/bin"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
line=""
IFS= read -r -t 0.1 line || true
printf '%s stdin=[%s]\n' "$*" "${line}" >>"${HOME}/calls"
case " $* " in
  *" show-environment "*)
    [[ -z ${FAKE_NO_SESSION-} ]] || exit 1
    echo "HOME=${HOME}"
    ;;
  *" show "*)
    printf '%s\n' "${FAKE_SHOW-}"
    ;;
  *" restart "*)
    if [[ -n ${FAKE_RESTART_ERR-} ]]; then
      echo "${FAKE_RESTART_ERR}" >&2
    fi
    exit "${FAKE_RESTART_RC:-0}"
    ;;
esac
exit 0
EOF
} >"${work}/bin/systemctl"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf '%s\n' "${FAKE_JOURNAL-}"
EOF
} >"${work}/bin/journalctl"
chmod +x "${work}/bin/systemctl" "${work}/bin/journalctl"

# $1: HOME。home-manager が置くのと同じ場所に unit ファイルを置く
place_unit() {
  mkdir -p "$1/.config/systemd/user"
  printf '[Unit]\nDescription=fake\n' >"$1/.config/systemd/user/${unit}"
}

# $1: HOME、残り: script の引数。setup から走るときと同じく、まとめ用のファイル (空) を DOTFILES_SETUP_WARNINGS で
# 渡して流す。stdout・stderr・終了コード・まとめ用のファイルを <HOME>/{stdout,stderr,rc,warnings} に残す
run() {
  local h=$1
  shift
  mkdir -p "${h}"
  : >"${h}/warnings"
  env -u XDG_CONFIG_HOME HOME="${h}" PATH="${work}/bin:${PATH}" DOTFILES_SETUP_WARNINGS="${h}/warnings" \
    "${BASH}" "${script}" "$@" >"${h}/stdout" 2>"${h}/stderr" <"${work}/stdin"
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
# calls の中で、引数 (stdin の印を外したもの) が $2 の行の番号。無ければ空
call_at() {
  awk -v want="$2" '{ sub(/ stdin=\[[^]]*\]$/, ""); if ($0 == want) { print NR; exit } }' "$1/calls" 2>/dev/null
}
detail() {
  printf 'rc=%s\nstdout=%s\nstderr=%s\nwarnings=%s\ncalls=%s' "$(cat "$1/rc")" "$(cat "$1/stdout")" \
    "$(cat "$1/stderr")" "$(cat "$1/warnings")" "$(cat "$1/calls" 2>/dev/null)"
}

running=$'ActiveState=active\nSubState=running\nResult=success\nExecMainStatus=0\nConditionResult=yes'
exited2=$'ActiveState=failed\nSubState=failed\nResult=exit-code\nExecMainStatus=2\nConditionResult=yes'
retrying=$'ActiveState=activating\nSubState=auto-restart\nResult=exit-code\nExecMainStatus=1\nConditionResult=yes'
skipped=$'ActiveState=inactive\nSubState=dead\nResult=success\nExecMainStatus=0\nConditionResult=no'

echo "== bootstrap-dev-tracker-inbox.sh: ${script}"

# 1. unit が無い: systemctl を呼ばずに 0 で終わり、警告しない
h="${work}/t1"
run "${h}"
if [[ $(rc "${h}") == 0 && ! -e ${h}/calls && ! -s ${h}/warnings && ! -s ${h}/stderr ]]; then
  ok "unit が無ければ systemctl を呼ばずに 0 で終わり、警告しない"
else
  ng "unit が無い" "$(detail "${h}")"
fi

# 2. unit があり、起こした見回り役が動き続ける: daemon-reload・reset-failed・restart の順に呼び、警告しない
h="${work}/t2"
place_unit "${h}"
FAKE_SHOW=${running} run "${h}"
reload=$(call_at "${h}" "--user daemon-reload")
reset=$(call_at "${h}" "--user reset-failed ${unit}")
restart=$(call_at "${h}" "--user restart ${unit}")
if [[ $(rc "${h}") == 0 && -n ${reload} && -n ${reset} && -n ${restart} && ! -s ${h}/warnings ]] \
  && ((reload < reset && reset < restart)) && grep -qF '起こし直しました' "${h}/stdout" \
  && ! grep -qv 'stdin=\[\]$' "${h}/calls"; then
  ok "unit があれば daemon-reload・reset-failed・restart の順に呼び、動き続ければ警告せずに 0 で終わる (stdin は渡さない)"
else
  ng "起こし直す" "$(detail "${h}")"
fi

# 3. 終了コード 2 で止まった: journal の末尾と流し直し方をまとめにも残し、0 で終わる
h="${work}/t3"
place_unit "${h}"
journal="ticket.sh inbox: プロファイル personal にユーザーの Notion の id がありません"
FAKE_SHOW=${exited2} FAKE_JOURNAL=${journal} run "${h}"
if [[ $(rc "${h}") == 0 ]] && [[ $(head -n 1 "${h}/warnings") == *'終了コード 2'* ]] \
  && grep -qxF "   ${journal}" "${h}/warnings" \
  && grep -qF -- '--steps bootstrap-dev-tracker-inbox' "${h}/warnings" && grep -q '^!! ' "${h}/stderr"; then
  ok "終了コード 2 で止まったら、journal の末尾と流し直し方を警告にしてまとめにも残し、0 で終わる"
else
  ng "終了コード 2" "$(detail "${h}")"
fi

# 4. 2 以外で落ちて起こし直しを待っている: 警告して 0 で終わる
h="${work}/t4"
place_unit "${h}"
FAKE_SHOW=${retrying} FAKE_JOURNAL='Traceback (most recent call last):' run "${h}"
if [[ $(rc "${h}") == 0 && -s ${h}/warnings ]] && grep -qxF '   Traceback (most recent call last):' "${h}/warnings" \
  && grep -q '^!! ' "${h}/stderr"; then
  ok "2 以外で落ちて起こし直しを待っていれば、警告して 0 で終わる"
else
  ng "auto-restart" "$(detail "${h}")"
fi

# 5. 条件で起動が飛んだ (ticket.sh か ~/h が無い): 1 行出して 0 で終わり、警告しない
h="${work}/t5"
place_unit "${h}"
FAKE_SHOW=${skipped} run "${h}"
if [[ $(rc "${h}") == 0 && ! -s ${h}/warnings && ! -s ${h}/stderr ]] && grep -qF '起動を飛ばしました' "${h}/stdout"; then
  ok "ticket.sh か ~/h が無くて起動が飛んだら、1 行出して 0 で終わり、警告しない"
else
  ng "条件で起動が飛んだ" "$(detail "${h}")"
fi

# 6. restart が失敗した: その出力を続きの行にした警告を残して 0 で終わる
h="${work}/t6"
place_unit "${h}"
err="Failed to restart ${unit}: Unit ${unit} not found."
FAKE_RESTART_RC=5 FAKE_RESTART_ERR=${err} run "${h}"
if [[ $(rc "${h}") == 0 ]] && grep -qxF "   ${err}" "${h}/warnings" && grep -q '^!! ' "${h}/stderr"; then
  ok "restart が失敗したら、その出力を続きの行にした警告を残して 0 で終わる"
else
  ng "restart が失敗した" "$(detail "${h}")"
fi

# 7. user の systemd に届かない: restart を呼ばずに警告して 0 で終わる
h="${work}/t7"
place_unit "${h}"
FAKE_NO_SESSION=1 run "${h}"
if [[ $(rc "${h}") == 0 && -s ${h}/warnings && -z $(call_at "${h}" "--user restart ${unit}") ]] \
  && grep -q '^!! ' "${h}/stderr"; then
  ok "user の systemd に届かなければ、restart を呼ばずに警告して 0 で終わる"
else
  ng "user session が無い" "$(detail "${h}")"
fi

# 8. 知らない引数: systemctl を呼ばずに終了コード 2 で終わる
h="${work}/t8"
place_unit "${h}"
run "${h}" --dry-run
if [[ $(rc "${h}") == 2 && ! -e ${h}/calls ]]; then
  ok "知らない引数では systemctl を呼ばずに終了コード 2 で終わる"
else
  ng "知らない引数" "$(detail "${h}")"
fi

# 9. setup の手順の並び: bootstrap-claude-skills・bootstrap-herdr-hub より後に来る。使い捨ての checkout に setup.sh と
# 3 つの bootstrap を写し、登録簿を置いて --list で並べる
o="${work}/order"
mkdir -p "${o}/repo/nix/scripts" "${o}/repo/nix/hosts" "${o}/home"
cp "${scripts}/setup.sh" "${scripts}/bootstrap-claude-skills.sh" "${scripts}/bootstrap-herdr-hub.sh" "${script}" \
  "${o}/repo/nix/scripts/"
printf '{ mkHome }:\n{\n  testhost = mkHome {\n    username = "test";\n  };\n}\n' >"${o}/repo/nix/hosts/default.nix"
listed=$(env HOME="${o}/home" TMPDIR="${work}" "${BASH}" "${o}/repo/nix/scripts/setup.sh" --list 2>&1 </dev/null)
ids=$(awk '$1 ~ /^bootstrap-/ { print $1 }' <<<"${listed}")
if [[ ${ids} == $'bootstrap-claude-skills\nbootstrap-herdr-hub\nbootstrap-dev-tracker-inbox' ]]; then
  ok "setup の手順の並びで、bootstrap-claude-skills・bootstrap-herdr-hub より後に来る"
else
  ng "setup の並び" "${listed}"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
