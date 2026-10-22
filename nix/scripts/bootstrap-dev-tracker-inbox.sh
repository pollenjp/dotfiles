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
# 記録と起動の回数を消し、restart する (止まっていれば起こす)。起こしてから 3 秒のうちに止まったら、journal の末尾を
# 添えて警告する。unit が置かれていないマシンでは何もしない。
#
# ## 止まらない
#
# setup.sh は手順が 1 つ失敗すると残りを走らせないので、ここでは exit 1 しない。
#
#   unit が置かれていない              このマシンでは使わない (option が false)。1 行出して通す
#   systemd の user session が無い      unit はあるのに起こせない。警告して通す
#   ticket.sh か ~/h が無い             unit の条件で起動が飛ぶ。claude-skills を取れないマシン・ハブがまだ無いマシンでは
#                                       正常 (取れないことは bootstrap-claude-skills.sh と bootstrap-herdr-hub.sh が警告する)
#                                       なので、1 行出して通す
#   restart に失敗した・すぐに止まった  警告して通す (終了コード 2 は設定の誤りか、ticket.sh に inbox がまだ無い)

set -eu -o pipefail

unit="pjp-dev-tracker-inbox.service"
# home-manager が置く unit ファイル。置かれていれば、このマシンは dotfiles.claude.devTracker.inbox.enable
unit_file="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user/${unit}"

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

# journal の末尾 (直したいときに見る行)。読めなければ何も出さない
journal_tail() {
  journalctl --user -u "${unit}" -n 5 --no-pager -o cat 2>/dev/null </dev/null || true
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

if ! command -v systemctl &>/dev/null || ! systemctl --user show-environment &>/dev/null </dev/null; then
  warn "見回り役の unit はあるのに、systemd の user session が無いので起こせません: ${unit}" \
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
  echo "ticket.sh かハブ ~/h が無いので、見回り役は起動を飛ばしました (claude-skills を取れないマシン・ハブがまだ無いマシンでは、これで問題ありません)。"
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
echo "見回り役を起こし直しました (状態 ${active:-?}/${sub:-?})。状態は systemctl --user status ${unit}"
