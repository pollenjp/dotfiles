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
# カスタムレイアウト (custom-layouts.json):
#
#   - repo のレイアウトを uuid で PC のファイルと突き合わせ、PC に無ければ末尾に足す。PC にだけあるレイアウト・
#     applied-layouts.json には触らず、どの場合も exit 0。PowerToys の形 (字下げ 2・CRLF・末尾に改行なし) で書き、隣に書いて
#     mv した後に touch する。書き換える前のファイルを退避し (新しい方から 10 回分)、足したものを記録する。足したことと、
#     PC にだけあるレイアウトに触らないことを出す
#   - 次の回は揃っていると出し、書かない。PC が repo と同じなら、キーの順・字下げ・改行が違っても書かずに記録だけする
#   - PC が記録と同じ (前に足したまま) なら、repo の更新として同じ位置で書き換える
#   - PC のエディターで直されていた・足す前から違う中身があった・PC から消えていたら、書き換えず (足し直さず) に警告し
#     (まとめにも残す)、--force と、PC の名前での --import を出す。違いの diff はその場にだけ出す。記録は変えない
#   - --force は直されたものを repo の中身へ戻し、消えていたものを足し直す。--dry-run は何も書かず (退避も記録もしない)、
#     同じ判定を出す
#   - PC にファイルが無ければ (ディレクトリも無くても)、記録によらず repo のレイアウトだけで作る
#   - repo から消したレイアウトは PC から消さず、記録からだけ消す
#   - PC のファイルを読めない (5 回読む。読めるようになれば進む)・記録が壊れている・repo のファイルに誤りがあるときは、
#     書かずに警告する。書けない・退避できない・touch できないときも警告する。どれも settings.json の手順を止めず、
#     managed.json の誤りもレイアウトを止めない
#   - 書き直しても、PC にだけあるレイアウトの名前のエスケープ (\u…) と custom-layouts のほかのキーの中身は変わらない
#   - --import <名前> は、PC のレイアウトを repo のファイルへ PowerToys の形で写す (同じ uuid は同じ位置で置き換え、無ければ末尾に
#     足す。PC のファイル・settings.json・記録には書かない)。--import=<名前> と、繰り返しも受ける。repo と同じなら書かない。
#     PC に無い名前・PC に 2 つある名前・repo の別の uuid と同じ名前・repo に置けない形・commit していない変更・git の
#     checkout でない・配り先の設定が無いときは、何も書かずに exit 1。名前が無い・--force・--dry-run・--check と一緒は exit 2
#   - --check は custom-layouts.json の誤り (uuid の形・name・type・info・object でない要素・uuid と name の重なり) と、
#     PowerToys の形でないこと (LF・末尾の改行・字下げ 4) を exit 1 にする。通れば持つキーとレイアウトの数を出す
#
# ## 偽の checkout
#
# script は自分のいる checkout の win/powertoys/fancyzones/ を読むので、ケースごとに <ケース>/repo/nix/scripts/ へ写して流す。
# Windows のホームに見立てるのは <ケース>/win。script は .exe を呼ばないが、要るコマンドだけを symlink で並べた PATH で流す
# (足りないコマンドに気づけるように)。mv・touch・sleep は偽物で、呼ばれた順を fs-calls に残し、sleep は待たない。
# 偽のコマンドの shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。
# --import のケースは、偽の checkout を git の repo にして commit してから流す。

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
for c in jq cat mkdir rm dirname sed grep cp mktemp date diff git; do
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
  # レイアウトの無い custom-layouts.json (PowerToys の形)
  printf '{\r\n  "custom-layouts": []\r\n}' >"$(layouts_json "${h}")"
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
if [[ $(rc "${h}") == 0 ]] && seen "${h}" -F 'win/powertoys/fancyzones/: OK (持つキー 1 件・カスタムレイアウト 0 件)'; then
  ok "--check は state が無くても確かめ、持つキーとレイアウトの数を出す"
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
  if [[ $(rc "${h}") == 1 ]] && grep -q 'custom-layouts.json に誤りがあります' "${h}/err"; then
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

# ---- カスタムレイアウト (custom-layouts.json) ----

# レイアウト。この PC と pjp-raiden の custom-layouts.json の形から、ゾーンを減らして写した (canvas と grid)
lay_a='{"uuid":"{67070A77-52EC-4EC3-9F63-DF5E58CD4400}","name":"4k-43inch","type":"canvas","info":{"ref-width":2560,"ref-height":1392,"zones":[{"X":0,"Y":54,"width":1846,"height":1234},{"X":0,"Y":297,"width":1374,"height":1055}],"sensitivity-radius":20}}'
# 4k-43inch を PC のエディターで直したもの (2 つ目のゾーンを動かした)
lay_a_edited='{"uuid":"{67070A77-52EC-4EC3-9F63-DF5E58CD4400}","name":"4k-43inch","type":"canvas","info":{"ref-width":2560,"ref-height":1392,"zones":[{"X":0,"Y":54,"width":1846,"height":1234},{"X":10,"Y":297,"width":1374,"height":1055}],"sensitivity-radius":20}}'
# 4k-43inch の前の版 (repo が後でゾーンを足した)
lay_a_old='{"uuid":"{67070A77-52EC-4EC3-9F63-DF5E58CD4400}","name":"4k-43inch","type":"canvas","info":{"ref-width":2560,"ref-height":1392,"zones":[{"X":0,"Y":54,"width":1846,"height":1234}],"sensitivity-radius":20}}'
# 4k-43inch を PC で名前ごと変えたもの
lay_a_renamed='{"uuid":"{67070A77-52EC-4EC3-9F63-DF5E58CD4400}","name":"4k-renamed","type":"canvas","info":{"ref-width":2560,"ref-height":1392,"zones":[{"X":0,"Y":54,"width":1846,"height":1234}],"sensitivity-radius":20}}'
lay_b='{"uuid":"{E389FFDC-3BDD-48CB-B448-0672774C5997}","name":"1080p","type":"canvas","info":{"ref-width":1920,"ref-height":1032,"zones":[{"X":0,"Y":29,"width":1505,"height":878}],"sensitivity-radius":20}}'
# PC にだけあるもの (この PC のエディターで作った)
lay_p1='{"uuid":"{2CAEB420-AB4C-4F3F-9226-1A98F049EDBF}","name":"Custom layout 1","type":"canvas","info":{"ref-width":1536,"ref-height":912,"zones":[{"X":0,"Y":0,"width":768,"height":912}],"sensitivity-radius":20}}'
lay_p2='{"uuid":"{BACEC35B-E024-41AD-8237-5E21D4C4E7F5}","name":"Custom layout 2","type":"grid","info":{"rows":1,"columns":2,"rows-percentage":[10000],"columns-percentage":[5000,5000],"cell-child-map":[[0,1]],"show-spacing":true,"spacing":16,"sensitivity-radius":20}}'
# --import の誤りのケース: PC に同じ名前がもう 1 つ・repo の 1080p と同じ名前で別の uuid・uuid が小文字
lay_p1_dup='{"uuid":"{3D3D3D3D-0000-0000-0000-000000000001}","name":"Custom layout 1","type":"canvas","info":{"ref-width":1536,"ref-height":912,"zones":[],"sensitivity-radius":20}}'
lay_b_other='{"uuid":"{3D3D3D3D-0000-0000-0000-000000000002}","name":"1080p","type":"canvas","info":{"ref-width":1920,"ref-height":1032,"zones":[],"sensitivity-radius":20}}'
lay_low='{"uuid":"{3d3d3d3d-0000-0000-0000-000000000003}","name":"low","type":"canvas","info":{"ref-width":1920,"ref-height":1032,"zones":[],"sensitivity-radius":20}}'
# 小さいレイアウトと、それだけを持つ custom-layouts.json の PowerToys の形のバイト列 (手で書いた)
lay_t='{"uuid":"{11111111-2222-3333-4444-555555555555}","name":"t","type":"canvas","info":{"ref-width":10,"ref-height":20,"zones":[],"sensitivity-radius":20}}'
want_t=$'{\r\n  "custom-layouts": [\r\n    {\r\n      "uuid": "{11111111-2222-3333-4444-555555555555}",\r\n      "name": "t",\r\n      "type": "canvas",\r\n      "info": {\r\n        "ref-width": 10,\r\n        "ref-height": 20,\r\n        "zones": [],\r\n        "sensitivity-radius": 20\r\n      }\r\n    }\r\n  ]\r\n}'

pcl_json() { echo "$(fz_dir "$1")/custom-layouts.json"; }
record_json() { echo "$1/.local/state/dotfiles/windows-fancyzones.applied.json"; }
backup_root() { echo "$1/.local/state/dotfiles/windows-fancyzones/backup"; }
# PowerToys の形 (字下げ 2・CRLF・末尾に改行なし) の custom-layouts.json の中身を出す。引数はレイアウト。
# この形は、この PC と pjp-raiden の custom-layouts.json (エディターが書いたもの) のバイト列と同じだった
pt_layouts() {
  local body
  body=$(jq -n --indent 2 '{"custom-layouts": $ARGS.positional}' --jsonargs "$@")
  printf '%s' "${body//$'\n'/$'\r\n'}"
}
put_pcl() {
  mkdir -p "$(fz_dir "$1")"
  printf '%s' "$2" >"$(pcl_json "$1")"
}
put_repo_layouts() { printf '%s' "$2" >"$(layouts_json "$1")"; }
# 記録を置く。$1: HOME、残り: 前に足したレイアウト
put_record() {
  local h=$1
  shift
  jq -n '{version: 1, layouts: ($ARGS.positional | map({key: .uuid, value: .}) | from_entries)}' --jsonargs "$@" >"$(record_json "${h}")"
}
# キーの順と形によらない 1 行: custom-layouts の並び / 期待する並び / 記録の中身 / 期待する記録の中身
pcl_list() { jq -c -S '.["custom-layouts"]' "$1" 2>/dev/null; }
want_list() { jq -n -c -S '$ARGS.positional' --jsonargs "$@"; }
rec_layouts() { jq -c -S '.layouts' "$1" 2>/dev/null; }
want_rec() { jq -n -c -S '$ARGS.positional | map({key: .uuid, value: .}) | from_entries' --jsonargs "$@"; }
# ファイルの中身が $2 とバイト列まで同じか (末尾の改行も比べる)
file_is() {
  local have
  have=$(
    cat "$1" 2>/dev/null
    printf x
  )
  [[ ${have} == "$2x" ]]
}
# PowerToys の形か (字下げ 2 で整えて CRLF にし、末尾の改行を外したものと同じ)
pt_form() {
  local body
  body=$(jq --indent 2 . "$1" 2>/dev/null) || return 1
  file_is "$1" "${body//$'\n'/$'\r\n'}"
}
# 退避の数と、いちばん新しい退避のディレクトリ (名前の順の最後。末尾に /)
nbackups() {
  local n=0 d
  for d in "$(backup_root "$1")"/*/; do
    if [[ -d ${d} ]]; then
      n=$((n + 1))
    fi
  done
  echo "${n}"
}
newest_backup() {
  local last="" d
  for d in "$(backup_root "$1")"/*/; do
    if [[ -d ${d} ]]; then
      last=${d}
    fi
  done
  echo "${last}"
}
# stderr が警告の形 (!! の行と、3 つの空白で始まる続きの行) だけか (jq・mv などの素のエラーを混ぜていないか)
err_only_warnings() { ! grep -qvE '^(!! |   )' "$1/err"; }

# 30. この PC (PF5XF47R) の形: PC にだけあるレイアウトが 2 つある。repo の 2 つを末尾に足し、PC のものと applied-layouts.json には
#     触らない。PowerToys の形で書き、mv の後に touch する。書き換える前のファイルを退避し、記録を書く。警告は出さない
h=$(new_home t30 "${state_on}")
put_fz "${h}" "$(fz_settings true)"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}" "${lay_b}")"
put_pcl "${h}" "$(pt_layouts "${lay_p1}" "${lay_p2}")"
before_pcl=$(cat "$(pcl_json "${h}")")
printf 'keep' >"$(fz_dir "${h}")/applied-layouts.json"
DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
pcl=$(pcl_json "${h}")
if [[ $(rc "${h}") == 0 && $(pcl_list "${pcl}") == "$(want_list "${lay_p1}" "${lay_p2}" "${lay_a}" "${lay_b}")" ]] && pt_form "${pcl}" \
  && [[ $(fs_calls "${h}") == "mv ${pcl},touch ${pcl},mv $(record_json "${h}")," && ! -e ${pcl}.dotfiles-tmp ]] && recent_mtime "${pcl}" \
  && [[ $(cat "$(fz_dir "${h}")/applied-layouts.json") == keep ]] \
  && [[ $(nbackups "${h}") == 1 ]] && file_is "$(newest_backup "${h}")custom-layouts.json" "${before_pcl}" \
  && [[ $(rec_layouts "$(record_json "${h}")") == "$(want_rec "${lay_a}" "${lay_b}")" ]] \
  && seen "${h}" -F '4k-43inch: 足す' && seen "${h}" -F '1080p: 足す' \
  && seen "${h}" -F 'PC にだけあるレイアウトには触りません: Custom layout 1、Custom layout 2' \
  && [[ ! -s ${h}/err && ! -s ${h}/warnings ]]; then
  ok "レイアウト: PC に無いものを末尾に足し、PC にだけあるものに触らず、PowerToys の形で書いて touch し、退避と記録を残す"
else
  ng "レイアウトを足す" "rc=$(rc "${h}") calls=$(fs_calls "${h}") list=$(pcl_list "${pcl}") backups=$(nbackups "${h}") $(outerr "${h}")"
fi

# 31. 次の回: 揃っているので書かない (LastWriteTime も変えない)。PC にだけあるものの数も出す
touch -d '2020-01-01 00:00:00' "${pcl}"
before_mtime=$(stat -c %Y "${pcl}")
: >"${h}/fs-calls"
run "${h}"
if [[ $(rc "${h}") == 0 && ! -s ${h}/fs-calls && $(stat -c %Y "${pcl}") == "${before_mtime}" && $(nbackups "${h}") == 1 ]] \
  && seen "${h}" -F 'FancyZones のカスタムレイアウトは揃っています (dotfiles のもの 2 件。PC にだけあるもの 2 件には触りません)。' \
  && [[ ! -s ${h}/err ]]; then
  ok "レイアウト: 揃っていれば書かず、LastWriteTime も変えない"
else
  ng "レイアウトが揃っている" "rc=$(rc "${h}") calls=$(fs_calls "${h}") $(outerr "${h}")"
fi

# 32. pjp-raiden の形: PC が repo と同じ中身 (キーの順・字下げ・改行が違う)。書かずに記録だけする
h=$(new_home t32 "${state_on}")
put_fz "${h}" "$(fz_settings true)"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}" "${lay_b}")"
pc_body=$(jq -c '{"custom-layouts": [.[] | {info, type, name, uuid}]}' <<<"[${lay_a},${lay_b}]")$'\n'
put_pcl "${h}" "${pc_body}"
run "${h}"
if [[ $(rc "${h}") == 0 && $(fs_calls "${h}") == "mv $(record_json "${h}")," && $(nbackups "${h}") == 0 ]] && file_is "$(pcl_json "${h}")" "${pc_body}" \
  && [[ $(rec_layouts "$(record_json "${h}")") == "$(want_rec "${lay_a}" "${lay_b}")" ]] \
  && seen "${h}" -F 'FancyZones のカスタムレイアウトは揃っています (dotfiles のもの 2 件)。'; then
  ok "レイアウト: PC が repo と同じ中身なら (キーの順・字下げ・改行が違っても) 書かずに記録だけする"
else
  ng "記録だけする" "rc=$(rc "${h}") calls=$(fs_calls "${h}") rec=$(rec_layouts "$(record_json "${h}")") $(outerr "${h}")"
fi

# 33. repo の更新: PC が記録と同じ (前に足したまま) なら、同じ位置で書き換える。同じものは書き換えの行に出さない
h=$(new_home t33 "${state_on}")
put_fz "${h}" "$(fz_settings true)"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}" "${lay_b}")"
put_pcl "${h}" "$(pt_layouts "${lay_p1}" "${lay_a_old}" "${lay_b}")"
put_record "${h}" "${lay_a_old}" "${lay_b}"
before_pcl=$(cat "$(pcl_json "${h}")")
DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
if [[ $(rc "${h}") == 0 && $(pcl_list "$(pcl_json "${h}")") == "$(want_list "${lay_p1}" "${lay_a}" "${lay_b}")" ]] && pt_form "$(pcl_json "${h}")" \
  && [[ $(rec_layouts "$(record_json "${h}")") == "$(want_rec "${lay_a}" "${lay_b}")" ]] \
  && file_is "$(newest_backup "${h}")custom-layouts.json" "${before_pcl}" \
  && seen "${h}" -F '4k-43inch: 書き換える (repo が更新された)' && ! seen "${h}" -F '1080p:' && [[ ! -s ${h}/warnings ]]; then
  ok "レイアウト: PC が記録と同じなら、repo の更新として同じ位置で書き換える"
else
  ng "repo の更新" "rc=$(rc "${h}") list=$(pcl_list "$(pcl_json "${h}")") $(outerr "${h}")"
fi

# 34. PC のエディターで直した (記録と違う): 書き換えずに警告し (まとめにも残す)、--force と --import を出す。diff はその場にだけ
#     出す。記録は変えない
h=$(new_home t34 "${state_on}")
put_fz "${h}" "$(fz_settings true)"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}" "${lay_b}")"
put_pcl "${h}" "$(pt_layouts "${lay_a_edited}" "${lay_b}" "${lay_p1}")"
put_record "${h}" "${lay_a}" "${lay_b}"
before_pcl=$(cat "$(pcl_json "${h}")")
DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
if [[ $(rc "${h}") == 0 && ! -e ${h}/fs-calls ]] && file_is "$(pcl_json "${h}")" "${before_pcl}" \
  && [[ $(rec_layouts "$(record_json "${h}")") == "$(want_rec "${lay_a}" "${lay_b}")" ]] \
  && grep -qF '4k-43inch: PC のエディターで直されています' "${h}/err" && grep -qF '4k-43inch: PC のエディターで直されています' "${h}/warnings" \
  && grep -qF 'bootstrap-windows-fancyzones.sh --force' "${h}/err" && grep -qF -- "bootstrap-windows-fancyzones.sh --import '4k-43inch'" "${h}/err" \
  && grep -qF -- '--- 4k-43inch (PC)' "${h}/err" && grep -qF -- '+++ 4k-43inch (repo)' "${h}/err" && grep -qF '"X": 10' "${h}/err" \
  && ! grep -qF -- '--- 4k-43inch' "${h}/warnings" && ! grep -qF '1080p' "${h}/warnings"; then
  ok "レイアウト: PC で直されていたら書き換えずに警告し、--force・--import と diff を出す (diff はまとめに入れない)"
else
  ng "PC で直した" "rc=$(rc "${h}") calls=$(fs_calls "${h}") warnings=$(warnings "${h}") $(outerr "${h}")"
fi

# 35. 足す前から PC にあり、中身が違う (記録が無い。PC で名前も変えた): 書き換えずに警告し、PC の名前で --import を出す。記録は作らない
h=$(new_home t35 "${state_on}")
put_fz "${h}" "$(fz_settings true)"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}")"
put_pcl "${h}" "$(pt_layouts "${lay_a_renamed}")"
before_pcl=$(cat "$(pcl_json "${h}")")
DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
if [[ $(rc "${h}") == 0 && ! -e ${h}/fs-calls && ! -e $(record_json "${h}") ]] && file_is "$(pcl_json "${h}")" "${before_pcl}" \
  && grep -qF '4k-43inch: dotfiles が足す前から PC にあり、repo と中身が違います' "${h}/warnings" \
  && grep -qF 'PC での名前は「4k-renamed」' "${h}/err" && grep -qF -- "--import '4k-renamed'" "${h}/err"; then
  ok "レイアウト: 足す前から PC に違う中身があれば書き換えずに警告し、PC の名前で --import を出す"
else
  ng "足す前から違う" "rc=$(rc "${h}") calls=$(fs_calls "${h}") $(outerr "${h}")"
fi

# 36. PC から消えている (記録はある): 足し直さずに警告する。--import は出さない (PC に無いので取り込めない)。記録は変えない
h=$(new_home t36 "${state_on}")
put_fz "${h}" "$(fz_settings true)"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}" "${lay_b}")"
put_pcl "${h}" "$(pt_layouts "${lay_b}" "${lay_p1}")"
put_record "${h}" "${lay_a}" "${lay_b}"
before_pcl=$(cat "$(pcl_json "${h}")")
DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
if [[ $(rc "${h}") == 0 && ! -e ${h}/fs-calls ]] && file_is "$(pcl_json "${h}")" "${before_pcl}" \
  && [[ $(rec_layouts "$(record_json "${h}")") == "$(want_rec "${lay_a}" "${lay_b}")" ]] \
  && grep -qF '4k-43inch: PC から消えています' "${h}/warnings" && grep -qF 'bootstrap-windows-fancyzones.sh --force' "${h}/err" \
  && ! grep -qF -- '--import' "${h}/err"; then
  ok "レイアウト: PC から消えていたら足し直さずに警告し、--import は出さない"
else
  ng "PC から消えた" "rc=$(rc "${h}") calls=$(fs_calls "${h}") $(outerr "${h}")"
fi

# 37. --force: 直されたものを repo の中身へ戻し (同じ位置)、消えていたものを足し直す。書き換える前を退避し、記録する
h=$(new_home t37 "${state_on}")
put_fz "${h}" "$(fz_settings true)"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}" "${lay_b}")"
put_pcl "${h}" "$(pt_layouts "${lay_p1}" "${lay_a_edited}")"
put_record "${h}" "${lay_a}" "${lay_b}"
before_pcl=$(cat "$(pcl_json "${h}")")
DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}" --force
if [[ $(rc "${h}") == 0 && $(pcl_list "$(pcl_json "${h}")") == "$(want_list "${lay_p1}" "${lay_a}" "${lay_b}")" ]] && pt_form "$(pcl_json "${h}")" \
  && file_is "$(newest_backup "${h}")custom-layouts.json" "${before_pcl}" \
  && [[ $(rec_layouts "$(record_json "${h}")") == "$(want_rec "${lay_a}" "${lay_b}")" ]] \
  && seen "${h}" -F '4k-43inch: 書き換える (--force)' && seen "${h}" -F '1080p: 足し直す (--force。PC に無かった)' \
  && [[ ! -s ${h}/warnings ]]; then
  ok "レイアウト: --force は直されたものを戻し、消えていたものを足し直す (退避して記録する)"
else
  ng "--force" "rc=$(rc "${h}") list=$(pcl_list "$(pcl_json "${h}")") $(outerr "${h}")"
fi

# 38. PC にファイルが無い: 記録があっても (PowerToys の設定を消した後など)、repo のレイアウトだけで作る (PowerToys の形のバイト列)。
#     退避するものは無い
h=$(new_home t38 "${state_on}")
put_fz "${h}" "$(fz_settings true)"
put_repo_layouts "${h}" "$(pt_layouts "${lay_t}")"
put_record "${h}" "${lay_t}"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && file_is "$(pcl_json "${h}")" "${want_t}" \
  && [[ $(fs_calls "${h}") == "mv $(pcl_json "${h}"),touch $(pcl_json "${h}")," && $(nbackups "${h}") == 0 ]] \
  && seen "${h}" -F 't: 足す' && seen "${h}" -F 'custom-layouts.json が無いので作る' && [[ ! -s ${h}/err ]]; then
  ok "レイアウト: PC にファイルが無ければ、記録によらず repo のレイアウトだけで作る"
else
  ng "ファイルが無い" "rc=$(rc "${h}") calls=$(fs_calls "${h}") $(outerr "${h}")"
fi

# 38b. FancyZones のディレクトリも無い: settings.json と一緒に作る
h=$(new_home t38b "${state_on}")
put_repo_layouts "${h}" "$(pt_layouts "${lay_t}")"
run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "${created}" ]] && file_is "$(pcl_json "${h}")" "${want_t}"; then
  ok "レイアウト: FancyZones のディレクトリが無ければ、settings.json と一緒に作る"
else
  ng "ディレクトリが無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 39. --dry-run: 何も書かない (退避も記録もしない)。足すものと、PC にだけあるものに触らないことを出す
h=$(new_home t39 "${state_on}")
put_fz "${h}" "$(fz_settings true)"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}" "${lay_b}")"
put_pcl "${h}" "$(pt_layouts "${lay_p1}" "${lay_p2}")"
before_pcl=$(cat "$(pcl_json "${h}")")
run "${h}" --dry-run
if [[ $(rc "${h}") == 0 && ! -e ${h}/fs-calls && ! -e $(record_json "${h}") && ! -e $(backup_root "${h}") ]] && file_is "$(pcl_json "${h}")" "${before_pcl}" \
  && seen "${h}" -F '[dry-run] 4k-43inch: 足す' && seen "${h}" -F '[dry-run] 1080p: 足す' \
  && seen "${h}" -F 'PC にだけあるレイアウトには触りません: Custom layout 1、Custom layout 2'; then
  ok "レイアウト: --dry-run は何も書かず、足すものと PC にだけあるものに触らないことを出す"
else
  ng "レイアウトの --dry-run" "rc=$(rc "${h}") calls=$(fs_calls "${h}") $(outerr "${h}")"
fi

# 39b. --dry-run --force も書かない。--force の判定を出す
h=$(new_home t39b "${state_on}")
put_fz "${h}" "$(fz_settings true)"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}")"
put_pcl "${h}" "$(pt_layouts "${lay_a_edited}")"
put_record "${h}" "${lay_a}"
before_pcl=$(cat "$(pcl_json "${h}")")
run "${h}" --dry-run --force
if [[ $(rc "${h}") == 0 && ! -e ${h}/fs-calls && ! -e $(backup_root "${h}") ]] && file_is "$(pcl_json "${h}")" "${before_pcl}" \
  && seen "${h}" -F '[dry-run] 4k-43inch: 書き換える (--force)'; then
  ok "レイアウト: --dry-run --force は書かずに --force の判定を出す"
else
  ng "--dry-run --force" "rc=$(rc "${h}") calls=$(fs_calls "${h}") $(outerr "${h}")"
fi

# 39c. --dry-run でファイルもディレクトリも無い: 作らない
h=$(new_home t39c "${state_on}")
put_repo_layouts "${h}" "$(pt_layouts "${lay_t}")"
run "${h}" --dry-run
if [[ $(rc "${h}") == 0 && ! -e $(fz_dir "${h}") && ! -e ${h}/fs-calls ]] && seen "${h}" -F '[dry-run] t: 足す'; then
  ok "レイアウト: --dry-run はファイルもディレクトリも作らない"
else
  ng "--dry-run で作らない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 39d. --dry-run は、揃っていて記録だけするときも記録を書かない
h=$(new_home t39d "${state_on}")
put_fz "${h}" "$(fz_settings true)"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}")"
put_pcl "${h}" "$(pt_layouts "${lay_a}")"
run "${h}" --dry-run
if [[ $(rc "${h}") == 0 && ! -e ${h}/fs-calls && ! -e $(record_json "${h}") ]] && seen "${h}" -F 'カスタムレイアウトは揃っています'; then
  ok "レイアウト: --dry-run は、揃っていて記録だけするときも記録を書かない"
else
  ng "--dry-run で記録しない" "rc=$(rc "${h}") calls=$(fs_calls "${h}") $(outerr "${h}")"
fi

# 40. repo から消したレイアウト: PC からは消さず、記録からだけ消す
h=$(new_home t40 "${state_on}")
put_fz "${h}" "$(fz_settings true)"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}" "${lay_b}")"
put_pcl "${h}" "$(pt_layouts "${lay_p1}" "${lay_a}" "${lay_b}")"
put_record "${h}" "${lay_p1}" "${lay_a}" "${lay_b}"
before_pcl=$(cat "$(pcl_json "${h}")")
run "${h}"
if [[ $(rc "${h}") == 0 && $(fs_calls "${h}") == "mv $(record_json "${h}")," ]] && file_is "$(pcl_json "${h}")" "${before_pcl}" \
  && [[ $(rec_layouts "$(record_json "${h}")") == "$(want_rec "${lay_a}" "${lay_b}")" ]]; then
  ok "レイアウト: repo から消したものは PC から消さず、記録からだけ消す"
else
  ng "repo から消した" "rc=$(rc "${h}") calls=$(fs_calls "${h}") rec=$(rec_layouts "$(record_json "${h}")") $(outerr "${h}")"
fi

# 40b. repo のレイアウトを全部消した: PC のファイルは読まずに (読めなくても)、記録を空にする
h=$(new_home t40b "${state_on}")
put_fz "${h}" "$(fz_settings true)"
put_pcl "${h}" 'not json'
put_record "${h}" "${lay_a}"
run "${h}"
if [[ $(rc "${h}") == 0 && $(rec_layouts "$(record_json "${h}")") == '{}' && $(nsleep "${h}") == 0 && ! -s ${h}/err ]] \
  && [[ $(cat "$(pcl_json "${h}")") == 'not json' ]]; then
  ok "レイアウト: repo にレイアウトが無ければ PC のファイルを読まず、記録を空にする"
else
  ng "repo のレイアウトが無い" "rc=$(rc "${h}") sleep=$(nsleep "${h}") $(outerr "${h}")"
fi

# 41. PC のファイルを読めない: 5 回読んでから警告し、書かない (記録も)。settings.json の手順は進む
for t in "broken:not json" "empty:" 'notarray:{"custom-layouts":{}}' "array:[1]"; do
  name=${t%%:*}
  body=${t#*:}
  h=$(new_home "t41-${name}" "${state_on}")
  put_fz "${h}" "$(fz_settings false)"
  put_repo_layouts "${h}" "$(pt_layouts "${lay_a}")"
  put_pcl "${h}" "${body}"
  DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
  if [[ $(rc "${h}") == 0 && $(cat "$(pcl_json "${h}")") == "${body}" && $(nsleep "${h}") == 5 && ! -e $(record_json "${h}") ]] \
    && [[ $(cat "$(fz_json "${h}")") == "$(fz_settings true)" ]] \
    && grep -q 'custom-layouts.json を読めない' "${h}/err" && grep -q 'custom-layouts.json を読めない' "${h}/warnings"; then
    ok "レイアウト: PC のファイルが読めなければ (${name}) 5 回読んでから警告し、書かない (settings.json は書く)"
  else
    ng "PC のファイルが読めない (${name})" "rc=$(rc "${h}") sleep=$(nsleep "${h}") $(outerr "${h}")"
  fi
done

# 41b. 書いている途中に当たっても、読めるようになれば足す
h=$(new_home t41b "${state_on}")
put_fz "${h}" "$(fz_settings true)"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}")"
put_pcl "${h}" '{"custom-layouts":[{"uu'
FAKE_SLEEP_PATH=$(pcl_json "${h}") FAKE_SLEEP_AT=2 FAKE_SLEEP_WRITE=$(pt_layouts "${lay_p1}") run "${h}"
if [[ $(rc "${h}") == 0 && $(pcl_list "$(pcl_json "${h}")") == "$(want_list "${lay_p1}" "${lay_a}")" && $(nsleep "${h}") == 2 ]] \
  && ! seen "${h}" '読めない'; then
  ok "レイアウト: 書いている途中に当たっても、読めるようになれば足す"
else
  ng "レイアウトの書いている途中" "rc=$(rc "${h}") sleep=$(nsleep "${h}") $(outerr "${h}")"
fi

# 42. 記録が壊れている: レイアウトは書かずに警告する (記録もそのまま)。settings.json の手順は進む
i=0
for body in 'not json' '{"version":1,"layouts":[]}'; do
  i=$((i + 1))
  h=$(new_home "t42-${i}" "${state_on}")
  put_fz "${h}" "$(fz_settings false)"
  put_repo_layouts "${h}" "$(pt_layouts "${lay_a}")"
  put_pcl "${h}" "$(pt_layouts "${lay_p1}")"
  before_pcl=$(cat "$(pcl_json "${h}")")
  printf '%s' "${body}" >"$(record_json "${h}")"
  DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
  if [[ $(rc "${h}") == 0 && $(cat "$(record_json "${h}")") == "${body}" && $(cat "$(fz_json "${h}")") == "$(fz_settings true)" ]] \
    && file_is "$(pcl_json "${h}")" "${before_pcl}" && grep -q '記録が壊れている' "${h}/warnings"; then
    ok "レイアウト: 記録が壊れていれば (${i}) 書かずに警告する (settings.json は書く)"
  else
    ng "記録が壊れている (${i})" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
done

# 43. repo の custom-layouts.json に誤りがある (uuid が重なる): レイアウトは書かずに警告する。settings.json の手順は進む
h=$(new_home t43 "${state_on}")
put_fz "${h}" "$(fz_settings false)"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}" "${lay_a_old}")"
put_pcl "${h}" "$(pt_layouts "${lay_p1}")"
before_pcl=$(cat "$(pcl_json "${h}")")
DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "$(fz_settings true)" ]] && file_is "$(pcl_json "${h}")" "${before_pcl}" \
  && grep -q 'custom-layouts.json に誤りがある' "${h}/warnings" && grep -qF 'uuid が重なっています' "${h}/warnings"; then
  ok "レイアウト: repo の custom-layouts.json に誤りがあれば書かずに警告する (settings.json は書く)"
else
  ng "repo の誤り" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 44. managed.json に誤りがあっても、レイアウトは足す
h=$(new_home t44 "${state_on}")
put_fz "${h}" "$(fz_settings false)"
printf '%s' 'not json' >"$(managed_json "${h}")"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}")"
put_pcl "${h}" "$(pt_layouts "${lay_p1}")"
DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
if [[ $(rc "${h}") == 0 && $(pcl_list "$(pcl_json "${h}")") == "$(want_list "${lay_p1}" "${lay_a}")" && $(cat "$(fz_json "${h}")") == "$(fz_settings false)" ]] \
  && grep -q 'managed.json に誤りがある' "${h}/warnings"; then
  ok "レイアウト: managed.json に誤りがあっても、レイアウトは足す"
else
  ng "managed.json の誤りとレイアウト" "rc=$(rc "${h}") list=$(pcl_list "$(pcl_json "${h}")") $(outerr "${h}")"
fi

# 45. 書けない (mv できない・一時ファイルを作れない・退避できない): 元のまま警告して exit 0。一時ファイルを残さず、素のエラーを
#     混ぜない。記録に足さない
for t in mv tmpdir backup; do
  h=$(new_home "t45-${t}" "${state_on}")
  put_fz "${h}" "$(fz_settings true)"
  put_repo_layouts "${h}" "$(pt_layouts "${lay_a}")"
  put_pcl "${h}" "$(pt_layouts "${lay_p1}")"
  before_pcl=$(cat "$(pcl_json "${h}")")
  want_calls=""
  msg='custom-layouts.json に書けない'
  case ${t} in
    mv) want_calls="mv $(pcl_json "${h}")," ;;
    tmpdir) mkdir "$(pcl_json "${h}").dotfiles-tmp" ;;
    backup)
      mkdir -p "$(dirname "$(backup_root "${h}")")"
      printf 'file' >"$(backup_root "${h}")"
      msg='退避できない'
      ;;
  esac
  if [[ ${t} == mv ]]; then
    FAKE_MV_FAIL=1 DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
  else
    DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
  fi
  if [[ $(rc "${h}") == 0 && $(fs_calls "${h}") == "${want_calls}" && ! -f $(pcl_json "${h}").dotfiles-tmp && ! -e $(record_json "${h}") ]] \
    && file_is "$(pcl_json "${h}")" "${before_pcl}" && grep -q "${msg}" "${h}/warnings" && err_only_warnings "${h}"; then
    ok "レイアウト: 書けなければ (${t}) 元のまま警告して exit 0 (素のエラーを混ぜず、記録に足さない)"
  else
    ng "レイアウトが書けない (${t})" "rc=$(rc "${h}") calls=$(fs_calls "${h}") $(outerr "${h}")"
  fi
done

# 45b. touch できない: 書いたうえで、読み直させられなかったと警告する (記録は書く)
h=$(new_home t45b "${state_on}")
put_fz "${h}" "$(fz_settings true)"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}")"
put_pcl "${h}" "$(pt_layouts "${lay_p1}")"
FAKE_TOUCH_FAIL=1 DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
if [[ $(rc "${h}") == 0 && $(pcl_list "$(pcl_json "${h}")") == "$(want_list "${lay_p1}" "${lay_a}")" ]] \
  && [[ $(rec_layouts "$(record_json "${h}")") == "$(want_rec "${lay_a}")" ]] \
  && grep -q 'custom-layouts.json に書きましたが' "${h}/warnings" && err_only_warnings "${h}"; then
  ok "レイアウト: touch できなければ、書いたうえで読み直させられなかったと警告する"
else
  ng "レイアウトの touch できない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 45c. 一時ディレクトリを作れない (TMPDIR が無い): レイアウトは書かずに警告して exit 0。settings.json の手順は進む
h=$(new_home t45c "${state_on}")
put_fz "${h}" "$(fz_settings false)"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}")"
put_pcl "${h}" "$(pt_layouts "${lay_p1}")"
before_pcl=$(cat "$(pcl_json "${h}")")
TMPDIR=${h}/no-such-dir DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "$(fz_json "${h}")") == "$(fz_settings true)" ]] && file_is "$(pcl_json "${h}")" "${before_pcl}" \
  && grep -q '一時ディレクトリを作れない' "${h}/warnings" && err_only_warnings "${h}"; then
  ok "レイアウト: 一時ディレクトリを作れなければ、書かずに警告して exit 0 (settings.json は書く)"
else
  ng "一時ディレクトリを作れない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 46. 退避は新しい方から 10 回分だけ残す
h=$(new_home t46 "${state_on}")
put_fz "${h}" "$(fz_settings true)"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}")"
put_pcl "${h}" "$(pt_layouts "${lay_p1}")"
for i in 00 01 02 03 04 05 06 07 08 09 10 11; do
  mkdir -p "$(backup_root "${h}")/20200101T0000${i}Z-1"
done
run "${h}"
broot=$(backup_root "${h}")
if [[ $(rc "${h}") == 0 && $(nbackups "${h}") == 10 && ! -e ${broot}/20200101T000002Z-1 && -d ${broot}/20200101T000003Z-1 ]] \
  && file_is "$(newest_backup "${h}")custom-layouts.json" "$(pt_layouts "${lay_p1}")"; then
  ok "レイアウト: 退避は新しい方から 10 回分だけ残す"
else
  ng "退避の数" "rc=$(rc "${h}") n=$(nbackups "${h}") $(outerr "${h}")"
fi

# 47. 書き直しても、PC にだけあるレイアウトの名前のエスケープと、custom-layouts のほかのキーの中身は変わらない
h=$(new_home t47 "${state_on}")
put_fz "${h}" "$(fz_settings true)"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}")"
put_pcl "${h}" $'{\r\n  "custom-layouts": [\r\n    {\r\n      "uuid": "{2CAEB420-AB4C-4F3F-9226-1A98F049EDBF}",\r\n      "name": "\\u7E26\\u0026\\u6A2A",\r\n      "type": "canvas",\r\n      "info": {\r\n        "ref-width": 1536,\r\n        "ref-height": 912,\r\n        "zones": [],\r\n        "sensitivity-radius": 20\r\n      }\r\n    }\r\n  ],\r\n  "x-extra": {\r\n    "k": 1\r\n  }\r\n}'
run "${h}"
if [[ $(rc "${h}") == 0 && $(jq -r '[.["custom-layouts"][].name] | join(",")' "$(pcl_json "${h}")") == '縦&横,4k-43inch' ]] \
  && [[ $(jq -c '.["x-extra"]' "$(pcl_json "${h}")") == '{"k":1}' ]] && seen "${h}" -F 'PC にだけあるレイアウトには触りません: 縦&横'; then
  ok "レイアウト: 書き直しても、名前のエスケープとほかのキーの中身は変わらない"
else
  ng "エスケープとほかのキー" "rc=$(rc "${h}") $(cat "$(pcl_json "${h}")") $(outerr "${h}")"
fi

# --import のケースの checkout: repo のレイアウトは 4k-43inch・1080p で commit 済み。settings.json は false (書かないことを見る)
import_home() {
  local h
  h=$(new_home "$1" "${state_on}")
  put_fz "${h}" "$(fz_settings false)"
  put_repo_layouts "${h}" "$(pt_layouts "${lay_a}" "${lay_b}")"
  git -c init.defaultBranch=main -C "${h}/repo" init -q >/dev/null 2>&1
  git -C "${h}/repo" add -A >/dev/null 2>&1
  git -C "${h}/repo" -c user.name=test -c user.email=test@example.com commit -q -m init >/dev/null 2>&1
  echo "${h}"
}
# repo の custom-layouts.json が commit した中身のままか
repo_clean() { git -C "$1/repo" diff --quiet; }
# script が出す checkout のパス (script は自分の場所を pwd -P で引く)
repo_phys() { (cd "$1/repo" && pwd -P); }

# 48. --import: PC で直したレイアウトを、repo の同じ uuid の位置へ PowerToys の形で写す。PC のファイル・settings.json・記録には
#     書かない。git diff と commit を促す
h=$(import_home t48)
put_pcl "${h}" "$(pt_layouts "${lay_a_edited}" "${lay_p1}")"
before_pcl=$(cat "$(pcl_json "${h}")")
run "${h}" --import 4k-43inch
if [[ $(rc "${h}") == 0 && $(pcl_list "$(layouts_json "${h}")") == "$(want_list "${lay_a_edited}" "${lay_b}")" ]] && pt_form "$(layouts_json "${h}")" \
  && file_is "$(pcl_json "${h}")" "${before_pcl}" && [[ $(cat "$(fz_json "${h}")") == "$(fz_settings false)" && ! -e $(record_json "${h}") ]] \
  && [[ $(fs_calls "${h}") == "mv $(repo_phys "${h}")/win/powertoys/fancyzones/custom-layouts.json," ]] \
  && seen "${h}" -F "git -C $(repo_phys "${h}") diff"; then
  ok "--import: PC で直したレイアウトを repo の同じ位置へ写し、PC のファイル・settings.json・記録には書かない"
else
  ng "--import" "rc=$(rc "${h}") calls=$(fs_calls "${h}") list=$(pcl_list "$(layouts_json "${h}")") $(outerr "${h}")"
fi

# 48b. --import: repo に無いレイアウト (PC で作った) は末尾に足す。--import=<名前> と繰り返しも受ける
h=$(import_home t48b)
put_pcl "${h}" "$(pt_layouts "${lay_a_edited}" "${lay_p1}")"
run "${h}" --import='Custom layout 1' --import 4k-43inch
if [[ $(rc "${h}") == 0 && $(pcl_list "$(layouts_json "${h}")") == "$(want_list "${lay_a_edited}" "${lay_b}" "${lay_p1}")" ]] && pt_form "$(layouts_json "${h}")"; then
  ok "--import: repo に無いものは末尾に足し、--import=<名前> と繰り返しも受ける"
else
  ng "--import で足す" "rc=$(rc "${h}") list=$(pcl_list "$(layouts_json "${h}")") $(outerr "${h}")"
fi

# 48c. --import: repo と同じなら書かない
h=$(import_home t48c)
put_pcl "${h}" "$(pt_layouts "${lay_a}")"
run "${h}" --import 4k-43inch
if [[ $(rc "${h}") == 0 && ! -e ${h}/fs-calls ]] && repo_clean "${h}" && seen "${h}" '取り込むものはありません'; then
  ok "--import: repo と同じなら書かない"
else
  ng "--import で同じ" "rc=$(rc "${h}") calls=$(fs_calls "${h}") $(outerr "${h}")"
fi

# 48d. --import の誤り: 何も書かずに exit 1 (PC に無い名前・PC に 2 つある名前・repo の別の uuid と同じ名前・repo に置けない形)
for t in missing dup samename bad; do
  h=$(import_home "t48d-${t}")
  case ${t} in
    missing)
      put_pcl "${h}" "$(pt_layouts "${lay_p1}")"
      arg=nope
      msg='PC に「nope」というカスタムレイアウトがありません (PC にあるもの: Custom layout 1)'
      ;;
    dup)
      put_pcl "${h}" "$(pt_layouts "${lay_p1}" "${lay_p1_dup}")"
      arg='Custom layout 1'
      msg='PC に「Custom layout 1」というカスタムレイアウトが 2 つあります'
      ;;
    samename)
      put_pcl "${h}" "$(pt_layouts "${lay_b_other}")"
      arg=1080p
      msg='repo に、同じ名前「1080p」の別のレイアウトがあります'
      ;;
    bad)
      put_pcl "${h}" "$(pt_layouts "${lay_low}")"
      arg=low
      msg='「low」は repo に置けない形です'
      ;;
  esac
  run "${h}" --import "${arg}"
  if [[ $(rc "${h}") == 1 && ! -e ${h}/fs-calls ]] && repo_clean "${h}" && grep -qF "${msg}" "${h}/err"; then
    ok "--import: ${t} は何も書かずに exit 1"
  else
    ng "--import の誤り (${t})" "rc=$(rc "${h}") calls=$(fs_calls "${h}") $(outerr "${h}")"
  fi
done

# 48e. --import: commit していない変更がある・git の checkout でない・配り先の設定が無い: 何も書かずに exit 1
h=$(import_home t48e-dirty)
put_pcl "${h}" "$(pt_layouts "${lay_a_edited}")"
printf ' ' >>"$(layouts_json "${h}")"
dirty=$(
  cat "$(layouts_json "${h}")"
  printf x
)
run "${h}" --import 4k-43inch
if [[ $(rc "${h}") == 1 && ! -e ${h}/fs-calls ]] && file_is "$(layouts_json "${h}")" "${dirty%x}" && grep -qF 'commit していない変更' "${h}/err"; then
  ok "--import: commit していない変更があれば、何も書かずに exit 1"
else
  ng "--import の commit していない変更" "rc=$(rc "${h}") $(outerr "${h}")"
fi
h=$(new_home t48e-nogit "${state_on}")
put_pcl "${h}" "$(pt_layouts "${lay_a_edited}")"
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}")"
before_repo=$(cat "$(layouts_json "${h}")")
GIT_CEILING_DIRECTORIES=${h} run "${h}" --import 4k-43inch
if [[ $(rc "${h}") == 1 && ! -e ${h}/fs-calls ]] && file_is "$(layouts_json "${h}")" "${before_repo}" && grep -qF '確かめられません' "${h}/err"; then
  ok "--import: git の checkout でなければ、何も書かずに exit 1"
else
  ng "--import で git の checkout でない" "rc=$(rc "${h}") $(outerr "${h}")"
fi
h=$(new_home t48e-nostate "")
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}")"
run "${h}" --import 4k-43inch
if [[ $(rc "${h}") == 1 && ! -e ${h}/fs-calls ]] && grep -qF '配り先の設定がありません' "${h}/err"; then
  ok "--import: 配り先の設定が無ければ exit 1"
else
  ng "--import で配り先の設定が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 48f. --import の引数の誤り: exit 2 (名前が無い・空・--force・--dry-run・--check と一緒)。jq が無ければ exit 1
h=$(import_home t48f)
put_pcl "${h}" "$(pt_layouts "${lay_a_edited}")"
bad_rcs=""
for args in "--import" "--import=" "--import 4k-43inch --force" "--import 4k-43inch --dry-run" "--check --import 4k-43inch"; do
  read -ra argv <<<"${args}"
  run "${h}" "${argv[@]}"
  if [[ $(rc "${h}") != 2 ]]; then
    bad_rcs+=" [${args}]=$(rc "${h}")"
  fi
done
RUN_NO_JQ=1 run "${h}" --import 4k-43inch
rc_nojq=$(rc "${h}")
if [[ -z ${bad_rcs} && ${rc_nojq} == 1 && ! -e ${h}/fs-calls ]] && repo_clean "${h}"; then
  ok "--import: 引数の誤りは exit 2、jq が無ければ exit 1 (どれも書かない)"
else
  ng "--import の引数" "bad=${bad_rcs} nojq=${rc_nojq} $(outerr "${h}")"
fi

# 49. --check: レイアウトの誤りは exit 1 (uuid が小文字・波括弧が無い・無い、name が空、type が無い、info が object でない、
#     object でない要素、uuid の重なり、name の重なり)
bad_layout() { jq -c "$1" <<<"${lay_a}"; }
i=0
for body in \
  "$(pt_layouts "$(bad_layout '.uuid |= ascii_downcase')")" \
  "$(pt_layouts "$(bad_layout '.uuid = "67070A77-52EC-4EC3-9F63-DF5E58CD4400"')")" \
  "$(pt_layouts "$(bad_layout 'del(.uuid)')")" \
  "$(pt_layouts "$(bad_layout '.name = ""')")" \
  "$(pt_layouts "$(bad_layout 'del(.type)')")" \
  "$(pt_layouts "$(bad_layout '.info = []')")" \
  "$(pt_layouts '1')" \
  "$(pt_layouts "${lay_a}" "${lay_a_old}")" \
  "$(pt_layouts "${lay_a}" "$(bad_layout '.uuid = "{00000000-0000-0000-0000-000000000009}"')")"; do
  i=$((i + 1))
  h=$(new_home "t49-${i}" "")
  put_repo_layouts "${h}" "${body}"
  run "${h}" --check
  if [[ $(rc "${h}") == 1 ]] && grep -q 'custom-layouts.json に誤りがあります' "${h}/err"; then
    ok "--check: 誤ったレイアウト (${i}) は exit 1"
  else
    ng "--check のレイアウトの誤り (${i})" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
done

# 49b. --check: PowerToys の形でない (LF・末尾の改行・字下げ 4) は exit 1。PowerToys の形なら、持つキーとレイアウトの数を出して通す
for t in lf trailing indent4; do
  case ${t} in
    lf) body=$(jq -n --indent 2 --argjson a "${lay_a}" '{"custom-layouts": [$a]}') ;;
    trailing) body="$(pt_layouts "${lay_a}")"$'\r\n' ;;
    indent4)
      body=$(jq -n --indent 4 --argjson a "${lay_a}" '{"custom-layouts": [$a]}')
      body=${body//$'\n'/$'\r\n'}
      ;;
  esac
  h=$(new_home "t49b-${t}" "")
  put_repo_layouts "${h}" "${body}"
  run "${h}" --check
  if [[ $(rc "${h}") == 1 ]] && grep -q 'PowerToys の書く形と違います' "${h}/err"; then
    ok "--check: PowerToys の形でない (${t}) は exit 1"
  else
    ng "--check の形 (${t})" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
done
h=$(new_home t49b-ok "")
put_repo_layouts "${h}" "$(pt_layouts "${lay_a}" "${lay_b}")"
run "${h}" --check
if [[ $(rc "${h}") == 0 ]] && seen "${h}" -F 'win/powertoys/fancyzones/: OK (持つキー 1 件・カスタムレイアウト 2 件)'; then
  ok "--check: PowerToys の形のレイアウトは通し、数を出す"
else
  ng "--check のレイアウトの数" "rc=$(rc "${h}") $(outerr "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
