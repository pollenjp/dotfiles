#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-claude-footer-links.sh の振る舞いを、使い捨ての HOME で確かめる。
#
#   bash nix/tests/bootstrap-claude-footer-links.test.sh [<bootstrap-claude-footer-links.sh のパス>]
#
# flake の checks (bootstrap-claude-footer-links-test) が Nix のサンドボックスで流す。
# 使うのは bash・jq・coreutils だけ。正規表現そのものの当たり方は
# claude-footer-links.test.mjs (claude-footer-links-test) の側で見る。
#
# ## 確かめること
#
#   - 生成ファイルの配列を settings.json の footerLinksRegexes へ書き、他のキーは残す。
#     再実行では変わらず、別の値が入っていたら元の値を見せてから置き換える
#   - settings.json が無い / 壊れている、生成ファイルが無い / 形が違うときの扱い
#   - settings.json の隣に中間ファイルを残さない

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-claude-footer-links.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-claude-footer-links-test.XXXXXX")
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

# 生成ファイルの中身 (形だけ合わせた 2 項目。正規表現の中身はここでは問わない)
links='[{"type":"regex","pattern":"\\b(?<id>TKT-\\d+)\\b","url":"https://example.com/t/{id}","label":"{id}"},{"type":"regex","pattern":"https://github\\.com/(?<o>[^/]+)/(?<r>[^/]+)/pull/(?<n>\\d+)","url":"https://github.com/{o}/{r}/pull/{n}"}]'
old_links='[{"type":"regex","pattern":"OLD-\\d+","url":"https://example.com/old"}]'

# 1 ケースぶんの HOME を作る。$2: settings.json の中身 (空なら作らない)、$3: 生成ファイル (空なら作らない)
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.claude" "${h}/.local/state/dotfiles"
  if [[ -n $2 ]]; then printf '%s\n' "$2" >"${h}/.claude/settings.json"; fi
  if [[ -n $3 ]]; then printf '%s\n' "$3" >"${h}/.local/state/dotfiles/claude-footer-links.json"; fi
  echo "${h}"
}

run() {
  local h=$1
  env HOME="${h}" "${BASH}" "${script}" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
links_of() { jq -cS '.footerLinksRegexes' "$1/.claude/settings.json"; }
# 右辺を引用符で囲む。囲まないと == の右辺が glob になり、正規表現の [ ] で一致しなくなる。
same() { [[ $(jq -cS . <<<"$1") == "$(jq -cS . <<<"$2")" ]]; }
leftovers() { find "$1/.claude" -name 'settings.json.*' | wc -l | tr -d ' '; }

echo "== bootstrap-claude-footer-links.sh: ${script}"

# 1. 生成ファイルの配列を書き、他のキーは残す
h=$(new_home t1 '{"model":"opus","env":{"FOO":"bar"},"permissions":{"allow":["x"]}}' "${links}")
run "${h}"
if [[ $(rc "${h}") == 0 ]] && same "$(links_of "${h}")" "${links}"; then
  ok "生成ファイルの配列が footerLinksRegexes に入る"
else
  ng "生成ファイルの配列が footerLinksRegexes に入る" "rc=$(rc "${h}") err=$(cat "${h}/err")"
fi
if same "$(jq -c 'del(.footerLinksRegexes)' "${h}/.claude/settings.json")" '{"model":"opus","env":{"FOO":"bar"},"permissions":{"allow":["x"]}}'; then
  ok "settings.json の他のキーは残る"
else
  ng "settings.json の他のキーは残る" "$(jq -c . "${h}/.claude/settings.json")"
fi

# 2. 冪等: もう一度流してもファイルは変わらない
before=$(cat "${h}/.claude/settings.json")
run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "${h}/.claude/settings.json") == "${before}" ]] && grep -q '登録済み' "${h}/out"; then
  ok "2 回流しても変わらない (登録済みと出る)"
else
  ng "2 回流しても変わらない" "rc=$(rc "${h}") out=$(cat "${h}/out")"
fi

# 3. 別の値が入っていたら、元の値を見せてから丸ごと置き換える
h=$(new_home t3 "{\"footerLinksRegexes\":${old_links}}" "${links}")
run "${h}"
if [[ $(rc "${h}") == 0 ]] && same "$(links_of "${h}")" "${links}" && grep -q '置き換えます' "${h}/out" && grep -q 'OLD-' "${h}/out"; then
  ok "別の値は元の値を見せてから置き換える"
else
  ng "別の値は元の値を見せてから置き換える" "rc=$(rc "${h}") out=$(cat "${h}/out")"
fi

# 4. settings.json が無ければ作る
h=$(new_home t4 "" "${links}")
run "${h}"
if [[ $(rc "${h}") == 0 ]] && same "$(jq -c . "${h}/.claude/settings.json")" "{\"footerLinksRegexes\":${links}}"; then
  ok "settings.json が無ければ footerLinksRegexes だけの形で作る"
else
  ng "settings.json が無ければ作る" "rc=$(rc "${h}") err=$(cat "${h}/err")"
fi

# 5. 生成ファイルが無い: 警告して exit 0、settings.json は変えない
h=$(new_home t5 '{"model":"opus"}' "")
before=$(cat "${h}/.claude/settings.json")
run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "${h}/.claude/settings.json") == "${before}" ]] && grep -q 'claude-footer-links.json' "${h}/err"; then
  ok "生成ファイルが無ければ警告して飛ばす (exit 0、変更なし)"
else
  ng "生成ファイルが無ければ警告して飛ばす" "rc=$(rc "${h}") err=$(cat "${h}/err")"
fi

# 6. 生成ファイルの形が違う: exit 1、settings.json は変えない
i=0
for bad in \
  '{"type":"regex","pattern":"x","url":"https://example.com"}' \
  '[{"type":"literal","pattern":"x","url":"https://example.com"}]' \
  '[{"type":"regex","pattern":1,"url":"https://example.com"}]' \
  '[{"type":"regex","pattern":"x"}]' \
  '[{"type":"regex","pattern":"x","url":"https://example.com","label":3}]'; do
  i=$((i + 1))
  h=$(new_home "t6-${i}" '{"model":"opus"}' "${bad}")
  before=$(cat "${h}/.claude/settings.json")
  run "${h}"
  if [[ $(rc "${h}") == 1 && $(cat "${h}/.claude/settings.json") == "${before}" ]]; then
    ok "形の違う生成ファイルは書かずに落ちる: ${bad}"
  else
    ng "形の違う生成ファイルは書かずに落ちる: ${bad}" "rc=$(rc "${h}") out=$(cat "${h}/out")"
  fi
done

# 7. settings.json が壊れている: exit 1、触らない
h=$(new_home t7 '{"model":' "${links}")
run "${h}"
if [[ $(rc "${h}") == 1 && $(cat "${h}/.claude/settings.json") == '{"model":' ]] && grep -q '壊れています' "${h}/err"; then
  ok "壊れた settings.json には触らずに落ちる"
else
  ng "壊れた settings.json には触らずに落ちる" "rc=$(rc "${h}") err=$(cat "${h}/err")"
fi

# 8. 中間ファイル (settings.json.XXXXXX) を残さない
if [[ $(leftovers "${work}/t1") == 0 && $(leftovers "${work}/t3") == 0 && $(leftovers "${work}/t7") == 0 ]]; then
  ok "settings.json の隣に中間ファイルを残さない"
else
  ng "settings.json の隣に中間ファイルを残さない" "$(find "${work}" -name 'settings.json.*')"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
