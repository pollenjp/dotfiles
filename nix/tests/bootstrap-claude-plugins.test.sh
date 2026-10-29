#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-claude-plugins.sh が公式 marketplace を登録して plugin を入れる流れと、入れられないときに setup を
# 止めないことを、使い捨ての HOME と偽の claude で確かめる。
#
#   bash nix/tests/bootstrap-claude-plugins.test.sh [<bootstrap-claude-plugins.sh のパス>]
#
# flake の checks (bootstrap-claude-plugins-test) が Nix のサンドボックスで流す。使うのは bash と coreutils の grep だけ。
#
# ## 確かめること
#
#   - marketplace (anthropics/claude-plugins-official) を登録してから、superpowers・frontend-design・playwright・
#     claude-security をこの順に <名前>@claude-plugins-official -y で入れ、plugin list を出す。claude は CLAUDE_CONFIG_DIR を
#     外して呼ぶ (claude-personal・claude-work のセッションから流しても ~/.claude に入れる)。警告は出さない
#   - 入れられない plugin があっても止めずに残りを入れ、plugin list まで流れて exit 0 する。入れられなかった plugin の名前と、
#     一覧を新しくする claude plugin marketplace update claude-plugins-official と入れ直す --steps を警告し、setup の最後の
#     まとめ (DOTFILES_SETUP_WARNINGS) にも同じ行を残す。入れられなかった plugin が 2 つなら警告も 2 つ
#   - claude が見つからなければ (PATH にも mise にも無い) 何も打たずに警告して exit 0
#   - marketplace を登録できなければ plugin を入れずに警告して exit 0
#
# 偽の claude は、受けた CLAUDE_CONFIG_DIR (無ければ <unset>) と引数を「<env>|<引数>」の形で $HOME/claude.log に 1 行ずつ
# 残す。FAKE_CLAUDE_FAIL に plugin の名前を空白区切りで渡すと、その plugin install だけ「not found in marketplace」で
# 落ちる。FAKE_MARKETPLACE_FAIL=1 なら marketplace add が落ちる。偽の claude の shebang は $BASH から作る (Nix の
# サンドボックスには /usr/bin/env が無い)。script には偽の claude だけを置いた PATH を渡す (手元の claude・mise を拾わない)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-claude-plugins.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-claude-plugins-test.XXXXXX")
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

fakebin="${work}/fake-bin"
mkdir -p "${fakebin}"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf '%s|%s\n' "${CLAUDE_CONFIG_DIR-<unset>}" "$*" >>"${HOME}/claude.log"
case "$*" in
  "plugin marketplace add "*)
    if [[ ${FAKE_MARKETPLACE_FAIL-} == 1 ]]; then
      echo "claude (偽物): marketplace を clone できませんでした" >&2
      exit 1
    fi
    ;;
  "plugin install "*)
    for f in ${FAKE_CLAUDE_FAIL-}; do
      if [[ ${3%@*} == "${f}" ]]; then
        echo "Plugin \"${f}\" not found in marketplace \"${3#*@}\"" >&2
        exit 1
      fi
    done
    ;;
esac
exit 0
EOF
} >"${fakebin}/claude"
chmod +x "${fakebin}/claude"

# 何も置かない PATH (claude も mise も無い)
emptybin="${work}/empty-bin"
mkdir -p "${emptybin}"

# $1: ケースの名前 (HOME の dir)、$2: script に渡す PATH。claude-personal のセッションから流したときと同じく
# CLAUDE_CONFIG_DIR を立て、setup から走るときと同じく警告のまとめ用のファイルを渡す。呼ぶ側の FAKE_* は偽の claude へ渡す。
# HOME を出す
run() {
  local h="${work}/$1"
  mkdir -p "${h}"
  env -i HOME="${h}" PATH="$2" CLAUDE_CONFIG_DIR="${h}/.claude-personal" DOTFILES_SETUP_WARNINGS="${h}/warnings" \
    FAKE_CLAUDE_FAIL="${FAKE_CLAUDE_FAIL-}" FAKE_MARKETPLACE_FAIL="${FAKE_MARKETPLACE_FAIL-}" \
    "${BASH}" "${script}" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
  echo "${h}"
}

detail() {
  printf 'rc=%s\n--- claude.log\n%s\n--- out\n%s\n--- err\n%s\n--- warnings\n%s' "$(cat "$1/rc")" \
    "$(cat "$1/claude.log" 2>/dev/null)" "$(cat "$1/out")" "$(cat "$1/err")" "$(cat "$1/warnings" 2>/dev/null)"
}

# 4 つとも入れようとしたときの偽の claude の控え
want_log="<unset>|plugin marketplace add anthropics/claude-plugins-official
<unset>|plugin install superpowers@claude-plugins-official -y
<unset>|plugin install frontend-design@claude-plugins-official -y
<unset>|plugin install playwright@claude-plugins-official -y
<unset>|plugin install claude-security@claude-plugins-official -y
<unset>|plugin list"

echo "== bootstrap-claude-plugins.sh: ${script}"

# 1. 通る: marketplace を登録し、4 つを順に入れて一覧を出す
h=$(run all-ok "${fakebin}")
if [[ $(cat "${h}/rc") == 0 && $(cat "${h}/claude.log") == "${want_log}" && ! -s ${h}/err && ! -e ${h}/warnings ]]; then
  ok "marketplace を登録し、claude-security を含む 4 つを CLAUDE_CONFIG_DIR を外して順に入れ、警告を出さない"
else
  ng "通るとき" "$(detail "${h}")"
fi

# 2. 1 つ入れられない: 残りを入れて最後まで流れ、名前と直し方を警告してまとめにも残す
h=$(FAKE_CLAUDE_FAIL=claude-security run one-fails "${fakebin}")
if [[ $(cat "${h}/rc") == 0 && $(cat "${h}/claude.log") == "${want_log}" ]] \
  && grep -Fxq '!! plugin を入れられませんでした: claude-security@claude-plugins-official' "${h}/err" \
  && grep -Fxq '     claude plugin marketplace update claude-plugins-official' "${h}/err" \
  && grep -Fq '/dotfiles/setup --steps bootstrap-claude-plugins で入れ直して' "${h}/err" \
  && grep -Fxq 'plugin を入れられませんでした: claude-security@claude-plugins-official' "${h}/warnings" \
  && grep -Fxq '     claude plugin marketplace update claude-plugins-official' "${h}/warnings" \
  && grep -Fq 'Claude Code を再起動すると有効になります。' "${h}/out"; then
  ok "入れられない plugin があっても残りを入れて exit 0 し、名前と直し方を警告してまとめにも残す"
else
  ng "1 つ入れられないとき" "$(detail "${h}")"
fi

# 3. 2 つ入れられない: どちらも警告する (途中の plugin が落ちても後ろを入れる)
h=$(FAKE_CLAUDE_FAIL='superpowers playwright' run two-fail "${fakebin}")
if [[ $(cat "${h}/rc") == 0 && $(cat "${h}/claude.log") == "${want_log}" ]] \
  && grep -Fxq 'plugin を入れられませんでした: superpowers@claude-plugins-official' "${h}/warnings" \
  && grep -Fxq 'plugin を入れられませんでした: playwright@claude-plugins-official' "${h}/warnings" \
  && [[ $(grep -c '^plugin を入れられませんでした: ' "${h}/warnings") == 2 ]]; then
  ok "入れられない plugin が 2 つなら、どちらも警告して後ろの plugin も入れる"
else
  ng "2 つ入れられないとき" "$(detail "${h}")"
fi

# 4. claude が無い: 何も打たずに警告して exit 0
h=$(run no-claude "${emptybin}")
if [[ $(cat "${h}/rc") == 0 && ! -e ${h}/claude.log ]] \
  && grep -Fxq '!! claude が見つかりません。プラグインの導入は飛ばします。' "${h}/err" \
  && grep -Fxq 'claude が見つかりません。プラグインの導入は飛ばします。' "${h}/warnings"; then
  ok "claude が見つからなければ何も打たずに警告して exit 0"
else
  ng "claude が無いとき" "$(detail "${h}")"
fi

# 5. marketplace を登録できない: plugin を入れずに警告して exit 0
h=$(FAKE_MARKETPLACE_FAIL=1 run marketplace-fails "${fakebin}")
if [[ $(cat "${h}/rc") == 0 && $(cat "${h}/claude.log") == "<unset>|plugin marketplace add anthropics/claude-plugins-official" ]] \
  && grep -Fxq '!! marketplace の登録に失敗しました。プラグインの導入は飛ばします。' "${h}/err" \
  && grep -Fxq 'marketplace の登録に失敗しました。プラグインの導入は飛ばします。' "${h}/warnings"; then
  ok "marketplace を登録できなければ plugin を入れずに警告して exit 0"
else
  ng "marketplace を登録できないとき" "$(detail "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
