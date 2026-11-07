#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016 # 単引用の中の $now などは jq の変数
#
# nix/pkgs/pjp-op/pjp-op-log.sh (WSL の op の記録を表で見る) を、作り物の記録で確かめる。
#
#   bash nix/tests/pjp-op-log.test.sh [<pjp-op-log.sh のパス>]
#
# flake の checks (pjp-op-log-test) が Nix のサンドボックスで流す。使うのは bash・coreutils・jq・column (util-linux)。
#
# ## 確かめること
#
#   期間
#     - 既定は直近 1 時間に始まった呼び出しだけを出し、61 分前のものは出さない
#     - --since 2h は 61 分前も出し、--all は 1 世代前の log.1.jsonl の分も出す
#   行
#     - start と end を 1 行にまとめ、結果 (許可・拒否・時間切れ・成功)・秒を出す。service account は「成功 (SA)」
#     - end の無い start は「実行中か中断」、refused は「断った (理由なし)」、shared-approval は「共有の承認を消した」
#     - 呼び手は Claude / 人 と herdr の label・pane、理由は日本語のまま、コマンドは op から始める
#     - 時刻は今日なら HH:MM:SS、ほかの日は MM/DD HH:MM:SS。JSON でない行は読み飛ばす
#   --json は呼び出しごとに 1 行の JSON (start に end を重ねたもの) を出す
#   記録が無い・期間に無い → そう出して 0。知らない引数・--since の誤り → 2 と使い方。-h は使い方を stdout に出して 0
#
# ## 作り
#
# 今の時刻は PJP_OP_LOG_NOW (1800000000 = 2027-01-15 08:00:00 UTC) で、時刻帯は UTC にする (サンドボックスに tzdata が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../pkgs/pjp-op/pjp-op-log.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/pjp-op-log-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

export LC_ALL=C.UTF-8 TZ=UTC0
export XDG_STATE_HOME=${work}/state
export PJP_OP_LOG_NOW=1800000000
now=${PJP_OP_LOG_NOW}
dir=${XDG_STATE_HOME}/pjp-op
mkdir -p "${dir}"

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

# rec <jq の式> [--arg …]…: 記録を 1 行にする (now を渡す)
rec() {
  local expr=$1
  shift
  jq -cn --argjson now "${now}" "$@" "${expr}"
}

claude='{type: "claude", claude_pid: 9, herdr: {workspace: "wX", label: "TKT-1 テスト", pane: "wX:p1"}, cwd: "/w", repo: "o/r", branch: "b"}'
human='{type: "human", claude_pid: null, herdr: null, cwd: "/w", repo: null, branch: null}'
{
  rec "{v: 1, id: \"a\", event: \"start\", epoch: (\$now - 600), kind: \"desktop\", caller: ${claude}, reason: \"設定を読む\", args: [\"item\", \"get\", \"x\"]}"
  rec '{v: 1, id: "a", event: "end", epoch: ($now - 590), result: "approved", exit: 0, seconds: 10}'
  rec "{v: 1, id: \"b\", event: \"start\", epoch: (\$now - 3660), kind: \"desktop\", caller: ${human}, reason: \"古い理由\", args: [\"vault\", \"list\"]}"
  rec '{v: 1, id: "b", event: "end", epoch: ($now - 3655), result: "denied", exit: 1, seconds: 5}'
  rec "{v: 1, id: \"c\", event: \"start\", epoch: (\$now - 300), kind: \"desktop\", caller: ${human}, reason: \"止めた\", args: [\"item\", \"list\"]}"
  echo 'not json'
  rec "{v: 1, id: \"d\", event: \"refused\", epoch: (\$now - 200), why: \"no-reason\", caller: ${claude}, reason: \"\", args: [\"item\", \"get\", \"y\"]}"
  rec '{v: 1, id: "e", event: "shared-approval", epoch: ($now - 100), when: "end", cleared: true}'
  rec "{v: 1, id: \"g\", event: \"start\", epoch: (\$now - 120), kind: \"service-account\", caller: ${human}, reason: \"CI\", args: [\"read\", \"op://v/i/f\"]}"
  rec '{v: 1, id: "g", event: "end", epoch: ($now - 119), result: "ok", exit: 0, seconds: 1}'
} >"${dir}/log.jsonl"
{
  rec "{v: 1, id: \"f\", event: \"start\", epoch: (\$now - 90000), kind: \"desktop\", caller: ${human}, reason: \"昨日の理由\", args: [\"whoami\"]}"
  rec '{v: 1, id: "f", event: "end", epoch: ($now - 89900), result: "timeout", exit: 1, seconds: 100}'
} >"${dir}/log.1.jsonl"

# run <名前> <引数>…: out・err・rc に入れる
run() {
  local name=$1
  shift
  rc=0
  "${BASH}" "${script}" "$@" >"${work}/${name}.out" 2>"${work}/${name}.err" || rc=$?
}

# row <名前> <文字>: 出力にその文字を含む行
row() {
  grep -F -- "$2" "${work}/$1.out"
}

echo "== 期間"
run default
out=$(<"${work}/default.out")
if [[ ${rc} == 0 && ${out} == *設定を読む* && ${out} == *止めた* && ${out} == *CI* && ${out} != *古い理由* && ${out} != *昨日の理由* ]]; then
  ok "既定は直近 1 時間だけ (61 分前は出さない)"
else
  ng "既定は直近 1 時間だけ (61 分前は出さない)" "rc=${rc} ${out}"
fi
run since --since 2h
out=$(<"${work}/since.out")
if [[ ${out} == *古い理由* && ${out} != *昨日の理由* ]]; then
  ok "--since 2h は 61 分前も出す"
else
  ng "--since 2h は 61 分前も出す" "${out}"
fi
run all --all
out=$(<"${work}/all.out")
if [[ ${out} == *昨日の理由* && $(row all 昨日の理由) == *時間切れ* ]]; then
  ok "--all は log.1.jsonl の分も出す"
else
  ng "--all は log.1.jsonl の分も出す" "${out}"
fi

echo "== 行"
a=$(row default 設定を読む)
if [[ ${a} == *許可* && ${a} == *" 10 "* && ${a} == *"Claude TKT-1 テスト wX:p1"* && ${a} == *"op item get x"* &&
  ${a} == "07:50:00 "* ]]; then
  ok "start と end を 1 行にまとめ、結果・秒・呼び手・理由・コマンド・今日の時刻 (HH:MM:SS) を出す"
else
  ng "start と end を 1 行にまとめ、結果・秒・呼び手・理由・コマンド・今日の時刻 (HH:MM:SS) を出す" "${a}"
fi
if [[ $(row since 古い理由) == *拒否* && $(row default CI) == *"成功 (SA)"* ]]; then
  ok "拒否と service account の成功 (SA)"
else
  ng "拒否と service account の成功 (SA)" "$(row since 古い理由) / $(row default CI)"
fi
if [[ $(row default 止めた) == *実行中か中断* && $(row default "op item get y") == *"断った (理由なし)"* &&
-n $(row default 共有の承認を消した) ]]; then
  ok "end の無い start は「実行中か中断」、refused・shared-approval も行にする"
else
  ng "end の無い start は「実行中か中断」、refused・shared-approval も行にする" "$(cat "${work}/default.out")"
fi
if [[ $(row all 昨日の理由) == "01/14 "* ]]; then
  ok "ほかの日の時刻は MM/DD HH:MM:SS"
else
  ng "ほかの日の時刻は MM/DD HH:MM:SS" "$(row all 昨日の理由)"
fi

echo "== --json"
run json --json
if [[ ${rc} == 0 && $(jq -s 'length' "${work}/json.out" 2>/dev/null) == 5 &&
$(jq -r 'select(.id == "a") | .end.result' "${work}/json.out" 2>/dev/null) == approved ]]; then
  ok "--json は呼び出しごとに 1 行 (start に end を重ねる)"
else
  ng "--json は呼び出しごとに 1 行 (start に end を重ねる)" "rc=${rc} $(cat "${work}/json.out")"
fi

echo "== 無いとき・引数"
PJP_OP_LOG_NOW=$((now + 864000)) run empty
if [[ ${rc} == 0 && $(<"${work}/empty.out") == *記録はありません* ]]; then
  ok "期間に記録が無ければ、そう出して 0"
else
  ng "期間に記録が無ければ、そう出して 0" "rc=${rc} $(cat "${work}/empty.out")"
fi
XDG_STATE_HOME=${work}/none run nolog
if [[ ${rc} == 0 && $(<"${work}/nolog.out") == *記録がありません* ]]; then
  ok "記録が無ければ、そう出して 0"
else
  ng "記録が無ければ、そう出して 0" "rc=${rc} $(cat "${work}/nolog.out")"
fi
run bad --no-such
rc_bad=${rc}
run badsince --since 3x
if [[ ${rc_bad} == 2 && ${rc} == 2 && $(<"${work}/badsince.err") == *使い方* ]]; then
  ok "知らない引数・--since の誤りは 2 と使い方"
else
  ng "知らない引数・--since の誤りは 2 と使い方" "bad=${rc_bad} since=${rc} $(cat "${work}/badsince.err")"
fi
run help -h
if [[ ${rc} == 0 && $(<"${work}/help.out") == *使い方* ]]; then
  ok "-h は使い方を stdout に出して 0"
else
  ng "-h は使い方を stdout に出して 0" "rc=${rc}"
fi

echo
echo "pass=${pass} fail=${fail}"
[[ ${fail} == 0 ]]
