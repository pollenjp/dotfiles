#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-fancyzones.sh の振る舞いを、使い捨ての HOME と偽の checkout で確かめる。
#
#   bash nix/tests/bootstrap-windows-fancyzones.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-fancyzones-test) が Nix のサンドボックスで流す。
# 使うのは bash・jq・coreutils・grep・sed だけ。
#
# ## 確かめること
#
#   - 配らないマシン (windowsHome があっても)・windows-files.json が無いときは、何も書かず、警告も出さずに、理由を出して飛ばす。
#     Windows 側のホームが見えない・windowsHome が空・windows-files.json が壊れているときは、警告して exit 0
#   - 値が違えば、持つキーだけを書く。ほかのキーの値・キーの順・1 行で末尾に改行なしの形は変えず、同じディレクトリの
#     ほかのファイルにも触らない。戻したことをキーごとに 1 行出し、exit 0 (衝突にしない)。警告のまとめには残さない
#   - 隣に書いて mv した後に touch する (FancyZones は LastWriteTime の変更しか見ていないので、mv だけでは気づかない)。
#     touch が本当に mtime を進めたかも見る (偽の mv が、置き換えた後の mtime を昔へ戻す)
#   - 値が同じなら書かない (LastWriteTime も変えない)。揃っていると出す
#   - 設定画面で手で変えていても、次の回で dotfiles の値へ戻す
#   - settings.json が無ければ (ディレクトリが無くても)、持つキーと name・version だけのファイルを作る。次の回は揃っている
#   - 持つキーが settings.json に無ければ足す
#   - 持つキーはデータで決まる: managed.json にキーを足すと、script を変えずに書く (数値・文字列・ホットキーの一部も)。
#     持つ値が false でも比べて書く。managed.json から消したキーは、settings.json からは消さない
#   - 読めない (JSON でない・空・object でない) ときは、5 回読み直してから警告し、書かずに exit 0。書いている途中に
#     当たっても、読めるようになれば進む。書いている途中の空のファイルを、書くときに読んでも空で置き換えず、比べるときに
#     読んでも「揃っています」と言わない
#   - 書けないとき (途中が object でない・一時ファイルを作れない・mv できない・ディレクトリを作れない) は、元のまま警告して exit 0。
#     警告にはキーと値を出し、jq・mv の素のエラーを混ぜない。touch できないときは、書いたうえで読み直させられなかったと警告する
#   - 全体の設定で FancyZones がオフなら、書いたときも揃っているときも作ったときも、読めない・書けない・作れないときと
#     --dry-run でも警告し、まとめにも残す。全体の設定は変えない。キーやファイルが無い・true なら警告しない。読めないときは
#     確かめられないと警告し、settings.json は書く
#   - --dry-run は何も書かず、本番と同じ判定を出す (書けない形なら書けないと出す)。--check は state を見ずに managed.json と
#     custom-layouts.json を確かめ、誤りがあれば exit 1
#   - managed.json に誤りがあるときは、setup では警告して書かずに exit 0。jq が無いときも setup では exit 0 (--check は exit 1)
#   - 引数の誤りは exit 2。script に実行ビットがある (setup.sh は -x でない bootstrap を流さずに止まる)
#
# ## 偽の checkout
#
# script は自分のいる checkout の win/powertoys/fancyzones/ を読むので、ケースごとに <ケース>/repo/nix/scripts/ へ写して流す。
# Windows のホームに見立てるのは <ケース>/win。script は .exe を呼ばないが、要るコマンドだけを symlink で並べた PATH で流す
# (足りないコマンドに気づけるように)。mv・touch・sleep は偽物で、呼ばれた順を fs-calls に残し、sleep は待たない。
# 偽のコマンドの shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-fancyzones.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-fancyzones-test.XXXXXX")
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

real_mv=$(command -v mv)
real_touch=$(command -v touch)

# 要るコマンドだけを並べた PATH (mv・touch・sleep はケースごとの偽物が先に来る)。jq だけ抜いたものも作る
sys_bin="${work}/sys-bin"
sys_bin_nojq="${work}/sys-bin-nojq"
mkdir -p "${sys_bin}" "${sys_bin_nojq}"
for c in jq cat mkdir rm dirname sed grep; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
  if [[ ${c} != jq ]]; then
    ln -s "${p}" "${sys_bin_nojq}/${c}"
  fi
done

# PowerToys が書く FancyZones の settings.json の形 (この PC の形から一部を抜いた。1 行で末尾に改行なし)。
# $1: fancyzones_overrideSnapHotkeys の値
fz_settings() {
  printf '{"properties":{"fancyzones_shiftDrag":{"value":true},"fancyzones_overrideSnapHotkeys":{"value":%s},"fancyzones_overlappingZonesAlgorithm":{"value":0},"fancyzones_zoneHighlightColor":{"value":"#0078D7"},"fancyzones_highlight_opacity":{"value":50},"fancyzones_editor_hotkey":{"value":{"win":true,"ctrl":false,"alt":false,"shift":true,"code":192,"key":""}},"fancyzones_excluded_apps":{"value":""}},"name":"FancyZones","version":"1.0"}' "$1"
}
# PowerToys の runner が書く全体の settings.json の形。$1: enabled.FancyZones
global_settings() {
  printf '{"startup":true,"enabled":{"Keyboard Manager":true,"FancyZones":%s,"ZoomIt":false},"run_elevated":false,"theme":"system"}' "$1"
}
managed_default='{
  "properties": {
    "fancyzones_overrideSnapHotkeys": {
      "value": true
    }
  }
}'
created='{"properties":{"fancyzones_overrideSnapHotkeys":{"value":true}},"name":"FancyZones","version":"1.0"}'

state_on='{"enable":true,"version":1,"windowsHome":"@WIN@"}'
state_off='{"enable":false,"version":1,"windowsHome":null}'

fz_dir() { echo "$1/win/AppData/Local/Microsoft/PowerToys/FancyZones"; }
fz_json() { echo "$1/win/AppData/Local/Microsoft/PowerToys/FancyZones/settings.json"; }
global_json() { echo "$1/win/AppData/Local/Microsoft/PowerToys/settings.json"; }
managed_json() { echo "$1/repo/win/powertoys/fancyzones/managed.json"; }
layouts_json() { echo "$1/repo/win/powertoys/fancyzones/custom-layouts.json"; }

# $1: 名前、$2: windows-files.json の中身 (空なら作らない)
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.local/state/dotfiles" "${h}/bin" "${h}/win" "${h}/repo/nix/scripts" "${h}/repo/win/powertoys/fancyzones"
  cp "${script}" "${h}/repo/nix/scripts/bootstrap-windows-fancyzones.sh"
  printf '%s\n' "${managed_default}" >"$(managed_json "${h}")"
  printf '{"custom-layouts":[]}' >"$(layouts_json "${h}")"
  if [[ -n $2 ]]; then
    printf '%s\n' "${2//@WIN@/${h}/win}" >"${h}/.local/state/dotfiles/windows-files.json"
  fi
  # 偽の mv。呼ばれたことを fs-calls に残して本物を流し、置き換えた後の mtime を昔へ戻す (touch が本当に mtime を進めたかを、
  # 流した後に見るため)。FAKE_MV_FAIL があれば、素のエラーを出して失敗する
  {
    printf '#!%s\n' "${BASH}"
    printf 'real=%q\nreal_touch=%q\n' "${real_mv}" "${real_touch}"
    cat <<'EOF'
printf 'mv %s\n' "${@: -1}" >>"${HOME}/fs-calls"
if [[ -n ${FAKE_MV_FAIL-} ]]; then
  echo "mv: cannot move" >&2
  exit 1
fi
"${real}" "$@" || exit
"${real_touch}" -d '2000-01-01 00:00:00' -- "${@: -1}"
EOF
  } >"${h}/bin/mv"
  # 偽の touch。呼ばれたことを fs-calls に残して本物を流す。FAKE_TOUCH_FAIL があれば、素のエラーを出して失敗する
  {
    printf '#!%s\n' "${BASH}"
    printf 'real=%q\n' "${real_touch}"
    cat <<'EOF'
printf 'touch %s\n' "${@: -1}" >>"${HOME}/fs-calls"
if [[ -n ${FAKE_TOUCH_FAIL-} ]]; then
  echo "touch: cannot touch" >&2
  exit 1
fi
exec "${real}" "$@"
EOF
  } >"${h}/bin/touch"
  # 偽の sleep。待たずに回数を sleep-calls に残す。FAKE_SLEEP_AT 回目に、FAKE_SLEEP_PATH へ FAKE_SLEEP_WRITE を書く
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/sleep-calls"
if [[ -n ${FAKE_SLEEP_PATH-} && $(grep -c '' "${HOME}/sleep-calls") == "${FAKE_SLEEP_AT:-1}" ]]; then
  printf '%s' "${FAKE_SLEEP_WRITE-}" >"${FAKE_SLEEP_PATH}"
fi
exit 0
EOF
  } >"${h}/bin/sleep"
  chmod +x "${h}/bin/mv" "${h}/bin/touch" "${h}/bin/sleep"
  echo "${h}"
}

# settings.json を置く。$1: HOME、$2: 中身
put_fz() {
  mkdir -p "$(fz_dir "$1")"
  printf '%s' "$2" >"$(fz_json "$1")"
}
put_global() {
  mkdir -p "$(dirname "$(global_json "$1")")"
  printf '%s' "$2" >"$(global_json "$1")"
}

# $1: HOME、残り: script の引数。RUN_NO_JQ があれば jq の無い PATH で流す
run() {
  local h=$1 base=${sys_bin}
  shift
  if [[ -n ${RUN_NO_JQ-} ]]; then
    base=${sys_bin_nojq}
  fi
  env HOME="${h}" PATH="${h}/bin:${base}" "${BASH}" "${h}/repo/nix/scripts/bootstrap-windows-fancyzones.sh" "$@" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }
# 判定の grep -q はパイプで受けず、ファイルを直に読む (pipefail の下で SIGPIPE を拾って「合わない」に見えることがある)
seen() {
  local d=$1
  shift
  grep -q "$@" "${d}/out" "${d}/err"
}
fs_calls() { tr '\n' ',' <"$1/fs-calls" 2>/dev/null; }
nsleep() { grep -c '' "$1/sleep-calls" 2>/dev/null || echo 0; }
warnings() { cat "$1/warnings" 2>/dev/null; }
# 1 行で末尾に改行が無いか
one_line_no_newline() { [[ $(grep -c '' "$1") == 1 && $(tail -c 1 "$1") == '}' ]]; }
# mtime が今か (偽の mv が 2000 年へ戻すので、touch が進めていなければ古いまま)
recent_mtime() { (($(stat -c %Y "$1") > $(date +%s) - 3600)); }
# 偽の jq を置く。フィルタに $2 を含む呼び出しの間だけ settings.json を 0 バイトにして、終わったら中身を戻す
# (設定画面が切り詰めてから書いている一瞬を作る)。jq が無いケースと混ざらないよう、要るケースでだけ置く
empty_moment_jq() {
  local real_jq
  real_jq=$(command -v jq)
  {
    printf '#!%s\n' "${BASH}"
    printf 'real=%q\ntarget=%q\nmatch=%q\n' "${real_jq}" "$(fz_json "$1")" "$2"
    cat <<'EOF'
for a in "$@"; do
  if [[ ${a} == *"${match}"* ]]; then
    body=$(<"${target}")
    : >"${target}"
    "${real}" "$@"
    rc=$?
    printf '%s' "${body}" >"${target}"
    exit "${rc}"
  fi
done
exec "${real}" "$@"
EOF
  } >"$1/bin/jq"
  chmod +x "$1/bin/jq"
}

echo "== bootstrap-windows-fancyzones.sh: ${script}"

# 1. windows-files.json が無い / enable = false: 何も書かず、警告も出さずに、理由を出して飛ばす。
#    windows-files.nix は無効のマシンに windowsHome = null を書くが、値があっても飛ばす
check_skip() {
  local h
  h=$(new_home "t1-$1" "$2")
  run "${h}"
  if [[ $(rc "${h}") == 0 && ! -e $(fz_dir "${h}") && ! -e ${h}/fs-calls && ! -s ${h}/err ]] && seen "${h}" "$3"; then
    ok "飛ばす ($1): 何も書かず、理由を出す"
  else
    ng "飛ばす ($1)" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
}
check_skip nostate "" '配り先の設定がありません'
check_skip off-null "${state_off}" 'このマシンは Windows 側へ配りません'
check_skip off-home '{"enable":false,"version":1,"windowsHome":"@WIN@"}' 'このマシンは Windows 側へ配りません'

# 1b. Windows 側のホームが見えない・windowsHome が空: 警告して exit 0 (まとめにも残す)
for t in '/nonexistent/fancyzones-test' ''; do
  h=$(new_home "t1b-${#t}" "{\"enable\":true,\"version\":1,\"windowsHome\":\"${t}\"}")
  DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
  if [[ $(rc "${h}") == 0 && ! -e ${h}/fs-calls ]] && seen "${h}" 'Windows 側のホームが見えない' && grep -q 'Windows 側のホームが見えない' "${h}/warnings"; then
    ok "Windows 側のホームが見えなければ (${t:-空}) 警告して exit 0"
  else
    ng "ホームが見えない (${t:-空})" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
done
h=$(new_home t1b-null '{"enable":true,"version":1,"windowsHome":null}')
run "${h}"
if [[ $(rc "${h}") == 0 ]] && seen "${h}" -F '(windowsHome が空)'; then
  ok "windowsHome が null なら、空と出して exit 0"
else
  ng "windowsHome が null" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 1c. windows-files.json が壊れている: 手順を止めない (exit 0)
i=0
for body in 'not json' '{"enable":true}'$'\n''['; do
  i=$((i + 1))
  h=$(new_home "t1c-${i}" "${body}")
  run "${h}"
  if [[ $(rc "${h}") == 0 && ! -e $(fz_dir "${h}") ]] && ! grep -qE '^jq: ' "${h}/err"; then
    ok "windows-files.json が壊れていても (${i}) exit 0 で、jq の素のエラーを出さない"
  else
    ng "windows-files.json が壊れている (${i})" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
done

# 2. 値が違う: 持つキーだけを書く。ほかのキーの値・順・1 行で末尾に改行なしの形は変えない。mv の後に touch する。1 行出す
h=$(new_home t2 "${state_on}")
put_fz "${h}" "$(fz_settings false)"
printf 'keep' >"$(fz_dir "${h}")/custom-layouts.json"
printf 'keep' >"$(fz_dir "${h}")/applied-layouts.json"
touch -d '2020-01-01 00:00:00' "$(fz_dir "${h}")/custom-layouts.json"
before_layout=$(stat -c %Y "$(fz_dir "${h}")/custom-layouts.json")
DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "$(fz_settings true)" ]] && one_line_no_newline "$(fz_json "${h}")" \
  && [[ $(fs_calls "${h}") == "mv $(fz_json "${h}"),touch $(fz_json "${h}")," ]] \
  && [[ ! -e "$(fz_json "${h}").dotfiles-tmp" ]] \
  && [[ $(grep -c 'dotfiles の値へ戻しました' "${h}/out") == 1 ]] \
  && seen "${h}" -F 'properties.fancyzones_overrideSnapHotkeys.value false → true' \
  && [[ ! -s ${h}/err && ! -s ${h}/warnings ]] \
  && [[ $(cat "$(fz_dir "${h}")/custom-layouts.json") == keep && $(stat -c %Y "$(fz_dir "${h}")/custom-layouts.json") == "${before_layout}" ]] \
  && [[ $(cat "$(fz_dir "${h}")/applied-layouts.json") == keep ]] && recent_mtime "$(fz_json "${h}")"; then
  ok "値が違えば持つキーだけを書き、形を変えず、mv の後に touch して (mtime が進む) 1 行出す (まとめには残さない)"
else
  ng "値が違う" "rc=$(rc "${h}") calls=$(fs_calls "${h}") json=$(cat "$(fz_json "${h}")") $(outerr "${h}")"
fi

# 3. 次の回: 値が同じなので書かない。LastWriteTime も変えない
touch -d '2020-01-01 00:00:00' "$(fz_json "${h}")"
before_mtime=$(stat -c %Y "$(fz_json "${h}")")
: >"${h}/fs-calls"
run "${h}"
if [[ $(rc "${h}") == 0 && ! -s ${h}/fs-calls && $(stat -c %Y "$(fz_json "${h}")") == "${before_mtime}" ]] \
  && seen "${h}" '揃っています (持つキー 1 件)' && ! seen "${h}" '戻しました'; then
  ok "値が同じなら書かず、LastWriteTime も変えない"
else
  ng "値が同じ" "rc=$(rc "${h}") calls=$(fs_calls "${h}") $(outerr "${h}")"
fi

# 4. 設定画面で手で変えた: 次の回で戻す。衝突にしない
put_fz "${h}" "$(fz_settings false)"
run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "$(fz_settings true)" ]] && seen "${h}" '戻しました'; then
  ok "手で変えていても、次の回で戻す (exit 0)"
else
  ng "手で変えた" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 5. settings.json が無い (ディレクトリも無い): 持つキーと name・version だけで作る。mv の後に touch する。次の回は揃っている
h=$(new_home t5 "${state_on}")
DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "${created}" ]] && one_line_no_newline "$(fz_json "${h}")" \
  && [[ $(fs_calls "${h}") == "mv $(fz_json "${h}"),touch $(fz_json "${h}")," ]] \
  && seen "${h}" '持つキーだけで作りました' && [[ ! -s ${h}/warnings ]] && recent_mtime "$(fz_json "${h}")"; then
  : >"${h}/fs-calls"
  run "${h}"
  if [[ $(rc "${h}") == 0 && ! -s ${h}/fs-calls ]] && seen "${h}" '揃っています'; then
    ok "settings.json が無ければ、持つキーと name・version だけで作る (次の回は揃っている)"
  else
    ng "作った次の回" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
else
  ng "settings.json が無い" "rc=$(rc "${h}") calls=$(fs_calls "${h}") json=$(cat "$(fz_json "${h}")" 2>/dev/null) $(outerr "${h}")"
fi

# 6. 持つキーが settings.json に無い: 足す。ほかは変えない
h=$(new_home t6 "${state_on}")
put_fz "${h}" '{"properties":{"fancyzones_shiftDrag":{"value":true}},"name":"FancyZones","version":"1.0"}'
run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == '{"properties":{"fancyzones_shiftDrag":{"value":true},"fancyzones_overrideSnapHotkeys":{"value":true}},"name":"FancyZones","version":"1.0"}' ]] \
  && seen "${h}" -F '(無い) → true'; then
  ok "持つキーが無ければ足す"
else
  ng "キーが無い" "rc=$(rc "${h}") json=$(cat "$(fz_json "${h}")") $(outerr "${h}")"
fi

# 7. 持つキーはデータで決まる: managed.json にキーを足すと、script を変えずに書く (数値・文字列・ホットキーの一部も)
h=$(new_home t7 "${state_on}")
put_fz "${h}" "$(fz_settings true)"
cat >"$(managed_json "${h}")" <<'EOF'
{
  "properties": {
    "fancyzones_overrideSnapHotkeys": { "value": true },
    "fancyzones_highlight_opacity": { "value": 80 },
    "fancyzones_zoneHighlightColor": { "value": "#112233" },
    "fancyzones_editor_hotkey": { "value": { "code": 65 } }
  }
}
EOF
run "${h}"
want='{"properties":{"fancyzones_shiftDrag":{"value":true},"fancyzones_overrideSnapHotkeys":{"value":true},"fancyzones_overlappingZonesAlgorithm":{"value":0},"fancyzones_zoneHighlightColor":{"value":"#112233"},"fancyzones_highlight_opacity":{"value":80},"fancyzones_editor_hotkey":{"value":{"win":true,"ctrl":false,"alt":false,"shift":true,"code":65,"key":""}},"fancyzones_excluded_apps":{"value":""}},"name":"FancyZones","version":"1.0"}'
if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "${want}" ]] && [[ $(grep -c '戻しました' "${h}/out") == 3 ]] \
  && seen "${h}" -F 'fancyzones_highlight_opacity.value 50 → 80' && seen "${h}" -F 'fancyzones_zoneHighlightColor.value "#0078D7" → "#112233"' \
  && seen "${h}" -F 'fancyzones_editor_hotkey.value.code 192 → 65'; then
  run "${h}"
  if seen "${h}" '揃っています (持つキー 4 件)'; then
    ok "managed.json にキーを足すと、script を変えずに書く (数値・文字列・ホットキーの一部も)"
  else
    ng "足したキーの次の回" "$(outerr "${h}")"
  fi
else
  ng "データで決まる" "rc=$(rc "${h}") json=$(cat "$(fz_json "${h}")") $(outerr "${h}")"
fi

# 7b. 持つ値が false: 同じなら書かず、違えば書く (false を「無い」と取り違えない)
h=$(new_home t7b "${state_on}")
printf '{"properties":{"fancyzones_overrideSnapHotkeys":{"value":false}}}\n' >"$(managed_json "${h}")"
put_fz "${h}" "$(fz_settings false)"
run "${h}"
same_ok=$([[ ! -e ${h}/fs-calls ]] && seen "${h}" '揃っています' && echo yes)
put_fz "${h}" "$(fz_settings true)"
run "${h}"
if [[ ${same_ok} == yes && $(cat "$(fz_json "${h}")") == "$(fz_settings false)" ]] && seen "${h}" -F 'true → false'; then
  ok "持つ値が false でも比べて書く"
else
  ng "持つ値が false" "same=${same_ok} $(outerr "${h}")"
fi

# 7c. managed.json から消したキーは、settings.json からは消さない。最後の値が残り、以後は戻さない
h=$(new_home t7c "${state_on}")
printf '{"properties":{"fancyzones_shiftDrag":{"value":true}}}\n' >"$(managed_json "${h}")"
put_fz "${h}" "$(fz_settings false)"
run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "$(fz_settings false)" && ! -e ${h}/fs-calls ]] && seen "${h}" '揃っています'; then
  ok "managed.json から消したキーは、settings.json からは消さない"
else
  ng "消したキー" "rc=$(rc "${h}") calls=$(fs_calls "${h}") $(outerr "${h}")"
fi

# 8. 読めない (JSON でない・空・object でない): 5 回読んでから警告し、書かずに exit 0
for t in "broken:not json" "partial:{\"properties\":{\"fancy" "empty:" "array:[1]"; do
  name=${t%%:*}
  body=${t#*:}
  h=$(new_home "t8-${name}" "${state_on}")
  put_fz "${h}" "${body}"
  DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
  if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "${body}" && ! -e ${h}/fs-calls && $(nsleep "${h}") == 5 ]] \
    && grep -q 'settings.json を読めない' "${h}/err" && grep -q 'settings.json を読めない' "${h}/warnings"; then
    ok "読めなければ (${name}) 5 回読んでから警告し、書かずに exit 0"
  else
    ng "読めない (${name})" "rc=$(rc "${h}") sleep=$(nsleep "${h}") calls=$(fs_calls "${h}") $(outerr "${h}")"
  fi
done

# 9. 書いている途中に当たっても、読めるようになれば進む
h=$(new_home t9 "${state_on}")
put_fz "${h}" '{"properties":{"fancy'
FAKE_SLEEP_PATH=$(fz_json "${h}") FAKE_SLEEP_AT=2 FAKE_SLEEP_WRITE=$(fz_settings false) run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "$(fz_settings true)" && $(nsleep "${h}") == 2 ]] \
  && ! seen "${h}" '読めない' && seen "${h}" '戻しました'; then
  ok "書いている途中に当たっても、読めるようになれば書く"
else
  ng "書いている途中" "rc=$(rc "${h}") sleep=$(nsleep "${h}") $(outerr "${h}")"
fi

# 9b. 書いている途中の空のファイルを、書くときに読む: 空で置き換えない。元の中身のまま、書けないと警告する
# shellcheck disable=SC2016 # jq の式を文字のまま探す
{
  h=$(new_home t9b "${state_on}")
  put_fz "${h}" "$(fz_settings false)"
  empty_moment_jq "${h}" 'apply($m[0])'
  run "${h}"
  if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "$(fz_settings false)" && ! -e ${h}/fs-calls && ! -e "$(fz_json "${h}").dotfiles-tmp" ]] \
    && grep -q 'settings.json に書けない' "${h}/err" && ! seen "${h}" '戻しました'; then
    ok "書くときに空のファイルを読んでも、空で置き換えない"
  else
    ng "書くときに空を読む" "rc=$(rc "${h}") size=$(stat -c %s "$(fz_json "${h}")") calls=$(fs_calls "${h}") $(outerr "${h}")"
  fi

  # 9c. 比べるときに読む: 差が無いことにしない。「揃っています」と言わず、読めないと警告する
  h=$(new_home t9c "${state_on}")
  put_fz "${h}" "$(fz_settings false)"
  empty_moment_jq "${h}" 'select($cur != $want)'
  run "${h}"
  if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "$(fz_settings false)" && ! -e ${h}/fs-calls ]] \
    && grep -q 'settings.json を読めない' "${h}/err" && ! seen "${h}" '揃っています'; then
    ok "比べるときに空のファイルを読んでも、揃っているとは言わない"
  else
    ng "比べるときに空を読む" "rc=$(rc "${h}") calls=$(fs_calls "${h}") $(outerr "${h}")"
  fi
}

# 10. 途中が object でない: 元のまま警告して exit 0。一時ファイルを残さない。警告にはキーと値を出し、jq の素のエラーを混ぜない
for t in 'arr:{"properties":[],"name":"FancyZones"}' 'scalar:{"properties":{"fancyzones_overrideSnapHotkeys":true},"name":"FancyZones"}'; do
  name=${t%%:*}
  body=${t#*:}
  h=$(new_home "t10-${name}" "${state_on}")
  put_fz "${h}" "${body}"
  DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
  if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "${body}" && ! -e ${h}/fs-calls && ! -e "$(fz_json "${h}").dotfiles-tmp" ]] \
    && grep -q 'settings.json に書けない' "${h}/err" && grep -q 'settings.json に書けない' "${h}/warnings" \
    && grep -qF 'properties.fancyzones_overrideSnapHotkeys.value' "${h}/err" && ! grep -qE '^jq: ' "${h}/err"; then
    ok "途中が object でなければ (${name}) 元のまま警告して exit 0"
  else
    ng "途中が object でない (${name})" "rc=$(rc "${h}") calls=$(fs_calls "${h}") json=$(cat "$(fz_json "${h}")") $(outerr "${h}")"
  fi
done

# 11. 一時ファイルを作れない (root でも落ちるよう、その場所をディレクトリにする): 元のまま警告して exit 0
h=$(new_home t11 "${state_on}")
put_fz "${h}" "$(fz_settings false)"
mkdir "$(fz_json "${h}").dotfiles-tmp"
run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "$(fz_settings false)" && ! -e ${h}/fs-calls ]] \
  && grep -q 'settings.json に書けない' "${h}/err" && ! seen "${h}" '戻しました' && [[ $(grep -c '^!! ' "${h}/err") == 1 ]] \
  && ! grep -q 'Is a directory' "${h}/err"; then
  ok "一時ファイルを作れなければ、元のまま警告して exit 0 (素のエラーを混ぜない)"
else
  ng "一時ファイルを作れない" "rc=$(rc "${h}") calls=$(fs_calls "${h}") $(outerr "${h}")"
fi

# 12. mv できない: 元のまま警告して exit 0。一時ファイルを消す。touch しない
h=$(new_home t12 "${state_on}")
put_fz "${h}" "$(fz_settings false)"
FAKE_MV_FAIL=1 run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "$(fz_settings false)" && $(fs_calls "${h}") == "mv $(fz_json "${h}")," && ! -e "$(fz_json "${h}").dotfiles-tmp" ]] \
  && grep -q 'settings.json に書けない' "${h}/err" && ! seen "${h}" '戻しました' && ! grep -qE '^mv: ' "${h}/err"; then
  ok "mv できなければ、元のまま警告して exit 0 (一時ファイルを消す。素のエラーを混ぜない)"
else
  ng "mv できない" "rc=$(rc "${h}") calls=$(fs_calls "${h}") $(outerr "${h}")"
fi

# 13. touch できない: 書いたうえで、読み直させられなかったと警告する (起動し直すと読む)
h=$(new_home t13 "${state_on}")
put_fz "${h}" "$(fz_settings false)"
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_TOUCH_FAIL=1 run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "$(fz_settings true)" ]] && seen "${h}" '戻しました' \
  && grep -q '読み直させられませんでした' "${h}/err" && grep -q '起動し直すと読みます' "${h}/warnings" && ! grep -qE '^touch: ' "${h}/err"; then
  ok "touch できなければ、書いたうえで読み直させられなかったと警告する (素のエラーを混ぜない)"
else
  ng "touch できない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 14. ディレクトリを作れない (FancyZones の場所がファイル): 警告して exit 0
h=$(new_home t14 "${state_on}")
mkdir -p "$(dirname "$(fz_dir "${h}")")"
printf 'file' >"$(fz_dir "${h}")"
DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
if [[ $(rc "${h}") == 0 && ! -e ${h}/fs-calls ]] && grep -q 'settings.json を作れません' "${h}/err" \
  && grep -q 'settings.json を作れません' "${h}/warnings" && [[ $(cat "$(fz_dir "${h}")") == file ]]; then
  ok "ディレクトリを作れなければ、警告して exit 0"
else
  ng "ディレクトリを作れない" "rc=$(rc "${h}") calls=$(fs_calls "${h}") $(outerr "${h}")"
fi

# 14b. 作るときに mv できない: 警告して exit 0。touch で空のファイルを作らない。一時ファイルも残さない
h=$(new_home t14b "${state_on}")
mkdir -p "$(fz_dir "${h}")"
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_MV_FAIL=1 run "${h}"
if [[ $(rc "${h}") == 0 && ! -e $(fz_json "${h}") && ! -e "$(fz_json "${h}").dotfiles-tmp" ]] && grep -q 'settings.json を作れません' "${h}/warnings"; then
  ok "作るときに mv できなければ、警告して exit 0 (空のファイルを残さない)"
else
  ng "作るときに mv できない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 15. FancyZones がオフ: 書いたときも、揃っているときも、作ったときも警告し、まとめにも残す。全体の設定は変えない
#     (ケースごとの準備は下の for で分ける)
for t in written same created; do
  h=$(new_home "t15-${t}" "${state_on}")
  put_global "${h}" "$(global_settings false)"
  case ${t} in
    written) put_fz "${h}" "$(fz_settings false)" ;;
    same) put_fz "${h}" "$(fz_settings true)" ;;
  esac
  DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
  if [[ $(rc "${h}") == 0 && $(cat "$(global_json "${h}")") == "$(global_settings false)" ]] \
    && [[ $(jq -r '.properties.fancyzones_overrideSnapHotkeys.value' "$(fz_json "${h}")") == true ]] \
    && grep -q 'FancyZones がオフ' "${h}/err" && grep -q '「ウィンドウとレイアウト」→「FancyZones」' "${h}/err" \
    && grep -q '自動ではオンにしません' "${h}/err" && grep -q 'FancyZones がオフ' "${h}/warnings"; then
    ok "FancyZones がオフなら (${t}) 警告してまとめにも残し、全体の設定は変えない"
  else
    ng "FancyZones がオフ (${t})" "rc=$(rc "${h}") global=$(cat "$(global_json "${h}")") warnings=$(warnings "${h}") $(outerr "${h}")"
  fi
done
# 揃っているときは、揃っていることも出す
h=${work}/t15-same
if seen "${h}" '揃っています' && [[ $(grep -c '^!! ' "${h}/err") == 1 ]]; then
  ok "オフで揃っているときは、揃っていることと警告の両方を出す"
else
  ng "オフで揃っている" "$(outerr "${h}")"
fi

# 15b. オフの警告は、読めない・書けない・作れないときと --dry-run でも出す (「効かない」と知らせそびれない)
for t in unreadable writefail createfail dryrun; do
  h=$(new_home "t15b-${t}" "${state_on}")
  put_global "${h}" "$(global_settings false)"
  args=()
  case ${t} in
    unreadable) put_fz "${h}" 'not json' ;;
    writefail) put_fz "${h}" '{"properties":[],"name":"FancyZones"}' ;;
    createfail) printf 'file' >"$(fz_dir "${h}")" ;;
    dryrun)
      put_fz "${h}" "$(fz_settings false)"
      args=(--dry-run)
      ;;
  esac
  DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}" "${args[@]}"
  if [[ $(rc "${h}") == 0 ]] && grep -q 'FancyZones がオフ' "${h}/err" && grep -q 'FancyZones がオフ' "${h}/warnings"; then
    ok "オフの警告は ${t} でも出す"
  else
    ng "オフの警告 (${t})" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
done

# 16. 全体の設定にキーが無い・ファイルが無い・true: 警告しない (FancyZones は既定でオン)
for t in 'nokey:{"startup":true,"enabled":{"Keyboard Manager":true}}' 'noenabled:{"startup":true}' "on:$(global_settings true)" 'nofile:'; do
  name=${t%%:*}
  body=${t#*:}
  h=$(new_home "t16-${name}" "${state_on}")
  put_fz "${h}" "$(fz_settings true)"
  if [[ -n ${body} ]]; then
    put_global "${h}" "${body}"
  fi
  DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
  if [[ $(rc "${h}") == 0 && ! -s ${h}/err && ! -s ${h}/warnings && $(nsleep "${h}") == 0 ]] && seen "${h}" '揃っています'; then
    ok "全体の設定が ${name} なら警告しない"
  else
    ng "全体の設定 (${name})" "rc=$(rc "${h}") sleep=$(nsleep "${h}") $(outerr "${h}")"
  fi
done

# 17. 全体の設定が読めない: 確かめられないと警告する。settings.json は書く
for t in "broken:not json" "empty:" 'scalar:{"enabled":true}'; do
  name=${t%%:*}
  body=${t#*:}
  h=$(new_home "t17-${name}" "${state_on}")
  put_fz "${h}" "$(fz_settings false)"
  put_global "${h}" "${body}"
  DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
  if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "$(fz_settings true)" && $(nsleep "${h}") == 5 ]] \
    && grep -q '確かめられません' "${h}/err" && grep -q '確かめられません' "${h}/warnings"; then
    ok "全体の設定が読めなければ (${name}) 確かめられないと警告し、settings.json は書く"
  else
    ng "全体の設定が読めない (${name})" "rc=$(rc "${h}") sleep=$(nsleep "${h}") $(outerr "${h}")"
  fi
done

# 17b. 全体の設定を読みかけても、読み直して確かめる
h=$(new_home t17b "${state_on}")
put_fz "${h}" "$(fz_settings true)"
put_global "${h}" '{"startup":tr'
FAKE_SLEEP_PATH=$(global_json "${h}") FAKE_SLEEP_AT=2 FAKE_SLEEP_WRITE=$(global_settings false) run "${h}"
if [[ $(rc "${h}") == 0 && $(nsleep "${h}") == 2 ]] && grep -q 'FancyZones がオフ' "${h}/err" && ! seen "${h}" '確かめられません'; then
  ok "全体の設定を読みかけても、読み直して確かめる"
else
  ng "全体の設定の読みかけ" "rc=$(rc "${h}") sleep=$(nsleep "${h}") $(outerr "${h}")"
fi

# 18. 引数の誤り: exit 2。--help は exit 0
h=$(new_home t18 "${state_on}")
put_fz "${h}" "$(fz_settings false)"
run "${h}" --bogus
rc_bogus=$(rc "${h}")
run "${h}" --check --dry-run
rc_both=$(rc "${h}")
run "${h}" --help
rc_help=$(rc "${h}")
if [[ ${rc_bogus} == 2 && ${rc_both} == 2 && ${rc_help} == 0 && $(cat "$(fz_json "${h}")") == "$(fz_settings false)" ]] && grep -q -- '--dry-run' "${h}/out"; then
  ok "知らない引数・--check と --dry-run の組み合わせは exit 2、--help は exit 0"
else
  ng "引数" "bogus=${rc_bogus} both=${rc_both} help=${rc_help} $(outerr "${h}")"
fi

# 19. --dry-run: 何も書かない (ファイルもディレクトリも作らない)。判定は出す
h=$(new_home t19a "${state_on}")
put_fz "${h}" "$(fz_settings false)"
run "${h}" --dry-run
h2=$(new_home t19b "${state_on}")
run "${h2}" --dry-run
if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "$(fz_settings false)" && ! -e ${h}/fs-calls ]] \
  && seen "${h}" -F '[dry-run] FancyZones の設定を dotfiles の値へ戻します: properties.fancyzones_overrideSnapHotkeys.value false → true' \
  && [[ $(rc "${h2}") == 0 && ! -e $(fz_dir "${h2}") && ! -e ${h2}/fs-calls ]] && seen "${h2}" -F '[dry-run] FancyZones の settings.json が無いので'; then
  ok "--dry-run は何も書かず、判定を出す"
else
  ng "--dry-run" "rc=$(rc "${h}")/$(rc "${h2}") $(outerr "${h}") $(outerr "${h2}")"
fi

# 19b. --dry-run は本番と同じ判定を出す: 書けない形なら「戻します」と言わず、書けないと出す。書かない
h=$(new_home t19c "${state_on}")
put_fz "${h}" '{"properties":[],"name":"FancyZones"}'
run "${h}" --dry-run
if [[ $(rc "${h}") == 0 && ! -e ${h}/fs-calls && ! -e "$(fz_json "${h}").dotfiles-tmp" ]] && seen "${h}" -F '[dry-run] FancyZones の settings.json に書けません' \
  && seen "${h}" -F 'properties.fancyzones_overrideSnapHotkeys.value' && ! seen "${h}" '戻します'; then
  ok "--dry-run は、書けない形なら書けないと出す"
else
  ng "--dry-run の書けない形" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 20. --check: state を見ずに確かめる
h=$(new_home t20 "")
run "${h}" --check
if [[ $(rc "${h}") == 0 ]] && seen "${h}" -F 'win/powertoys/fancyzones/: OK (持つキー 1 件)'; then
  ok "--check は state が無くても確かめ、持つキーの数を出す"
else
  ng "--check" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 20b. --check: managed.json の誤りは exit 1
i=0
for body in 'not json' '' '[1]' '{}' '{"properties":{}}' '{"properties":[]}' \
  '{"properties":{"k":{"value":true}},"name":"FancyZones"}' '{"properties":{"k":true}}' '{"properties":{"k":{"other":true}}}' \
  '{"properties":{"k":{"value":true,"other":1}}}' '{"properties":{"k":{"value":{}}}}' '{"properties":{"k":{"value":null}}}' \
  '{"properties":{"k":{"value":{"a":{},"b":1}}}}'; do
  i=$((i + 1))
  h=$(new_home "t20b-${i}" "")
  printf '%s' "${body}" >"$(managed_json "${h}")"
  run "${h}" --check
  if [[ $(rc "${h}") == 1 ]] && grep -q 'managed.json に誤りがあります' "${h}/err"; then
    ok "--check: 誤った managed.json (${body:-空}) は exit 1"
  else
    ng "--check の誤り (${body:-空})" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
done

# 20c. --check: custom-layouts.json の誤りは exit 1
i=0
for body in 'not json' '{}' '{"custom-layouts":{}}'; do
  i=$((i + 1))
  h=$(new_home "t20c-${i}" "")
  printf '%s' "${body}" >"$(layouts_json "${h}")"
  run "${h}" --check
  if [[ $(rc "${h}") == 1 ]] && grep -q 'custom-layouts.json が' "${h}/err"; then
    ok "--check: 誤った custom-layouts.json (${body}) は exit 1"
  else
    ng "--check の custom-layouts.json (${body})" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
done

# 21. setup で managed.json に誤りがある: 警告して書かずに exit 0 (後ろの手順を止めない)
h=$(new_home t21 "${state_on}")
put_fz "${h}" "$(fz_settings false)"
printf '%s' 'not json' >"$(managed_json "${h}")"
DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "$(fz_settings false)" && ! -e ${h}/fs-calls ]] \
  && grep -q 'managed.json に誤りがある' "${h}/err" && grep -q 'managed.json に誤りがある' "${h}/warnings"; then
  ok "setup で managed.json に誤りがあれば、警告して書かずに exit 0"
else
  ng "setup の managed.json の誤り" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 22. jq が無い: setup では警告して exit 0。--check は exit 1
h=$(new_home t22 "${state_on}")
put_fz "${h}" "$(fz_settings false)"
RUN_NO_JQ=1 run "${h}"
rc_setup=$(rc "${h}")
warned=$(grep -c 'jq が見つかりません' "${h}/err")
RUN_NO_JQ=1 run "${h}" --check
if [[ ${rc_setup} == 0 && ${warned} == 1 && $(rc "${h}") == 1 && $(cat "$(fz_json "${h}")") == "$(fz_settings false)" ]]; then
  ok "jq が無ければ、setup では警告して exit 0、--check は exit 1"
else
  ng "jq が無い" "setup=${rc_setup} check=$(rc "${h}") warned=${warned} $(outerr "${h}")"
fi

# 23. script に実行ビットがある (setup.sh は実行ビットの無い bootstrap を「実行できません」で止める)
if [[ -x ${script} ]]; then
  ok "script に実行ビットがある (setup.sh は実行できない bootstrap で止まる)"
else
  ng "script に実行ビットが無い" "$(ls -l "${script}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
