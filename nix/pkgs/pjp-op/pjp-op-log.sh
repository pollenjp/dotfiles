#!/usr/bin/env bash
# shellcheck shell=bash
#
# WSL の op (pjp-op) の記録を表で見る。既定は直近 1 時間。nix/pkgs/pjp-op が bin/pjp-op-log として包む。
#
#   pjp-op-log [--since <数>(s|m|h|d)] [--all] [--json]
#
# 記録は ${XDG_STATE_HOME:-~/.local/state}/pjp-op/log.jsonl (と 1 世代前の log.1.jsonl)。op (op.sh) が 1 回の呼び出しに start と
# end の 2 行 (同じ id)、断ったときに refused、共有の承認を見つけたときに shared-approval を書く。ここでは start と end を
# 1 行にまとめ、時刻の順に並べる。end の無い start (止められた・まだ終わっていない) は「実行中か中断」。
#
# 列は 時刻・結果・秒・呼び手・理由・コマンド。表では理由とコマンドを切り、--json は切らずに 1 呼び出し 1 行の JSON で出す。
# 結果には、service account・Connect・help の呼び出しと、窓を出せなかった desktop の呼び出し (窓なし)、lock を待たずに打った
# 呼び出し (lock を待たず。パイプの先の op が lock を持ってこの出力を待っていた。op.sh の「## stdin」) の印を添える。
# 期間は始まった時刻で見る。PJP_OP_LOG_NOW (UNIX 秒) で今の時刻を変えられる (テスト用)。
# 終了コード: 0 (記録が無いときも)・2 = 使い方の誤り

set -u -o pipefail

usage_text() {
  cat <<'EOS'
使い方: pjp-op-log [--since <数>(s|m|h|d)] [--all] [--json]
  WSL の op (1Password CLI の wrapper) の記録を、始まった時刻の順に表で出します。
  --since 30m / 2h / 1d   出す期間 (既定 1h)
  --all                   残っている記録を全部出す
  --json                  1 呼び出し 1 行の JSON で出す (理由とコマンドを切らない)
EOS
}

since_arg=1h
all=0
json=0
while (($# > 0)); do
  case $1 in
    --since)
      if (($# < 2)); then
        usage_text >&2
        exit 2
      fi
      since_arg=$2
      shift 2
      ;;
    --since=*)
      since_arg=${1#--since=}
      shift
      ;;
    --all)
      all=1
      shift
      ;;
    --json)
      json=1
      shift
      ;;
    -h | --help)
      usage_text
      exit 0
      ;;
    *)
      echo "pjp-op-log: 知らない引数です: $1" >&2
      usage_text >&2
      exit 2
      ;;
  esac
done

if [[ ! ${since_arg} =~ ^([0-9]+)([smhd])$ ]]; then
  echo "pjp-op-log: --since は <数>(s|m|h|d) で書いてください: ${since_arg}" >&2
  usage_text >&2
  exit 2
fi
case ${BASH_REMATCH[2]} in
  s) unit=1 ;;
  m) unit=60 ;;
  h) unit=3600 ;;
  d) unit=86400 ;;
esac
since=$((BASH_REMATCH[1] * unit))

dir=${XDG_STATE_HOME:-${HOME}/.local/state}/pjp-op
files=()
for f in "${dir}/log.1.jsonl" "${dir}/log.jsonl"; do
  [[ ! -f ${f} ]] || files+=("${f}")
done
if ((${#files[@]} == 0)); then
  echo "記録がありません (${dir}/log.jsonl)"
  exit 0
fi

now=${PJP_OP_LOG_NOW:-$(date +%s)}
cutoff=$((now - since))
((all == 0)) || cutoff=0

# 呼び出しごとの record (start に end を重ねたもの・refused・shared-approval) を、始まった時刻の順に 1 行ずつ出す。
# JSON でない行は読み飛ばす
rows=$(jq -cnR --argjson cutoff "${cutoff}" '
  [inputs | fromjson? | objects] as $recs
  | ($recs | map(select(.event == "end" and (.id | type) == "string")) | map({key: .id, value: .}) | from_entries) as $ends
  | $recs
  | map(select((.event == "start" or .event == "refused" or .event == "shared-approval") and ((.epoch // 0) >= $cutoff)))
  | map(if .event == "start" then . + {end: $ends[.id]} else . end)
  | sort_by(.epoch)
  | .[]' "${files[@]}")

if [[ -z ${rows} ]]; then
  if ((all)); then
    echo "記録がありません (${dir}/log.jsonl)"
  else
    echo "直近 ${since_arg} の記録はありません (${dir}/log.jsonl)"
  fi
  exit 0
fi

if ((json)); then
  printf '%s\n' "${rows}"
  exit 0
fi

{
  printf '時刻\t結果\t秒\t呼び手\t理由\tコマンド\n'
  jq -r --argjson now "${now}" '
    def cut($n): if length > $n then .[0:$n] + "…" else . end;
    def cell: if . == null or . == "" then "-" else tostring end;
    def when: if (.epoch | strflocaltime("%Y-%m-%d")) == ($now | strflocaltime("%Y-%m-%d"))
      then .epoch | strflocaltime("%H:%M:%S") else .epoch | strflocaltime("%m/%d %H:%M:%S") end;
    def who: if .caller == null then null
      else (if .caller.type == "claude" then "Claude" else "人" end)
        + (if .caller.herdr == null then ""
          else " " + ((.caller.herdr.label // "") | if . == "" then "?" else . end) + " " + (.caller.herdr.pane // "") end)
        | cut(40) end;
    def kind_note: {"service-account": " (SA)", connect: " (Connect)", help: " (help)"}[.kind // ""] // "";
    def result_label: {approved: "許可", ok: "成功", denied: "拒否", timeout: "時間切れ", failed: "失敗",
      "launcher-failed": "失敗 (launcher)", interrupted: "中断"};
    def why_label: {"no-reason": "理由なし", "lock-timeout": "承認待ちが終わらない", "no-op-exe": "op.exe が無い",
      "no-powershell": "powershell.exe が無い", "no-wslpath": "wslpath が無い", "no-launcher": "launcher が無い",
      "too-long": "引数が長すぎる", interrupted: "始める前に止められた"};
    def window_note: if ((.end.window // "") | startswith("failed")) then " (窓なし)" else "" end;
    def lock_note: if .lock == "skipped" then " (lock を待たず)" else "" end;
    def command: "op " + ((.args // []) | join(" ")) | cut(60);
    if .event == "start" then
      [when,
       (if .end == null then "実行中か中断" else ((result_label[.end.result] // .end.result) + kind_note + window_note) end)
         + lock_note,
       (.end.seconds | cell), (who | cell), ((.reason // "") | cut(48) | cell), command]
    elif .event == "refused" then
      [when, "断った (" + (why_label[.why] // .why) + ")", "-", (who | cell), ((.reason // "") | cut(48) | cell), command]
    else
      [when, (if .cleared then "共有の承認を消した" else "共有の承認を消せなかった" end), "-", "-",
       (if .when == "start" then "op を打つ前に見つけた" else "op を打った後に見つけた" end), "op.exe signout"]
    end
    | @tsv' <<<"${rows}"
} | column -t -s $'\t'
