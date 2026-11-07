#!/usr/bin/env bash
# shellcheck shell=bash
# jq の式 ($in など) を文字のまま書く所が多いので、ファイル全体で SC2016 を止める
# shellcheck disable=SC2016
#
# nix/scripts/bootstrap-windows-international.sh の振る舞いを、使い捨ての HOME と偽の checkout・偽の pwsh.exe で確かめる。
#
#   bash nix/tests/bootstrap-windows-international.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-international-test) が Nix のサンドボックスで流す。
# CI の `nix flake check` もこれを通る。使うのは bash・jq・git・coreutils・grep・sed・awk だけ。
#
# ## 確かめること
#
#   - --check は managed.json だけを見る (pwsh.exe を呼ばない)。知らない名前・文字列でない値・空・長すぎる値・
#     制御文字・object でない・ファイルが無い・jq --indent 4 の形でない、のどれでも止まる。引数の組み合わせの誤りは exit 2
#   - 配らないマシン・windows-files.json が無いときは、pwsh.exe を呼ばずに飛ばす
#   - pwsh.exe が無い・失敗する・時間切れ・決めた形の JSON を返さないときは、warn で知らせて何も書かずに exit 0。
#     pwsh.exe のエラーは平文で出す (CLIXML でも色のエスケープ付きでもない)
#   - 初めて書くマシン (記録が無く、今の値が地域の既定) では 3 つとも表の順に書き、WM_SETTINGCHANGE を送り、記録する。
#     pwsh.exe には -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand で、ASCII だけの UTF-16LE を渡す
#   - 揃っていれば読むだけで書かない (記録も変えない)。Windows がもう持つ値なら、書かずに記録だけする
#   - managed.json を変えたら (Windows が前回書いた値のまま)、衝突でない値を全部表の順に書き直し、変わった値だけを出す
#   - 記録が無く地域の既定とも違う値・前回書いた値から変わった値・地域の既定に戻った値は、衝突として触らず、
#     値と解き方を出して exit 1。衝突しない値は書く。--force なら書く
#   - --dry-run は読むだけで、Windows も記録も変えない (衝突があれば exit 1)
#   - --import は衝突した値を managed.json へ取り込み (jq --indent 4 の形)、Windows には書かない。衝突が無ければ何も
#     取り込まない。managed.json に commit していない変更があるとき・git の checkout でないときは止まる
#   - 書けない値・書いても読み戻すと違う値・書く途中の pwsh.exe の失敗は、⚠ で出して exit 1。書く行にもそう出し、
#     記録は書けた値だけ。グループポリシーで止められている値 (1260) は、流し直しても書けないので warn で知らせて
#     exit 0。WM_SETTINGCHANGE を送れないときも warn で知らせて exit 0
#   - 日本語や ' を含む形式も、そのまま届いて読み戻せる
#   - managed.json から消した値は、Windows では戻さず、記録からだけ消す。壊れた記録では止まる。持つ値が無ければ
#     pwsh.exe を呼ばない
#   - setup から走るとき (DOTFILES_SETUP_WARNINGS がある) は、exit 0 で続ける警告を setup の最後のまとめ用の
#     ファイルにも残す
#
# ## 偽の checkout と偽の pwsh.exe
#
# script は自分のいる checkout の win/international/managed.json を読むので、ケースごとに <ケース>/repo/nix/scripts/ へ
# 写して流す。要るコマンドだけを symlink で並べた PATH で流し、本物の pwsh.exe と Windows には触らない。出力は
# <ケース>/stdout と <ケース>/stderr に残し、grep には直にファイルを渡す (パイプの grep -q は、pipefail の下で
# SIGPIPE を拾って落ちることがある。CI の nix/scripts/check-test-grep-q.sh が見る)。
#
# 偽の pwsh.exe (<HOME>/bin/pwsh.exe) は、-EncodedCommand の中身を UTF-16LE として読み戻し、先頭の $Mode と
# $InputJson を取り出して、<HOME>/fake-windows.json に持たせた Windows の状態から本物と同じ形の JSON を CRLF で返す。
# write なら状態を書き換える (deny の値は Win32 のエラーで失敗させ、stuck の値は成功を返して変えない)。渡された
# コードが ASCII の UTF-16LE でなければ <HOME>/bad-encoding を作る。呼ばれた mode を <HOME>/pwsh-modes に、書いた
# 値の名前を書いた順に <HOME>/writes に、最後の引数を除いた引数を <HOME>/pwsh-args に 1 行ずつ残す。shebang は
# $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-international.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-international-test.XXXXXX")
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

# 要るコマンドだけを並べた PATH (script と偽の pwsh.exe が使うもの。pwsh.exe は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in jq git cat mkdir mktemp mv cp rm date sort sed cmp dirname od base64 tr timeout awk; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# 持つ値 (jq --indent 4 の形)。引数は「名前=値」を並べる。無ければ repo と同じ 3 つ
managed_json() {
  if (($# == 0)); then
    set -- sShortDate=yyyy-MM-dd sTimeFormat=HH:mm:ss sShortTime=HH:mm
  fi
  printf '%s\n' "$@" | jq -R 'capture("^(?<k>[^=]*)=(?<v>.*)$")' | jq -s --indent 4 'map({(.k): .v}) | add // {}'
}

# 偽の Windows の状態 (en-US の既定のまま。この PC で 2026-11-07 に読んだ値)
fake_windows() {
  jq -n '{
    locale: "en-US",
    values: {
      sShortDate: {current: "M/d/yyyy", default: "M/d/yyyy"},
      sTimeFormat: {current: "h:mm:ss tt", default: "h:mm:ss tt"},
      sShortTime: {current: "h:mm tt", default: "h:mm tt"}
    },
    deny: {},
    stuck: [],
    broadcast_error: 0
  }'
}

# 偽の pwsh.exe を $1 に作る (上の「偽の checkout と偽の pwsh.exe」)
make_fake_pwsh() {
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
set -u -o pipefail
st="${HOME}/fake-windows.json"
args=("$@")
enc=${args[-1]}
unset 'args[-1]'
printf '%s\n' "${args[*]}" >>"${HOME}/pwsh-args"
# エラーの出し方は本物に合わせる: -EncodedCommand で起動すると、-OutputFormat Text が無ければ CLIXML、あれば
# 色のエスケープの付いた平文 (2026-11-07 にこの PC の pwsh 7.6.9 で確かめた)
emit_err() {
  if [[ " ${args[*]} " == *" -OutputFormat Text "* ]]; then
    printf '\e[31;1m%s\e[0m\n' "$1" >&2
  else
    printf '#< CLIXML\n<Objs Version="1.1.0.1"><S S="Error">_x001B_[31;1m%s_x001B_[0m_x000D__x000A_</S></Objs>' "$1" >&2
  fi
}
if [[ -n ${FAKE_PWSH_RC-} ]]; then
  emit_err "${FAKE_PWSH_ERR-}"
  exit "${FAKE_PWSH_RC}"
fi
# ASCII の UTF-16LE か (奇数番目の byte が 0x80 より小さく、偶数番目が 0。byte の数は偶数)
if ! base64 -d <<<"${enc}" | od -An -v -tx1 | tr -s ' \n' '\n' | sed '/^$/d' \
  | awk 'NR % 2 == 0 && $0 != "00" { bad = 1 } NR % 2 == 1 && $0 >= "80" { bad = 1 } END { exit (bad || NR % 2) }'; then
  touch "${HOME}/bad-encoding"
fi
code=$(base64 -d <<<"${enc}" | tr -d '\0')
mode=""
input=""
while IFS= read -r line; do
  case ${line} in
    "\$Mode = '"*)
      mode=${line#"\$Mode = '"}
      mode=${mode%"'"}
      ;;
    "\$InputJson = '"*)
      input=${line#"\$InputJson = '"}
      input=${input%"'"}
      input=${input//"''"/"'"}
      ;;
  esac
done <<<"${code}"
printf '%s\n' "${mode}" >>"${HOME}/pwsh-modes"
if [[ ${mode} == write && -n ${FAKE_PWSH_WRITE_RC-} ]]; then
  emit_err "write failed"
  exit "${FAKE_PWSH_WRITE_RC}"
fi
if [[ -n ${FAKE_PWSH_RAW-} ]]; then
  printf '%s\r\n' "${FAKE_PWSH_RAW}"
  exit 0
fi
result=$(jq -c --argjson in "${input}" --arg mode "${mode}" '
  . as $s
  | [$in[] | select($mode == "write" and .write)] as $w
  | [$w[] | .name as $n | select($s.deny | has($n)) | {name, error: $s.deny[$n]}] as $failed
  | (reduce ($w[] | .name as $n | select(($s.deny | has($n)) | not) | select($n | IN($s.stuck[]) | not)) as $e
      ($s; .values[$e.name].current = $e.value)) as $new
  | {
      state: $new,
      reply: {
        locale: $new.locale,
        values: [$in[] | {name, current: $new.values[.name].current, default: $new.values[.name].default}],
        failed: $failed,
        broadcast: (if ($w | length) > ($failed | length)
          then {ok: ($s.broadcast_error == 0), error: $s.broadcast_error} else null end)
      }
    }' "${st}") || exit 1
jq '.state' <<<"${result}" >"${st}.tmp" && mv "${st}.tmp" "${st}"
if [[ ${mode} == write ]]; then
  jq -r '.[] | select(.write) | .name' <<<"${input}" >>"${HOME}/writes"
fi
printf '%s\r\n' "$(jq -c '.reply' <<<"${result}")"
EOF
  } >"$1"
  chmod +x "$1"
}

# 1 ケースぶんを作る。$1: 名前
new_case() {
  local c="${work}/$1"
  mkdir -p "${c}/home/.local/state/dotfiles" "${c}/home/bin" "${c}/repo/nix/scripts" "${c}/repo/win/international"
  cp "${script}" "${c}/repo/nix/scripts/bootstrap-windows-international.sh"
  jq -n --arg home "${c}/win" '{enable: true, version: 1, windowsHome: $home}' \
    >"${c}/home/.local/state/dotfiles/windows-files.json"
  managed_json >"${c}/repo/win/international/managed.json"
  fake_windows >"${c}/home/fake-windows.json"
  make_fake_pwsh "${c}/home/bin/pwsh.exe"
  echo "${c}"
}

managed() { printf '%s' "$1/repo/win/international/managed.json"; }
record() { printf '%s' "$1/home/.local/state/dotfiles/windows-international.applied.json"; }
# Windows の今の値。$1: ケース、$2: 名前
win() { jq -r --arg n "$2" '.values[$n].current' "$1/home/fake-windows.json"; }
# 記録の値 (無ければ (無い))。$1: ケース、$2: 名前
rec() { jq -r --arg n "$2" '.values[$n] // "(無い)"' "$(record "$1")" 2>/dev/null || echo "(記録なし)"; }
# 偽の Windows の状態を jq で書き換える。$1: ケース、残り: jq の引数 (最後が式)
fake_edit() {
  local f="$1/home/fake-windows.json"
  shift
  jq "$@" "${f}" >"${f}.tmp" && mv "${f}.tmp" "${f}"
}
# 今の値を変える (設定画面で変えたまね)。$1: ケース、$2: 名前、$3: 値
set_win() { fake_edit "$1" --arg n "$2" --arg v "$3" '.values[$n].current = $v'; }
# 呼ばれた mode を , でつないで出す (呼ばれていなければ空)
modes() {
  if [[ -e $1/home/pwsh-modes ]]; then
    tr '\n' ',' <"$1/home/pwsh-modes"
  fi
}
# 3 つとも持つ値か
all_want() {
  [[ $(win "$1" sShortDate) == yyyy-MM-dd && $(win "$1" sTimeFormat) == HH:mm:ss && $(win "$1" sShortTime) == HH:mm ]]
}
# managed.json を commit した git の checkout にする
git_init() {
  git -C "$1/repo" init -q
  git -C "$1/repo" add win
  git -C "$1/repo" -c user.name=test -c user.email=test@example.com commit -qm init
}

# $1: ケース、残り: script の引数。環境変数は呼び出し側で付ける
run() {
  local c=$1
  shift
  env HOME="${c}/home" PATH="${c}/home/bin:${sys_bin}" "${BASH}" "${c}/repo/nix/scripts/bootstrap-windows-international.sh" "$@" \
    >"${c}/stdout" 2>"${c}/stderr"
  echo $? >"${c}/rc"
}
rc() { cat "$1/rc"; }
outerr() { cat "$1/stdout" "$1/stderr"; }
# 出力 (stdout か stderr) に $2 があるか
has() { grep -qF -- "$2" "$1/stdout" "$1/stderr"; }
# 偽の pwsh.exe が呼ばれたか
called() { [[ -e $1/home/pwsh-modes ]]; }

echo "== bootstrap-windows-international.sh: ${script}"

# c1. 3 つの値: OK。pwsh.exe は呼ばない
c=$(new_case c1)
run "${c}" --check
if [[ $(rc "${c}") == 0 ]] && has "${c}" 'win/international/managed.json: OK (持つ値 3 件)' && ! called "${c}"; then
  ok "--check は 3 つの値の managed.json を通し、pwsh.exe を呼ばない"
else
  ng "--check (3 つの値)" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# c2. 知らない名前
c=$(new_case c2)
managed_json sShortDate=yyyy-MM-dd 'sLongDate=dddd, MMMM d, yyyy' >"$(managed "${c}")"
run "${c}" --check
if [[ $(rc "${c}") == 1 ]] && has "${c}" '知らない名前です: sLongDate'; then
  ok "--check は知らない名前で止まる"
else
  ng "--check (知らない名前)" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# c3. 値の誤り: 文字列でない・空・長すぎる・制御文字
check_bad_value() {
  local label=$1 json=$2 want=$3
  c=$(new_case "c3-${label}")
  jq --indent 4 . <<<"${json}" >"$(managed "${c}")"
  run "${c}" --check
  if [[ $(rc "${c}") == 1 ]] && has "${c}" "${want}"; then
    ok "--check は値の誤り (${label}) で止まる"
  else
    ng "--check (${label})" "rc=$(rc "${c}") $(outerr "${c}")"
  fi
}
check_bad_value number '{"sShortDate": 1}' 'sShortDate の値が文字列ではありません'
check_bad_value empty '{"sShortDate": ""}' 'sShortDate の値が空です'
check_bad_value long "$(jq -n '{sShortDate: ([range(80)] | map("y") | join(""))}')" 'sShortDate の値が長すぎます (80 字。79 字まで)'
check_bad_value control '{"sShortTime": "HH:\tmm"}' 'sShortTime の値に制御文字があります'

# c4. object でない・ファイルが無い
c=$(new_case c4-array)
echo '[]' >"$(managed "${c}")"
run "${c}" --check
if [[ $(rc "${c}") == 1 ]] && has "${c}" 'JSON の object ではありません'; then
  ok "--check は object でない managed.json で止まる"
else
  ng "--check (object でない)" "rc=$(rc "${c}") $(outerr "${c}")"
fi
c=$(new_case c4-missing)
rm -f "$(managed "${c}")"
run "${c}" --check
if [[ $(rc "${c}") == 1 ]] && has "${c}" 'win/international/managed.json がありません'; then
  ok "--check は managed.json が無ければ止まる"
else
  ng "--check (ファイルが無い)" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# c5. 中身は正しいが jq --indent 4 の形でない
c=$(new_case c5)
jq -c . <<<"$(managed_json)" >"$(managed "${c}")"
run "${c}" --check
if [[ $(rc "${c}") == 1 ]] && has "${c}" 'jq --indent 4 の出力と違います' && has "${c}" 'jq --indent 4 . win/international/managed.json'; then
  ok "--check は jq --indent 4 の形でない managed.json で止まり、整えるコマンドを出す"
else
  ng "--check (形)" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# a1. 引数の組み合わせの誤り・知らない引数
c=$(new_case a1)
bad_args=0
for args in '--check --force' '--check --dry-run' '--import --force' '--import --dry-run' '--bogus'; do
  # shellcheck disable=SC2086  # 引数を語に分けて渡す
  run "${c}" ${args}
  if [[ $(rc "${c}") != 2 ]]; then
    bad_args=1
    ng "引数 ${args} が exit 2 にならない" "rc=$(rc "${c}") $(outerr "${c}")"
  fi
done
if ((bad_args == 0)); then
  ok "引数の組み合わせの誤りと知らない引数は exit 2"
fi

# t1. windows-files.json が無い: 飛ばす
c=$(new_case t1)
rm -f "${c}/home/.local/state/dotfiles/windows-files.json"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && has "${c}" '飛ばします' && ! called "${c}" && [[ ! -e $(record "${c}") ]]; then
  ok "windows-files.json が無ければ pwsh.exe を呼ばずに飛ばす"
else
  ng "windows-files.json が無いとき" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# t2. 配らないマシン
c=$(new_case t2)
jq -n '{enable: false, version: 1, windowsHome: null}' >"${c}/home/.local/state/dotfiles/windows-files.json"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && has "${c}" '配りません' && ! called "${c}"; then
  ok "enable = false のマシンでは何もしない"
else
  ng "配らないマシン" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# t3. pwsh.exe が無い: warn で知らせて exit 0
c=$(new_case t3)
rm -f "${c}/home/bin/pwsh.exe"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && has "${c}" '!! pwsh.exe が見つかりません' && [[ ! -e $(record "${c}") ]] \
  && [[ $(win "${c}" sShortDate) == M/d/yyyy ]]; then
  ok "pwsh.exe が無ければ warn で知らせて何も書かない (exit 0)"
else
  ng "pwsh.exe が無いとき" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# t4. pwsh.exe が失敗する・時間切れ: warn で知らせて exit 0
c=$(new_case t4)
FAKE_PWSH_RC=1 FAKE_PWSH_ERR='Add-Type: boom' run "${c}"
if [[ $(rc "${c}") == 0 ]] && has "${c}" '!! pwsh.exe で Windows の日付と時刻の形式を読めませんでした (終了コード 1' \
  && has "${c}" 'Add-Type: boom' && ! has "${c}" 'CLIXML' && ! grep -q $'\e' "${c}/stdout" "${c}/stderr" \
  && [[ ! -e $(record "${c}") ]]; then
  ok "pwsh.exe が失敗したら、その出力を平文 (CLIXML でも色のエスケープ付きでもない) で添えて warn で知らせる (exit 0)"
else
  ng "pwsh.exe が失敗するとき" "rc=$(rc "${c}") $(outerr "${c}")"
fi
c=$(new_case t4-timeout)
FAKE_PWSH_RC=124 run "${c}"
if [[ $(rc "${c}") == 0 ]] && has "${c}" '!! pwsh.exe が 60 秒たっても終わりませんでした' && [[ ! -e $(record "${c}") ]]; then
  ok "pwsh.exe の時間切れも warn で知らせる (exit 0)"
else
  ng "pwsh.exe の時間切れ" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# t5. 決めた形の JSON を返さない
c=$(new_case t5)
FAKE_PWSH_RAW='oops' run "${c}"
if [[ $(rc "${c}") == 0 ]] && has "${c}" '!! pwsh.exe の返りが、決めた形の JSON ではありません' && has "${c}" 'oops' \
  && [[ ! -e $(record "${c}") ]]; then
  ok "pwsh.exe が決めた形の JSON を返さなければ warn で知らせる (exit 0)"
else
  ng "JSON でない返り" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# t6. 初めて書くマシン: 3 つとも表の順に書き、WM_SETTINGCHANGE を送り、記録する
c=$(new_case t6)
run "${c}"
recorded=$(jq -S -c '.values' "$(record "${c}")" 2>/dev/null)
want=$(jq -S -c . "$(managed "${c}")")
writes=$(tr '\n' ',' <"${c}/home/writes" 2>/dev/null)
if [[ $(rc "${c}") == 0 ]] && all_want "${c}" && [[ ${recorded} == "${want}" && $(modes "${c}") == read,write, ]] \
  && [[ ${writes} == sShortDate,sTimeFormat,sShortTime, ]] \
  && has "${c}" '==> Windows の日付と時刻の形式 (地域 en-US)' \
  && has "${c}" 'sShortDate: "M/d/yyyy" → "yyyy-MM-dd" (初めて書く。今の値は地域の既定)' \
  && has "${c}" 'sShortTime: "h:mm tt" → "HH:mm" (初めて書く。今の値は地域の既定)' \
  && has "${c}" 'WM_SETTINGCHANGE (intl) を送りました'; then
  ok "初めて書くマシンでは 3 つとも表の順に書き、WM_SETTINGCHANGE を送り、記録する"
else
  ng "初めて書く" "rc=$(rc "${c}") modes=$(modes "${c}") writes=${writes} recorded=${recorded} $(outerr "${c}")"
fi
if [[ ! -e ${c}/home/bad-encoding ]] \
  && [[ $(sort -u "${c}/home/pwsh-args") == '-NoProfile -NonInteractive -OutputFormat Text -EncodedCommand' ]]; then
  ok "pwsh.exe には -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand で、ASCII だけの UTF-16LE を渡す"
else
  ng "pwsh.exe の引数と中身" "bad-encoding=$([[ -e ${c}/home/bad-encoding ]] && echo yes) args=$(cat "${c}/home/pwsh-args")"
fi

# t7. もう一度流す: 読むだけ。記録も変えない
cp "$(record "${c}")" "${c}/record-before"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && has "${c}" 'Windows の日付と時刻の形式は揃っています (持つ値 3 件。地域 en-US)' \
  && [[ $(modes "${c}") == read,write,read, ]] && cmp -s "${c}/record-before" "$(record "${c}")"; then
  ok "揃っていれば読むだけで書かず、記録も変えない"
else
  ng "揃っているとき" "rc=$(rc "${c}") modes=$(modes "${c}") $(outerr "${c}")"
fi

# t8. 記録が無く、Windows がもう持つ値: 書かずに記録だけ
c=$(new_case t8)
fake_edit "${c}" '.values.sShortDate.current = "yyyy-MM-dd" | .values.sTimeFormat.current = "HH:mm:ss" | .values.sShortTime.current = "HH:mm"'
run "${c}"
if [[ $(rc "${c}") == 0 ]] && [[ $(modes "${c}") == read, ]] && [[ $(rec "${c}" sShortDate) == yyyy-MM-dd ]] \
  && [[ $(rec "${c}" sShortTime) == HH:mm ]] && has "${c}" '揃っています'; then
  ok "Windows がもう持つ値なら、書かずに記録だけする"
else
  ng "もう持つ値" "rc=$(rc "${c}") modes=$(modes "${c}") $(outerr "${c}")"
fi

# t9. managed.json を変えた (Windows は前回書いた値のまま): 書き換え、変わった値だけを出す
c=$(new_case t9)
run "${c}"
managed_json sShortDate=yyyy-MM-dd sTimeFormat=HH:mm:ss sShortTime=H:mm >"$(managed "${c}")"
run "${c}"
writes=$(tr '\n' ',' <"${c}/home/writes" 2>/dev/null)
if [[ $(rc "${c}") == 0 && $(win "${c}" sShortTime) == H:mm && $(rec "${c}" sShortTime) == H:mm ]] \
  && has "${c}" 'sShortTime: "HH:mm" → "H:mm" (managed.json が更新された)' \
  && ! grep -qF 'sShortDate:' "${c}/stdout" \
  && [[ ${writes} == sShortDate,sTimeFormat,sShortTime,sShortDate,sTimeFormat,sShortTime, ]]; then
  ok "managed.json を変えたら、衝突でない値を全部表の順に書き直し、変わった値だけを出す"
else
  ng "managed.json の更新" "rc=$(rc "${c}") win=$(win "${c}" sShortTime) $(outerr "${c}")"
fi

# t10. 記録が無く、地域の既定とも違う値: 衝突。ほかの値は書く
c=$(new_case t10)
set_win "${c}" sShortDate 'yyyy/MM/dd'
run "${c}"
if [[ $(rc "${c}") == 1 && $(win "${c}" sShortDate) == yyyy/MM/dd && $(win "${c}" sTimeFormat) == HH:mm:ss ]] \
  && [[ $(win "${c}" sShortTime) == HH:mm && $(rec "${c}" sShortDate) == '(無い)' && $(rec "${c}" sShortTime) == HH:mm ]] \
  && has "${c}" '!! 衝突: sShortDate は、書いた記録が無く、地域 (en-US) の既定とも違います' \
  && has "${c}" 'Windows 側:    "yyyy/MM/dd"' && has "${c}" 'managed.json:  "yyyy-MM-dd"' \
  && has "${c}" '地域の既定:    "M/d/yyyy"' \
  && has "${c}" 'bootstrap-windows-international.sh --import' && has "${c}" 'bootstrap-windows-international.sh --force'; then
  ok "記録が無く地域の既定とも違う値は衝突として触らず、ほかの値は書く (exit 1)"
else
  ng "記録の無い衝突" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# t13. --force: 衝突も書く
run "${c}" --force
if [[ $(rc "${c}") == 0 ]] && all_want "${c}" && [[ $(rec "${c}" sShortDate) == yyyy-MM-dd ]] \
  && has "${c}" 'sShortDate: "yyyy/MM/dd" → "yyyy-MM-dd" (--force)'; then
  ok "--force は衝突した値も書く"
else
  ng "--force" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# t11. 前回書いた値から変わった: 衝突
c=$(new_case t11)
run "${c}"
set_win "${c}" sShortDate 'yyyy/MM/dd'
run "${c}"
if [[ $(rc "${c}") == 1 && $(win "${c}" sShortDate) == yyyy/MM/dd ]] \
  && has "${c}" '!! 衝突: sShortDate は Windows 側で変わっています' && has "${c}" '前回書いた値:  "yyyy-MM-dd"'; then
  ok "前回書いた値から変わった値は衝突として触らない (exit 1)"
else
  ng "前回書いた値からの変化" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# t12. 地域を変えた (今の値が新しい地域の既定に戻った): 衝突
c=$(new_case t12)
run "${c}"
fake_edit "${c}" '.locale = "ja-JP" | .values = {
  sShortDate: {current: "yyyy/MM/dd", default: "yyyy/MM/dd"},
  sTimeFormat: {current: "H:mm:ss", default: "H:mm:ss"},
  sShortTime: {current: "H:mm", default: "H:mm"}}'
run "${c}"
if [[ $(rc "${c}") == 1 && $(win "${c}" sShortDate) == yyyy/MM/dd && $(modes "${c}") == read,write,read, ]] \
  && has "${c}" '!! 衝突: sShortDate は、前回書いた値から地域 (ja-JP) の既定に戻っています'; then
  ok "地域の既定に戻った値は、黙って書かずに衝突にする (exit 1)"
else
  ng "地域の既定に戻ったとき" "rc=$(rc "${c}") modes=$(modes "${c}") $(outerr "${c}")"
fi

# t14. --dry-run: 読むだけで、Windows も記録も変えない
c=$(new_case t14)
run "${c}" --dry-run
if [[ $(rc "${c}") == 0 && $(modes "${c}") == read, && $(win "${c}" sShortDate) == M/d/yyyy && ! -e $(record "${c}") ]] \
  && has "${c}" '[dry-run] sShortDate: "M/d/yyyy" → "yyyy-MM-dd"' && ! has "${c}" 'WM_SETTINGCHANGE'; then
  ok "--dry-run は読むだけで、Windows も記録も変えない"
else
  ng "--dry-run" "rc=$(rc "${c}") modes=$(modes "${c}") $(outerr "${c}")"
fi
set_win "${c}" sShortDate 'yyyy/MM/dd'
run "${c}" --dry-run
if [[ $(rc "${c}") == 1 && $(modes "${c}") == read,read, && ! -e $(record "${c}") ]] && has "${c}" '!! 衝突: sShortDate'; then
  ok "--dry-run でも衝突があれば exit 1 (書かない)"
else
  ng "--dry-run の衝突" "rc=$(rc "${c}") modes=$(modes "${c}") $(outerr "${c}")"
fi

# t15. --import: 衝突した値を managed.json へ取り込み、Windows には書かない
c=$(new_case t15)
set_win "${c}" sShortDate 'yyyy/MM/dd'
git_init "${c}"
run "${c}" --import
if [[ $(rc "${c}") == 0 && $(jq -r '.sShortDate' "$(managed "${c}")") == yyyy/MM/dd && $(rec "${c}" sShortDate) == yyyy/MM/dd ]] \
  && jq --indent 4 . "$(managed "${c}")" | cmp -s - "$(managed "${c}")" \
  && [[ $(modes "${c}") == read, && $(win "${c}" sShortTime) == 'h:mm tt' ]] \
  && has "${c}" 'Windows の値を win/international/managed.json へ取り込みました' \
  && has "${c}" 'managed.json の値で Windows へ書く値が 2 件あります'; then
  ok "--import は衝突した値を managed.json へ取り込み (jq --indent 4 の形)、Windows には書かない"
else
  ng "--import" "rc=$(rc "${c}") modes=$(modes "${c}") $(outerr "${c}")"
fi
c=$(new_case t15-noconflict)
git_init "${c}"
cp "$(managed "${c}")" "${c}/managed-before"
run "${c}" --import
if [[ $(rc "${c}") == 0 && $(modes "${c}") == read, ]] && has "${c}" '取り込むものはありません' \
  && has "${c}" 'managed.json の値で Windows へ書く値が 3 件あります' && cmp -s "${c}/managed-before" "$(managed "${c}")"; then
  ok "--import は衝突が無ければ何も取り込まず、書く値の数を出す"
else
  ng "--import (衝突が無い)" "rc=$(rc "${c}") modes=$(modes "${c}") $(outerr "${c}")"
fi
c=$(new_case t15-dirty)
set_win "${c}" sShortDate 'yyyy/MM/dd'
git_init "${c}"
managed_json sShortDate=yyyy-MM-dd sTimeFormat=HH:mm:ss sShortTime=H:mm >"$(managed "${c}")"
cp "$(managed "${c}")" "${c}/managed-before"
run "${c}" --import
if [[ $(rc "${c}") == 1 ]] && has "${c}" 'commit していない変更があります' && cmp -s "${c}/managed-before" "$(managed "${c}")" \
  && [[ ! -e $(record "${c}") ]]; then
  ok "--import は managed.json に commit していない変更があると何も書かずに止まる"
else
  ng "--import (commit していない変更)" "rc=$(rc "${c}") $(outerr "${c}")"
fi
c=$(new_case t15-nogit)
set_win "${c}" sShortDate 'yyyy/MM/dd'
run "${c}" --import
if [[ $(rc "${c}") == 1 ]] && has "${c}" 'commit していない変更が無いかを確かめられません' \
  && [[ $(jq -r '.sShortDate' "$(managed "${c}")") == yyyy-MM-dd ]]; then
  ok "--import は git の checkout でなければ止まる"
else
  ng "--import (git でない)" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# t16. 書く途中で pwsh.exe が失敗する: ⚠ で出して exit 1。記録しない
c=$(new_case t16)
FAKE_PWSH_WRITE_RC=1 run "${c}"
if [[ $(rc "${c}") == 1 ]] && has "${c}" '書く途中で pwsh.exe が失敗しました (終了コード 1)。どの値が書けたかは分からないので、記録していません' \
  && has "${c}" 'write failed' && ! has "${c}" 'CLIXML' && ! has "${c}" '次の値は書けませんでした' \
  && has "${c}" 'sShortDate: "M/d/yyyy" → "yyyy-MM-dd" (初めて書く。今の値は地域の既定) … 書けたか分かりません' \
  && [[ ! -e $(record "${c}") ]]; then
  ok "書く途中で pwsh.exe が失敗したら ⚠ で出して exit 1 (記録せず、書く行には書けたか分からないと出す)"
else
  ng "書く途中の失敗" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# t17. 書けない値 (グループポリシーでない): ⚠ で出して exit 1。記録は書けた値だけ
c=$(new_case t17)
fake_edit "${c}" '.deny = {sShortTime: 87}'
run "${c}"
if [[ $(rc "${c}") == 1 && $(win "${c}" sShortTime) == 'h:mm tt' && $(rec "${c}" sShortTime) == '(無い)' ]] \
  && [[ $(rec "${c}" sShortDate) == yyyy-MM-dd ]] \
  && has "${c}" '次の値は書けませんでした (書けた値は記録してあります):' \
  && has "${c}" 'sShortTime: 書けませんでした (Win32 のエラー 87)' \
  && has "${c}" 'sShortTime: "h:mm tt" → "HH:mm" (初めて書く。今の値は地域の既定) … 書けませんでした' \
  && ! grep -qF 'sShortDate: "M/d/yyyy" → "yyyy-MM-dd" (初めて書く。今の値は地域の既定) …' "${c}/stdout"; then
  ok "書けない値は ⚠ で出して exit 1、記録は書けた値だけ (書く行にも書けなかったと出す)"
else
  ng "書けない値" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# t17b. グループポリシーで止められている値 (1260): 流し直しても書けないので、warn で知らせて exit 0
c=$(new_case t17b)
fake_edit "${c}" '.deny = {sShortTime: 1260}'
run "${c}"
if [[ $(rc "${c}") == 0 && $(win "${c}" sShortTime) == 'h:mm tt' && $(rec "${c}" sShortTime) == '(無い)' ]] \
  && [[ $(rec "${c}" sShortDate) == yyyy-MM-dd ]] \
  && has "${c}" '!! 次の値は、この PC ではグループポリシーで止められていて書けません (Win32 のエラー 1260): sShortTime' \
  && has "${c}" 'sShortTime: "h:mm tt" → "HH:mm" (初めて書く。今の値は地域の既定) … グループポリシーで止められていて書けません'; then
  ok "グループポリシーで止められている値は warn で知らせて exit 0 (setup を止めない)"
else
  ng "グループポリシー" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# t18. 書いても読み戻すと変わっていない値
c=$(new_case t18)
fake_edit "${c}" '.stuck = ["sShortDate"]'
run "${c}"
if [[ $(rc "${c}") == 1 && $(rec "${c}" sShortDate) == '(無い)' && $(rec "${c}" sShortTime) == HH:mm ]] \
  && has "${c}" 'sShortDate: 書いた後に読み戻すと "M/d/yyyy" で、managed.json の "yyyy-MM-dd" と違います' \
  && has "${c}" 'sShortDate: "M/d/yyyy" → "yyyy-MM-dd" (初めて書く。今の値は地域の既定) … 書けませんでした'; then
  ok "読み戻すと違う値は ⚠ で出して exit 1、記録しない"
else
  ng "読み戻すと違う値" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# t19. WM_SETTINGCHANGE を送れない: warn で知らせて exit 0
c=$(new_case t19)
fake_edit "${c}" '.broadcast_error = 1460'
run "${c}"
if [[ $(rc "${c}") == 0 ]] && all_want "${c}" && [[ $(rec "${c}" sShortTime) == HH:mm ]] \
  && has "${c}" '!! WM_SETTINGCHANGE を送れませんでした (Win32 のエラー 1460)'; then
  ok "WM_SETTINGCHANGE を送れなければ warn で知らせて exit 0 (値は書けている)"
else
  ng "WM_SETTINGCHANGE を送れない" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# t20・t21. 日本語や ' を含む形式も、そのまま届いて読み戻せる
c=$(new_case t20)
managed_json "sShortDate=yyyy'年'M'月'd'日'" sTimeFormat=HH:mm:ss "sShortTime=HH'h'mm" >"$(managed "${c}")"
run "${c}"
if [[ $(rc "${c}") == 0 && $(win "${c}" sShortDate) == "yyyy'年'M'月'd'日'" && $(win "${c}" sShortTime) == "HH'h'mm" ]] \
  && [[ $(rec "${c}" sShortDate) == "yyyy'年'M'月'd'日'" && ! -e ${c}/home/bad-encoding ]]; then
  ok "日本語や ' を含む形式も、ASCII だけのコードで届いて読み戻せる"
else
  ng "日本語や ' を含む形式" "rc=$(rc "${c}") win=$(win "${c}" sShortDate) $(outerr "${c}")"
fi

# t23. managed.json から消した値: Windows では戻さず、記録からだけ消す
c=$(new_case t23)
run "${c}"
managed_json sShortDate=yyyy-MM-dd sShortTime=HH:mm >"$(managed "${c}")"
run "${c}"
if [[ $(rc "${c}") == 0 && $(win "${c}" sTimeFormat) == HH:mm:ss && $(rec "${c}" sTimeFormat) == '(無い)' ]] \
  && [[ $(rec "${c}" sShortDate) == yyyy-MM-dd ]]; then
  ok "managed.json から消した値は Windows では戻さず、記録からだけ消す"
else
  ng "managed.json から消した値" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# t24. 壊れた記録
c=$(new_case t24)
echo '[]' >"$(record "${c}")"
run "${c}"
if [[ $(rc "${c}") == 1 ]] && has "${c}" '壊れています' && [[ $(win "${c}" sShortDate) == M/d/yyyy ]]; then
  ok "壊れた記録では何も書かずに止まる"
else
  ng "壊れた記録" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# t25. 持つ値が無い: pwsh.exe を呼ばない
c=$(new_case t25)
echo '{}' >"$(managed "${c}")"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && has "${c}" '持つ値 0 件' && ! called "${c}"; then
  ok "持つ値が無ければ pwsh.exe を呼ばない"
else
  ng "持つ値が無い" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# t26. setup から走るとき: exit 0 で続ける警告を、まとめ用のファイルにも残す
c=$(new_case t26)
rm -f "${c}/home/bin/pwsh.exe"
DOTFILES_SETUP_WARNINGS="${c}/warnings" run "${c}"
if [[ $(rc "${c}") == 0 ]] && grep -qF 'pwsh.exe が見つかりません' "${c}/warnings"; then
  ok "setup から走るときは、警告を setup の最後のまとめ用のファイルにも残す"
else
  ng "setup の警告のまとめ" "rc=$(rc "${c}") warnings=$(cat "${c}/warnings" 2>/dev/null)"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
