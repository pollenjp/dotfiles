#!/usr/bin/env bash
# shellcheck shell=bash
#
# Dev Tracker のコメントの見回り役 (systemd の user service pjp-dev-tracker-inbox) を、claude-skills を進めた後に起こし直す。
# 冪等。`setup.sh --update` でも毎回走る。
#
# order: 70
#
# ^ setup.sh が読む実行順。bootstrap-claude-skills.sh (既定の 50) が claude-skills の clone を進め、bootstrap-herdr-hub.sh
#   (60) がハブ ~/h を作った後に走らせる (unit は ticket.sh と ~/h が無ければ起動を飛ばす)。仕組みは nix/README.md
#   「bootstrap の実行順」。
#
# ## 何のために
#
# 見回り役の本体 (`~/.claude/skills/pjp-dev-tracker/scripts/ticket.sh inbox`) は claude-skills の作業クローンにあり、unit
# (home/modules/dev-tracker-inbox.nix) は Nix が置く。claude-skills を進めても unit ファイルは変わらないので、switch は
# 見回り役を再起動しない。動いていれば古いコードのまま、止まっていれば止まったまま残る (inbox の無い古い ticket.sh は
# 終了コード 2 で終わり、unit はそれを再起動しない)。setup --update では switch が bootstrap-claude-skills.sh より先に
# 走るので、初めて入れるときも、switch が起こした見回り役は古い clone で止まりうる。
#
# ## 何をするか
#
# unit が置かれている (dotfiles.claude.devTracker.inbox.enable のマシン) なら、daemon-reload の後に reset-failed で失敗の
# 記録と起動の回数を消し、restart する (止まっていれば起こす)。起こしてから 3 秒のうちに止まったら、今回の起動の journal の
# 末尾を添えて警告する。unit が置かれていないマシンでは何もしない。
#
# ## 止まらない
#
# setup.sh は手順が 1 つ失敗すると残りを走らせないので、ここでは exit 1 しない。
#
#   unit が置かれていない              このマシンでは使わない (option が false)。1 行出して通す
#   systemd の user session が無い      unit はあるのに起こせない。警告して通す
#   ticket.sh か ~/h が無い             unit の条件で起動が飛ぶ。option で使うと決めたマシンなのに見回り役が動かないので、
#                                       どちらが無いかと直し方を警告して通す (claude-skills の側で skill の名前や場所が変わった
#                                       ときも、黙って飛ばすと気付けない。bootstrap-herdr-hub.sh と同じ考え方)
#   restart に失敗した・すぐに止まった  警告して通す (終了コード 2 は設定の誤りか、ticket.sh に inbox がまだ無い)

set -eu -o pipefail

unit="pjp-dev-tracker-inbox.service"
# home-manager が置く unit ファイル。置かれていれば、このマシンは dotfiles.claude.devTracker.inbox.enable
unit_file="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user/${unit}"
# unit が起動の条件に見るもの (home/modules/dev-tracker-inbox.nix の ConditionPathExists・ConditionPathIsDirectory と合わせる)
ticket_sh="${HOME}/.claude/skills/pjp-dev-tracker/scripts/ticket.sh"
hub="${HOME}/h"

usage() {
  cat <<'EOS'
Dev Tracker のコメントの見回り役 (systemd の user service pjp-dev-tracker-inbox) を、claude-skills を進めた後に起こし直す。

使い方:
  bootstrap-dev-tracker-inbox.sh              unit があれば reset-failed して restart する
  bootstrap-dev-tracker-inbox.sh -h, --help   これ

unit を置くのは home-manager (dotfiles.claude.devTracker.inbox.enable のマシンだけ)。置かれていなければ何もしない。
起こせなくても、起こした見回り役がすぐに止まっても、警告を出して正常終了する (setup の後ろの手順を止めない)。
状態は systemctl --user status pjp-dev-tracker-inbox、ログは journalctl --user -u pjp-dev-tracker-inbox。
EOS
}

# 手順を止めない警告を出す。引数は 1 つが 1 行で、2 つ目からは字下げした続きの行になる。
# setup.sh から走るときは、最後の「警告のまとめ」にも同じ行を残す (summary_warn)。
warn() {
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  printf '!! %s\n' "${text//${nl}/${nl}   }" >&2
  summary_warn "$@"
}

# setup.sh の最後の「警告のまとめ」にだけ警告を残す (その場には出さない。引数は warn と同じ)。
# setup.sh が手順ごとに DOTFILES_SETUP_WARNINGS でファイルを渡す。単体で流したときは何もしない。
summary_warn() {
  [[ -n ${DOTFILES_SETUP_WARNINGS-} ]] || return 0
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  { printf '%s\n' "${text//${nl}/${nl}   }" >>"${DOTFILES_SETUP_WARNINGS}"; } 2>/dev/null || true
}

# unit の今の状態を読み、active・sub・result・status・condition に入れる。読めなければ空のまま
unit_state() {
  local line listed
  active="" sub="" result="" status="" condition=""
  listed=$(systemctl --user show "${unit}" -p ActiveState -p SubState -p Result -p ExecMainStatus -p ConditionResult \
    2>/dev/null </dev/null) || return 0
  while IFS= read -r line; do
    case ${line} in
      ActiveState=*) active=${line#*=} ;;
      SubState=*) sub=${line#*=} ;;
      Result=*) result=${line#*=} ;;
      ExecMainStatus=*) status=${line#*=} ;;
      ConditionResult=*) condition=${line#*=} ;;
    esac
  done <<<"${listed}"
}

# 今回の起動で見回り役が出した行の末尾 (止まったわけ)。前の起動の行を混ぜないよう、InvocationID で絞る (user の unit では、
# service の出力に _SYSTEMD_INVOCATION_ID が付く)。読めなければ何も出さない
journal_tail() {
  local inv
  inv=$(systemctl --user show "${unit}" -p InvocationID --value 2>/dev/null </dev/null) || inv=""
  if [[ -z ${inv} ]]; then
    return 0
  fi
  journalctl --user "_SYSTEMD_INVOCATION_ID=${inv}" -n 5 --no-pager -o cat 2>/dev/null </dev/null || true
}

# 引数は --help だけ。--dry-run などを渡されて、起こさないつもりで起こしてしまわないよう、ほかは断る
if [[ $# -gt 0 ]]; then
  case $1 in
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'ERROR: 知らないオプション: %s  (--help)\n' "$1" >&2
      exit 2
      ;;
  esac
fi

echo "==> Dev Tracker のコメントの見回り役 (${unit})"

if [[ ! -e ${unit_file} ]]; then
  echo "unit が置かれていないので飛ばします (dotfiles.claude.devTracker.inbox.enable = false のマシンでは、これで問題ありません)。"
  exit 0
fi

# systemctl が無ければ、これも失敗する
if ! systemctl --user show-environment &>/dev/null </dev/null; then
  warn "見回り役の unit はあるのに、systemctl が無いか systemd の user session に届かないので起こせません: ${unit}" \
    "user session のあるログイン (SSH など) から、この手順だけ流し直してください: ~/dotfiles/setup --steps bootstrap-dev-tracker-inbox"
  exit 0
fi

# switch (sd-switch) が読み込み済みのはずだが、switch を通らずに unit ファイルだけ変わったときのために読み直す。
# reset-failed は、終了コード 2 の失敗や起動の回数の上限 (10 分に 5 回) の記録を消す (消さないと restart が断られうる)
systemctl --user daemon-reload </dev/null || true
systemctl --user reset-failed "${unit}" &>/dev/null </dev/null || true
echo "+ systemctl --user restart ${unit}"
rc=0
captured=$(systemctl --user restart "${unit}" 2>&1 </dev/null) || rc=$?
if ((rc != 0)); then
  warn "見回り役を起こせませんでした (systemctl --user restart の終了コード ${rc}):" \
    ${captured:+"${captured}"} \
    "状態とログ: systemctl --user status ${unit} / journalctl --user -u ${unit}"
  exit 0
fi

# 起こしてから 3 秒のうちに止まらないかを見る (終了コード 2 は、設定を読んだところですぐに出る)
unit_state
for _ in 1 2 3 4 5 6; do
  if [[ ${condition} == no || ${active} == failed || ${active} == inactive || ${sub} == auto-restart ]]; then
    break
  fi
  sleep 0.5
  unit_state
done

if [[ ${condition} == no ]]; then
  hints=()
  if [[ ! -e ${ticket_sh} ]]; then
    hints+=("ticket.sh が無い: ${ticket_sh}"
      "  claude-skills を取れていないなら bootstrap-claude-skills の警告を見る。claude-skills の側で skill の名前か場所が変わったなら、nix/home/modules/dev-tracker-inbox.nix と nix/scripts/bootstrap-dev-tracker-inbox.sh を合わせて直す")
  fi
  if [[ ! -d ${hub} ]]; then
    hints+=("ハブが無い: ${hub}" "  作るのは bootstrap-herdr-hub。その警告を見る")
  fi
  if ((${#hints[@]} == 0)); then
    hints+=("ticket.sh も ~/h も今はあるので、流し直せば起きる")
  fi
  warn "dotfiles.claude.devTracker.inbox.enable のマシンなのに、見回り役は起動の条件が揃わずに飛ばされました:" \
    "${hints[@]}" \
    "揃えたら、この手順だけ流し直す: ~/dotfiles/setup --steps bootstrap-dev-tracker-inbox"
  exit 0
fi

if [[ ${active} == active ]]; then
  echo "見回り役を起こし直しました (状態 ${active}/${sub:-?})。状態は systemctl --user status ${unit}"
  exit 0
fi

tail_lines=$(journal_tail)
if [[ ${active} == failed && ${status} == 2 ]]; then
  warn "見回り役が終了コード 2 で止まりました (設定の誤りか、claude-skills の ticket.sh に inbox がまだ無い)。再起動はしません。" \
    ${tail_lines:+"${tail_lines}"} \
    "直したら、この手順だけ流し直す: ~/dotfiles/setup --steps bootstrap-dev-tracker-inbox"
  exit 0
fi
if [[ ${active} == failed || ${active} == inactive || ${sub} == auto-restart ]]; then
  warn "見回り役が起こしてすぐに止まりました (状態 ${active}/${sub}・${result}・終了コード ${status:-?})。" \
    ${tail_lines:+"${tail_lines}"} \
    "状態とログ: systemctl --user status ${unit} / journalctl --user -u ${unit}"
  exit 0
fi
# activating など、3 秒たっても動いているとも止まったとも言えない (状態を読めなかったときも)
echo "見回り役を起こしました (状態 ${active:-?}/${sub:-?})。動いているかは systemctl --user status ${unit}"
