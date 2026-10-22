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
#   - unit があれば daemon-reload・reset-failed・restart の順に呼ぶ。動き続ければ、状態を読み直しながら 3 秒ほど
#     見届けてから「起こし直した」と出して 0 で終わる。警告せず、journal も読まない。systemctl に stdin を渡さない
#   - 起こしてしばらく (1 秒) 動いてから終了コード 2 で止まったら (設定の誤り・ticket.sh に inbox がまだ無い)、今回の
#     起動 (InvocationID) の journal の末尾と、この手順だけを流し直すコマンド (--steps bootstrap-dev-tracker-inbox) を
#     setup の最後のまとめにも残し、0 で終わる (restart はすぐに返るので、読み直さないと止まったのを見逃す)
#   - 2 以外で落ちて起こし直しを待っている (auto-restart) とき・終了コード 0 ですぐに終わったときも、警告して 0 で終わる
#   - ticket.sh か ~/h が無くて unit の条件で起動が飛んだら (ConditionResult=no)、無い方の名前と直し方
#     (bootstrap-claude-skills・bootstrap-herdr-hub) を警告にして 0 で終わる (option で使うと決めたマシンなので)
#   - restart が失敗したら、その出力を続きの行にした警告を残して 0 で終わる
#   - unit はあるのに user の systemd に届かない (show-environment が落ちる)・systemctl が無いなら、restart を呼ばずに
#     警告して 0 で終わる
#   - 知らない引数 (--dry-run など) では systemctl を呼ばずに終了コード 2 で終わる
#   - setup の手順の並び (setup.sh --list) で、bootstrap-claude-skills・bootstrap-herdr-hub より後に来る
#
# 偽の systemctl は、引数と stdin から読めた 1 行を <HOME>/calls に 1 行ずつ書き留める。restart は時刻を書き留めて
# FAKE_RESTART_RC (既定 0) で終わる。show (状態) は、restart から FAKE_LATER_MS ミリ秒たっていれば FAKE_LATER、まだなら
# FAKE_SHOW の状態を KEY=VALUE の行で出し (本物と同じく -p の順ではない並びで)、呼ばれた回数を <HOME>/shows に数える。
# show -p InvocationID は inv-1 を出す。show-environment は FAKE_NO_SESSION があれば 1 で終わる。偽の journalctl は、
# 引数を <HOME>/journal に書き留めて FAKE_JOURNAL を出す。script には、読めば中身の出る stdin を渡す。

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
mkdir -p "${work}/bin" "${work}/nobin"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
line=""
IFS= read -r -t 0.1 line || true
printf '%s stdin=[%s]\n' "$*" "${line}" >>"${HOME}/calls"
# 状態の名前から、show が出す行を組む (本物と同じく、-p に渡した順ではない並びで出す)
state_lines() {
  local a s r st c
  case $1 in
    running) a=active s=running r=success st=0 c=yes ;;
    exited2) a=failed s=failed r=exit-code st=2 c=yes ;;
    exited0) a=inactive s=dead r=success st=0 c=yes ;;
    retrying) a=activating s=auto-restart r=exit-code st=1 c=yes ;;
    skipped) a=inactive s=dead r=success st=0 c=no ;;
    *) return 0 ;;
  esac
  printf 'Result=%s\nExecMainStatus=%s\nActiveState=%s\nSubState=%s\nConditionResult=%s\n' "${r}" "${st}" "${a}" "${s}" "${c}"
}
case " $* " in
  *" show-environment "*)
    [[ -z ${FAKE_NO_SESSION-} ]] || exit 1
    echo "HOME=${HOME}"
    ;;
  *" -p InvocationID "*)
    echo "inv-1"
    ;;
  *" show "*)
    n=0
    if [[ -r ${HOME}/shows ]]; then
      n=$(<"${HOME}/shows")
    fi
    echo $((n + 1)) >"${HOME}/shows"
    state=${FAKE_SHOW-}
    if [[ -n ${FAKE_LATER-} && -r ${HOME}/restarted ]]; then
      started=$(<"${HOME}/restarted")
      if (($(date +%s%3N) - started >= ${FAKE_LATER_MS:-0})); then
        state=${FAKE_LATER}
      fi
    fi
    state_lines "${state}"
    ;;
  *" restart "*)
    date +%s%3N >"${HOME}/restarted"
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
printf '%s\n' "$*" >>"${HOME}/journal"
printf '%s\n' "${FAKE_JOURNAL-}"
EOF
} >"${work}/bin/journalctl"
chmod +x "${work}/bin/systemctl" "${work}/bin/journalctl"

# $1: HOME。home-manager が置くのと同じ場所に unit ファイルを置き、unit が起動の条件に見る ticket.sh と ~/h も作る
place_unit() {
  mkdir -p "$1/.config/systemd/user" "$1/.claude/skills/pjp-dev-tracker/scripts" "$1/h"
  printf '[Unit]\nDescription=fake\n' >"$1/.config/systemd/user/${unit}"
  : >"$1/.claude/skills/pjp-dev-tracker/scripts/ticket.sh"
}

# $1: HOME、残り: script の引数。setup から走るときと同じく、まとめ用のファイル (空) を DOTFILES_SETUP_WARNINGS で
# 渡して流す。stdout・stderr・終了コード・まとめ用のファイル・かかったミリ秒を <HOME>/{stdout,stderr,rc,warnings,ms}
# に残す。PATH は FAKE_PATH があればそれ (systemctl の無い PATH を試す)
run() {
  local h=$1 t0
  shift
  mkdir -p "${h}"
  : >"${h}/warnings"
  t0=$(date +%s%3N)
  env -u XDG_CONFIG_HOME HOME="${h}" PATH="${FAKE_PATH:-${work}/bin:${PATH}}" DOTFILES_SETUP_WARNINGS="${h}/warnings" \
    "${BASH}" "${script}" "$@" >"${h}/stdout" 2>"${h}/stderr" <"${work}/stdin"
  echo $? >"${h}/rc"
  echo $(($(date +%s%3N) - t0)) >"${h}/ms"
}

rc() { cat "$1/rc"; }
# calls の中で、引数 (stdin の印を外したもの) が $2 の行の番号。無ければ空
call_at() {
  awk -v want="$2" '{ sub(/ stdin=\[[^]]*\]$/, ""); if ($0 == want) { print NR; exit } }' "$1/calls" 2>/dev/null
}
detail() {
  printf 'rc=%s ms=%s shows=%s\nstdout=%s\nstderr=%s\nwarnings=%s\ncalls=%s\njournal=%s' "$(cat "$1/rc")" \
    "$(cat "$1/ms")" "$(cat "$1/shows" 2>/dev/null)" "$(cat "$1/stdout")" "$(cat "$1/stderr")" "$(cat "$1/warnings")" \
    "$(cat "$1/calls" 2>/dev/null)" "$(cat "$1/journal" 2>/dev/null)"
}

echo "== bootstrap-dev-tracker-inbox.sh: ${script}"

# 1. unit が無い: systemctl を呼ばずに 0 で終わり、警告しない
h="${work}/t1"
run "${h}"
if [[ $(rc "${h}") == 0 && ! -e ${h}/calls && ! -s ${h}/warnings && ! -s ${h}/stderr ]]; then
  ok "unit が無ければ systemctl を呼ばずに 0 で終わり、警告しない"
else
  ng "unit が無い" "$(detail "${h}")"
fi

# 2. unit があり、起こした見回り役が動き続ける: daemon-reload・reset-failed・restart の順に呼び、読み直しながら 3 秒ほど
# 見届けてから、警告せず journal も読まずに 0 で終わる
h="${work}/t2"
place_unit "${h}"
FAKE_SHOW=running run "${h}"
reload=$(call_at "${h}" "--user daemon-reload")
reset=$(call_at "${h}" "--user reset-failed ${unit}")
restart=$(call_at "${h}" "--user restart ${unit}")
if [[ $(rc "${h}") == 0 && -n ${reload} && -n ${reset} && -n ${restart} && ! -s ${h}/warnings && ! -e ${h}/journal ]] \
  && ((reload < reset && reset < restart && $(cat "${h}/shows") >= 2 && $(cat "${h}/ms") >= 2500)) \
  && grep -qF '起こし直しました' "${h}/stdout" && ! grep -qv 'stdin=\[\]$' "${h}/calls"; then
  ok "unit があれば daemon-reload・reset-failed・restart の順に呼び、動き続ければ読み直しながら 3 秒ほど見届けて、警告せずに 0 で終わる (stdin は渡さない)"
else
  ng "起こし直す" "$(detail "${h}")"
fi

# 3. 1 秒動いてから終了コード 2 で止まった: 今回の起動の journal の末尾と流し直し方をまとめにも残し、0 で終わる
h="${work}/t3"
place_unit "${h}"
journal="ticket.sh inbox: プロファイル personal にユーザーの Notion の id がありません"
FAKE_SHOW=running FAKE_LATER=exited2 FAKE_LATER_MS=1000 FAKE_JOURNAL=${journal} run "${h}"
if [[ $(rc "${h}") == 0 ]] && [[ $(head -n 1 "${h}/warnings") == *'終了コード 2'* ]] \
  && grep -qxF "   ${journal}" "${h}/warnings" && grep -qF '_SYSTEMD_INVOCATION_ID=inv-1' "${h}/journal" \
  && grep -qF -- '--steps bootstrap-dev-tracker-inbox' "${h}/warnings" && grep -q '^!! ' "${h}/stderr"; then
  ok "1 秒動いてから終了コード 2 で止まったら、今回の起動の journal の末尾と流し直し方を警告にしてまとめにも残し、0 で終わる"
else
  ng "終了コード 2" "$(detail "${h}")"
fi

# 4. 2 以外で落ちて起こし直しを待っている: 警告して 0 で終わる
h="${work}/t4"
place_unit "${h}"
FAKE_SHOW=running FAKE_LATER=retrying FAKE_LATER_MS=500 FAKE_JOURNAL='Traceback (most recent call last):' run "${h}"
if [[ $(rc "${h}") == 0 && -s ${h}/warnings ]] && grep -qxF '   Traceback (most recent call last):' "${h}/warnings" \
  && grep -q '^!! ' "${h}/stderr"; then
  ok "2 以外で落ちて起こし直しを待っていれば、警告して 0 で終わる"
else
  ng "auto-restart" "$(detail "${h}")"
fi

# 5. 終了コード 0 ですぐに終わった: 警告して 0 で終わる
h="${work}/t5"
place_unit "${h}"
FAKE_SHOW=running FAKE_LATER=exited0 FAKE_LATER_MS=500 run "${h}"
if [[ $(rc "${h}") == 0 && -s ${h}/warnings ]] && grep -qF 'すぐに止まりました' "${h}/warnings" \
  && grep -q '^!! ' "${h}/stderr"; then
  ok "終了コード 0 ですぐに終わったら、警告して 0 で終わる"
else
  ng "すぐに終わった" "$(detail "${h}")"
fi

# 6. ticket.sh が無くて条件で起動が飛んだ: ticket.sh の場所と bootstrap-claude-skills の案内を警告にして 0 で終わる
h="${work}/t6"
place_unit "${h}"
rm "${h}/.claude/skills/pjp-dev-tracker/scripts/ticket.sh"
FAKE_SHOW=skipped run "${h}"
if [[ $(rc "${h}") == 0 ]] && grep -qF "ticket.sh が無い: ${h}/.claude/skills/pjp-dev-tracker/scripts/ticket.sh" "${h}/warnings" \
  && grep -qF 'bootstrap-claude-skills' "${h}/warnings" && ! grep -qF 'ハブが無い' "${h}/warnings" \
  && grep -qF -- '--steps bootstrap-dev-tracker-inbox' "${h}/warnings" && grep -q '^!! ' "${h}/stderr"; then
  ok "ticket.sh が無くて起動が飛んだら、その場所と bootstrap-claude-skills の案内を警告にして 0 で終わる"
else
  ng "ticket.sh が無い" "$(detail "${h}")"
fi

# 7. ~/h が無くて条件で起動が飛んだ: ハブの場所と bootstrap-herdr-hub の案内を警告にして 0 で終わる
h="${work}/t7"
place_unit "${h}"
rmdir "${h}/h"
FAKE_SHOW=skipped run "${h}"
if [[ $(rc "${h}") == 0 ]] && grep -qF "ハブが無い: ${h}/h" "${h}/warnings" && grep -qF 'bootstrap-herdr-hub' "${h}/warnings" \
  && ! grep -qF 'ticket.sh が無い' "${h}/warnings" && grep -q '^!! ' "${h}/stderr"; then
  ok "ハブ (HOME の h) が無くて起動が飛んだら、その場所と bootstrap-herdr-hub の案内を警告にして 0 で終わる"
else
  ng "ハブが無い" "$(detail "${h}")"
fi

# 8. restart が失敗した: その出力を続きの行にした警告を残して 0 で終わる
h="${work}/t8"
place_unit "${h}"
err="Failed to restart ${unit}: Unit ${unit} not found."
FAKE_RESTART_RC=5 FAKE_RESTART_ERR=${err} run "${h}"
if [[ $(rc "${h}") == 0 ]] && grep -qxF "   ${err}" "${h}/warnings" && grep -q '^!! ' "${h}/stderr"; then
  ok "restart が失敗したら、その出力を続きの行にした警告を残して 0 で終わる"
else
  ng "restart が失敗した" "$(detail "${h}")"
fi

# 9. user の systemd に届かない: restart を呼ばずに警告して 0 で終わる
h="${work}/t9"
place_unit "${h}"
FAKE_NO_SESSION=1 run "${h}"
if [[ $(rc "${h}") == 0 && -s ${h}/warnings && -z $(call_at "${h}" "--user restart ${unit}") ]] \
  && grep -q '^!! ' "${h}/stderr"; then
  ok "user の systemd に届かなければ、restart を呼ばずに警告して 0 で終わる"
else
  ng "user session が無い" "$(detail "${h}")"
fi

# 10. systemctl が無い (PATH は空のディレクトリだけ。script は組み込みのコマンドだけでここまで来る): 警告して 0 で終わる
h="${work}/t10"
place_unit "${h}"
FAKE_PATH="${work}/nobin" run "${h}"
if [[ $(rc "${h}") == 0 && -s ${h}/warnings && ! -e ${h}/calls ]] && grep -q '^!! ' "${h}/stderr"; then
  ok "systemctl が無ければ、警告して 0 で終わる"
else
  ng "systemctl が無い" "$(detail "${h}")"
fi

# 11. 知らない引数: systemctl を呼ばずに終了コード 2 で終わる
h="${work}/t11"
place_unit "${h}"
run "${h}" --dry-run
if [[ $(rc "${h}") == 2 && ! -e ${h}/calls ]]; then
  ok "知らない引数では systemctl を呼ばずに終了コード 2 で終わる"
else
  ng "知らない引数" "$(detail "${h}")"
fi

# 12. setup の手順の並び: bootstrap-claude-skills・bootstrap-herdr-hub より後に来る。使い捨ての checkout に setup.sh と
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
