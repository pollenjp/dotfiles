#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-powertoys.sh の振る舞いを、使い捨ての HOME と
# 偽の powershell.exe / pwsh.exe / wslpath / sleep で確かめる。
#
#   bash nix/tests/bootstrap-windows-powertoys.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-powertoys-test) が Nix のサンドボックスで流す。
# 使うのは bash・jq・coreutils・grep・sed だけ。
#
# ## 確かめること
#
#   - 配らないマシン・default.json が無いときは powershell.exe を呼ばずに飛ばす
#   - 送れたら記録し、同じ default.json では呼ばない。変われば呼ぶ。--force なら変わらなくても呼ぶ
#   - PowerToys が動いていない (absent) ときも記録する。interop が使えない・出力がおかしいときは
#     手で読み直す方法を出し、記録しない。どれも exit 0
#   - Keyboard Manager の settings.json が無い・有効なプロファイルが default でないときは、
#     default.json が読まれないので、送らず記録もせずに stderr に案内して exit 0。settings.json が
#     できた後の回では送って記録する
#   - 読み直させる前に Install-PowerToys.ps1 -Check を流し、3 (入っていない) なら -IfMissing で入れる。
#     入っていれば入れない。スクリプトが無い・pwsh.exe が無い・失敗する・入れられないときも、
#     知らせて読み直しへ進む (exit 0)。default.json が無くても、読み直し済みでも確かめる
#   - 偽の timeout が上限の秒数を記録し、-Check は 60 秒・-IfMissing は 600 秒・読み直し (powershell.exe) は
#     60 秒で打つこと、-IfMissing を打つ前に winget で入れることと 600 秒まで待つことを出すことを確かめる。
#     -Check が時間切れなら時間切れと手で打つコマンドを、-IfMissing が時間切れなら ⚠ で囲んで 600 秒
#     待ったことを出し、どちらも読み直しへ進む
#   - 全体の settings.json で Keyboard Manager か自動起動がオフなら、止める → 両方を true に書く → 起動する → 確かめる、
#     の順に進み、ほかの項目を変えず (キーの順も 1 行の形も)、読み直しへ進む。次の回は起動し直さない。両方オンなら
#     止めない・書かない。ファイルが無ければ 2 つだけで作る
#   - オンにできないとき (run_elevated・止められない・powershell.exe が失敗する・PowerToys が無い・書けない・起動できない・
#     エンジンが動かない・設定が読めない・起動の後もオフ) は、警告して exit 0。手順 (入出力・起動時に実行) を出し、止めた後は
#     起動し直す。Keyboard Manager がオフのままなら、記録せず、イベントを送らず、「読み直し済み」「起動したときに読みます」
#     と出さない (前の記録が同じ sha でも)。もともと Keyboard Manager がオンなら、読み直しへ進む
#   - 自動起動のタスクが無いと分かったら警告する。全体の設定を読みかけても (入口でも、起動の後でも)、読み直して確かめる
#   - 全体の設定に書いた後に起動や確認でつまずいたら印を残し、次の回は両方オンでも起動と確認をやり直して、確かめられたら
#     印を消す。確かめるまでは記録しない。書く前につまずいた・書けないときは印を残さない
#   - PowerToys を入れた直後は止める前に、起動した直後は読み直しの前に、Keyboard Manager の settings.json が読めるように
#     なるのを 30 秒まで待つ (空や書きかけでは待ち続ける)。待つときは記録を消し、前の記録が同じ sha でもイベントを送る。
#     それ以外では待たない
#   - script に実行ビットがある (setup.sh は -x でない bootstrap を流さずに止まる)
#   - setup から走るとき (DOTFILES_SETUP_WARNINGS がある) は、警告 (⚠ の枠は見出しと入れるコマンド) を
#     setup の最後のまとめ用のファイルにも残す。何も無ければ残さない
#
# ## 本物の powershell.exe と pwsh.exe を見せない
#
# 本物の powershell.exe と pwsh.exe を見せないよう、要るコマンドだけを symlink で並べた PATH で流す。
# 偽のコマンドの shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-powertoys.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-powertoys-test.XXXXXX")
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

# Install-PowerToys.ps1 -Check の出力 (入っている / 入っていない)
installed_out='PowerToys (winget の Microsoft.PowerToys。版は固定しない)
  入っている場所 : C:\Users\u\AppData\Local\PowerToys\PowerToys.exe
  入っている版   : 0.100.2.0
入っている'
missing_out='PowerToys (winget の Microsoft.PowerToys。版は固定しない)
⚠ 入っている場所 : 入っていない → user スコープで入れる
⚠️ PowerToys が入っていない → Install-PowerToys で入れる ⚠️'
# PowerToys の設定画面が作る Keyboard Manager の settings.json (この PC と同じ形。有効なプロファイルは default)
km_settings='{"properties":{"activeConfiguration":{"value":"default"},"keyboardConfigurations":{"value":["default"]}},"name":"Keyboard Manager","version":"1"}'
# PowerToys の runner が書く全体の settings.json (この PC と同じ形。1 行で末尾に改行なし)。
# $1: enabled["Keyboard Manager"]、$2: startup、$3: run_elevated (省略は false)
global_settings() {
  printf '{"startup":%s,"enabled":{"AdvancedPaste":false,"AlwaysOnTop":true,"Keyboard Manager":%s,"ZoomIt":false},"show_tray_icon":true,"is_elevated":false,"run_elevated":%s,"quick_access_shortcut":{"win":false,"code":0,"key":""},"theme":"system","powertoys_version":"v0.102.3001","ignored_conflict_properties":{"ignored_shortcuts":[]}}' \
    "$2" "$1" "${3:-false}"
}
# Install-PowerToys.ps1 -IfMissing が入れ終えたときの出力
added_out="winget install --id Microsoft.PowerToys --exact --source winget --scope user --silent --accept-source-agreements --disable-interactivity --accept-package-agreements
  Successfully installed

${installed_out%入っている}入った"

sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env jq grep sed tr cat head tail cut mkdir dirname sha256sum timeout od mv rm sleep touch; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# $1: 名前、$2: windows-files.json の中身 (空なら作らない)、
# $3: 1 なら default.json と Keyboard Manager の settings.json と全体の settings.json (両方オン) を置く、
# $4: 1 なら Install-PowerToys.ps1 を配った状態にする (省略は 0)
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.local/state/dotfiles" "${h}/bin" "${h}/win"
  if [[ -n $2 ]]; then
    printf '%s\n' "${2//@WIN@/${h}/win}" >"${h}/.local/state/dotfiles/windows-files.json"
  fi
  if [[ $3 == 1 ]]; then
    mkdir -p "${h}/win/AppData/Local/Microsoft/PowerToys/Keyboard Manager"
    printf '{"remapKeys":{"inProcess":[{"originalKeys":"20","newRemapKeys":"124"}]}}' \
      >"${h}/win/AppData/Local/Microsoft/PowerToys/Keyboard Manager/default.json"
    printf '%s' "${km_settings}" >"$(km_settings_json "${h}")"
    global_settings true true >"$(global_json "${h}")"
  fi
  if [[ ${4:-0} == 1 ]]; then
    mkdir -p "${h}/win/.config/powershell"
    printf '# Install-PowerToys.ps1\n' >"${h}/win/.config/powershell/Install-PowerToys.ps1"
  fi
  # 偽の powershell.exe。引数を記録し、コマンドの中身で分けて、決まった語を CRLF で出して終わる。分け方は ps-steps に残す。
  #   stop  (PToyTrayIconWindow) FAKE_PS_STOP (既定 stopped) / FAKE_PS_STOP_RC。呼ばれた時点の全体の設定を global-at-stop に、
  #                         Keyboard Manager の settings.json があったかを km-settings-at-stop に写す
  #   start (Start-Process) FAKE_PS_START (既定 started) / FAKE_PS_START_RC。呼ばれた時点の全体の設定を global-at-start に写す。
  #                         FAKE_START_WRITES があれば全体の設定をそれで置き換える (起動した runner や設定画面が書く)
  #   wait  (AddSeconds)    FAKE_PS_WAIT (既定 ready task) / FAKE_PS_WAIT_RC
  #   event (ほか)          FAKE_PS_OUT (既定 set) / FAKE_PS_RC
  {
    printf '#!%s\n' "${BASH}"
    printf 'global=%q\n' "$(global_json "${h}")"
    printf 'km=%q\n' "$(km_settings_json "${h}")"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/ps-calls"
case "$*" in
  *PToyTrayIconWindow*)
    step=stop
    cat "${global}" >"${HOME}/global-at-stop" 2>/dev/null
    [[ -e ${km} ]] && echo yes >"${HOME}/km-settings-at-stop"
    out=${FAKE_PS_STOP-stopped}
    rc=${FAKE_PS_STOP_RC:-0}
    ;;
  *Start-Process*)
    step=start
    cat "${global}" >"${HOME}/global-at-start" 2>/dev/null
    if [[ -n ${FAKE_START_WRITES-} ]]; then
      printf '%s' "${FAKE_START_WRITES}" >"${global}"
    fi
    out=${FAKE_PS_START-started}
    rc=${FAKE_PS_START_RC:-0}
    ;;
  *AddSeconds*)
    step=wait
    out=${FAKE_PS_WAIT-ready task}
    rc=${FAKE_PS_WAIT_RC:-0}
    ;;
  *)
    step=event
    out=${FAKE_PS_OUT-set}
    rc=${FAKE_PS_RC:-0}
    ;;
esac
printf '%s\n' "${step}" >>"${HOME}/ps-steps"
printf '%s\r\n' "${out}"
exit "${rc}"
EOF
  } >"${h}/bin/powershell.exe"
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
  # 偽の pwsh.exe (Install-PowerToys.ps1 を呼ぶ)。引数を記録し、出力を行ごとに CRLF で出して終わる。
  # -IfMissing の呼び出しは FAKE_PWSH_OUT2 / FAKE_PWSH_RC2、ほかは FAKE_PWSH_OUT (既定は入っている) / FAKE_PWSH_RC を使う
  {
    printf '#!%s\n' "${BASH}"
    printf 'installed_out=%q\n' "${installed_out}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/pwsh-calls"
case "$*" in
  *-IfMissing*)
    cat "${HOME}/out" >"${HOME}/out-at-ifmissing"
    out=${FAKE_PWSH_OUT2-}
    rc=${FAKE_PWSH_RC2:-0}
    ;;
  *)
    out=${FAKE_PWSH_OUT-${installed_out}}
    rc=${FAKE_PWSH_RC:-0}
    ;;
esac
if [[ -n ${out} ]]; then
  while IFS= read -r l; do printf '%s\r\n' "${l}"; done <<<"${out}"
fi
exit "${rc}"
EOF
  } >"${h}/bin/pwsh.exe"
  # 偽の timeout。上限 (秒) と呼ぶコマンドを記録して、残りをそのまま流す
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s %s\n' "$1" "$2" >>"${HOME}/timeout-calls"
shift
exec "$@"
EOF
  } >"${h}/bin/timeout"
  # 偽の wslpath。-w <パス> を C:\fake\<ファイル名> にする
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
[[ $1 == -w ]] || exit 1
printf 'C:\\fake\\%s\n' "${2##*/}"
EOF
  } >"${h}/bin/wslpath"
  chmod +x "${h}/bin/powershell.exe" "${h}/bin/pwsh.exe" "${h}/bin/wslpath" "${h}/bin/timeout" "${h}/bin/sleep"
  echo "${h}"
}

# $1: HOME、$2: 0 なら偽のコマンドを全部置く。1 なら Windows のコマンドを 1 つも置かない。
# 2 なら pwsh.exe だけ置かない (powershell.exe と wslpath は置く)、残り: script の引数
run() {
  local h=$1 mode=$2
  shift 2
  local path="${h}/bin:${sys_bin}"
  if [[ ${mode} == 1 ]]; then
    path="${sys_bin}"
  elif [[ ${mode} == 2 ]]; then
    mkdir -p "${h}/bin-nopwsh"
    ln -sf "${h}/bin/powershell.exe" "${h}/bin-nopwsh/powershell.exe"
    ln -sf "${h}/bin/wslpath" "${h}/bin-nopwsh/wslpath"
    path="${h}/bin-nopwsh:${sys_bin}"
  fi
  env HOME="${h}" PATH="${path}" "${BASH}" "${script}" "$@" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }
# 判定の grep -q はパイプで受けず、ファイルを直に読む。outerr を grep -q へパイプでつなぐと、grep が
# out で合って先に抜けたあと cat が err を書こうとして SIGPIPE (141) で終わり、pipefail で「合わない」
# に見える (check-test-grep-q.sh が CI の lint で落とす)。$1: ケースのディレクトリ、残り: grep の引数
seen() {
  local d=$1
  shift
  grep -q "$@" "${d}/out" "${d}/err"
}
ncalls() { grep -c '' "$1/ps-calls" 2>/dev/null || echo 0; }
npwsh() { grep -c '' "$1/pwsh-calls" 2>/dev/null || echo 0; }
pwsh_calls() { cat "$1/pwsh-calls" 2>/dev/null; }
# pwsh.exe の呼び出しの記録 (1 回 1 行) に、grep の引数で合う行があるか。記録が無ければ合わない
# (判定はパイプで受けない。seen と同じ)。ほかのテストの pwsh_called (呼ばれたか) とは別のものなので、
# 名前を分ける
pwsh_called_with() {
  local h=$1
  shift
  grep -qs "$@" "${h}/pwsh-calls"
}
# 最後の pwsh.exe の呼び出しが、grep の引数で合うか
pwsh_last_called_with() {
  local h=$1
  shift
  grep -q "$@" <<<"$(tail -n 1 "${h}/pwsh-calls" 2>/dev/null)"
}
record() { echo "$1/.local/state/dotfiles/powertoys-keyboard-manager.reloaded"; }
pending() { echo "$1/.local/state/dotfiles/powertoys-enable.pending"; }
km_settings_json() { echo "$1/win/AppData/Local/Microsoft/PowerToys/Keyboard Manager/settings.json"; }
global_json() { echo "$1/win/AppData/Local/Microsoft/PowerToys/settings.json"; }
# 偽の powershell.exe が受けた順 (stop,start,wait,event,)。呼ばれていなければ空
steps() { [[ ! -e $1/ps-steps ]] || tr '\n' ',' <"$1/ps-steps"; }
nsleep() { grep -c '' "$1/sleep-calls" 2>/dev/null || echo 0; }
# 手でオンにする手順を出したか
manual_seen() { seen "$1" '「入出力」→「Keyboard Manager」' && seen "$1" '「全般」→「起動時に実行」'; }
# Keyboard Manager がオフのままなのに言ってはいけないことを言っていないか
no_false_claim() { ! seen "$1" '読み直し済み' && ! seen "$1" '起動したときに' && ! seen "$1" '読み直させました'; }

state_on='{"enable":true,"version":1,"windowsHome":"@WIN@"}'
state_off='{"enable":false,"version":1,"windowsHome":null}'

echo "== bootstrap-windows-powertoys.sh: ${script}"

# 1. 状態ファイルが無い / enable = false / default.json が無い: 呼ばずに飛ばす
for t in "nostate::1" "off:${state_off}:1" "nojson:${state_on}:0"; do
  name=${t%%:*}
  rest=${t#*:}
  state=${rest%:*}
  json=${rest##*:}
  h=$(new_home "t1-${name}" "${state}" "${json}")
  run "${h}" 0
  if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 0 && ! -e $(record "${h}") ]]; then
    ok "飛ばす (${name}): powershell.exe を呼ばない"
  else
    ng "飛ばす (${name})" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
  fi
done

# 2. 送れた: 記録する。名前付きイベントの名前を渡す
h=$(new_home t2 "${state_on}" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 && -s $(record "${h}") ]] && seen "${h}" '読み直させました' \
  && grep -qF 'PowerToys_KeyboardManager_Event_Settings' "${h}/ps-calls" && grep -qF -- '-NoProfile' "${h}/ps-calls"; then
  ok "送れたら記録し、イベントの名前を渡す (CRLF の出力も読める)"
else
  ng "送れた" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 3. 同じ default.json: 呼ばない
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && seen "${h}" '読み直し済み'; then
  ok "同じ default.json なら呼ばない"
else
  ng "同じ default.json" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 4. --force: 同じでも呼ぶ
run "${h}" 0 --force
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 2 ]]; then
  ok "--force なら同じでも呼ぶ"
else
  ng "--force" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 5. default.json が変わった: 呼んで記録を更新する
printf '{"remapKeys":{"inProcess":[]}}' >"${h}/win/AppData/Local/Microsoft/PowerToys/Keyboard Manager/default.json"
before=$(cat "$(record "${h}")")
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 3 && $(cat "$(record "${h}")") != "${before}" ]]; then
  ok "default.json が変わったら呼んで記録を更新する"
else
  ng "変わった" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 6. PowerToys が動いていない (absent): 記録する
h=$(new_home t6 "${state_on}" 1)
FAKE_PS_OUT=absent run "${h}" 0
if [[ $(rc "${h}") == 0 && -s $(record "${h}") ]] && seen "${h}" '動いていません'; then
  ok "PowerToys が動いていなければ記録する (起動したときに読む)"
else
  ng "absent" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 6b. settings.json が無い (PowerToys の設定画面をまだ開いていない): Keyboard Manager は default.json を読まないので、
#     送らず記録もせず、設定画面を一度開いてから流し直すよう stderr に出す。設定画面が作った後の回では送って記録する
h=$(new_home t6b "${state_on}" 1)
rm "$(km_settings_json "${h}")"
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 0 && ! -e $(record "${h}") ]] \
  && grep -qF 'settings.json' "${h}/err" && grep -q '設定画面を一度開いてから' "${h}/err" \
  && ! grep -q '設定画面を一度開いてから' "${h}/out"; then
  printf '%s' "${km_settings}" >"$(km_settings_json "${h}")"
  run "${h}" 0
  if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 && -s $(record "${h}") ]] && seen "${h}" '読み直させました'; then
    ok "settings.json が無ければ送らず記録もせずに、設定画面を一度開くよう stderr に出す (できた後の回で送る)"
  else
    ng "settings.json ができた後の回" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
  fi
else
  ng "settings.json が無い" "rc=$(rc "${h}") calls=$(ncalls "${h}") record=$([[ -e $(record "${h}") ]] && echo あり) $(outerr "${h}")"
fi

# 6c. 有効なプロファイル (activeConfiguration) が default でない: default.json は読まれないので、
#     送らず記録もせず、そのプロファイルの名前を stderr に出す
h=$(new_home t6c "${state_on}" 1)
printf '%s' '{"properties":{"activeConfiguration":{"value":"work"},"keyboardConfigurations":{"value":["default","work"]}},"name":"Keyboard Manager","version":"1"}' \
  >"$(km_settings_json "${h}")"
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 0 && ! -e $(record "${h}") ]] && grep -qF 'default ではありません (work)' "${h}/err"; then
  ok "有効なプロファイルが default でなければ送らず記録もせずに、その名前を stderr に出す"
else
  ng "有効なプロファイルが default でない" "rc=$(rc "${h}") calls=$(ncalls "${h}") record=$([[ -e $(record "${h}") ]] && echo あり) $(outerr "${h}")"
fi

# 6d. 読み直させて記録した後に settings.json が無くなった: 前の記録で「読み直し済み」と素通りせず (sha を比べる前に確かめる)、
#     送らず記録も変えずに、設定画面を一度開くよう stderr に出す
h=$(new_home t6d "${state_on}" 1)
run "${h}" 0
before=$(cat "$(record "${h}")")
rm "$(km_settings_json "${h}")"
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 && $(cat "$(record "${h}")") == "${before}" ]] \
  && grep -q '設定画面を一度開いてから' "${h}/err" && ! seen "${h}" '読み直し済み'; then
  ok "記録があっても settings.json が無ければ、読み直し済みとは言わずに設定画面を一度開くよう出す (記録は変えない)"
else
  ng "記録があって settings.json が無い" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 7. powershell.exe が無い: 手で読み直す方法を出し、記録しない
h=$(new_home t7 "${state_on}" 1)
run "${h}" 1
if [[ $(rc "${h}") == 0 && ! -e $(record "${h}") ]] && seen "${h}" 'オフにしてオンに戻す'; then
  ok "powershell.exe が無ければ手で読み直す方法を出し、記録しない"
else
  ng "powershell.exe が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 8. powershell.exe が失敗する / 知らない出力: 手で読み直す方法を出し、記録しない
for t in "126:" "0:Exec format error"; do
  h=$(new_home "t8-${t%%:*}" "${state_on}" 1)
  FAKE_PS_RC=${t%%:*} FAKE_PS_OUT=${t#*:} run "${h}" 0
  if [[ $(rc "${h}") == 0 && ! -e $(record "${h}") ]] && seen "${h}" 'オフにしてオンに戻す'; then
    ok "powershell.exe が失敗・知らない出力 (rc=${t%%:*}) なら記録しない"
  else
    ng "失敗 (rc=${t%%:*})" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
done

# 9. 知らない引数: exit 2
h=$(new_home t9 "${state_on}" 1)
run "${h}" 0 --bogus
if [[ $(rc "${h}") == 2 && $(ncalls "${h}") == 0 ]]; then
  ok "知らない引数は exit 2"
else
  ng "知らない引数" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 10. Install-PowerToys.ps1 が配られていない: pwsh.exe は呼ばず、確かめずに読み直しへ進む
h=$(new_home t10 "${state_on}" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 0 && $(ncalls "${h}") == 1 ]] && seen "${h}" 'Install-PowerToys.ps1 がまだ配られていません'; then
  ok "Install-PowerToys.ps1 が配られていなければ pwsh.exe を呼ばずに、読み直しへ進む"
else
  ng "Install-PowerToys.ps1 が無い" "rc=$(rc "${h}") pwsh=$(npwsh "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 11. 入っている (-Check が 0): 入れずに読み直させる。pwsh.exe は -NoProfile -Check で、配った場所を渡す
h=$(new_home t11 "${state_on}" 1 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 1 && $(ncalls "${h}") == 1 ]] && seen "${h}" 'PowerToys は入っています' \
  && seen "${h}" '読み直させました' && pwsh_called_with "${h}" -- '-NoProfile' \
  && pwsh_called_with "${h}" -- '-Check' && ! pwsh_called_with "${h}" -- '-IfMissing' \
  && pwsh_called_with "${h}" -F 'C:\fake\Install-PowerToys.ps1' \
  && [[ $(head -n 1 "${h}/timeout-calls") == "60 pwsh.exe" ]]; then
  ok "入っていれば入れずに読み直させる (pwsh.exe は -NoProfile -Check、配った場所を渡す)"
else
  ng "入っている" "rc=$(rc "${h}") calls=$(pwsh_calls "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 11b. スクリプトが exit まで届かずに終わっても成功扱いにしない: 呼ぶ前に $LASTEXITCODE を 2 にしておく
# shellcheck disable=SC2016 # PowerShell の $global:… を文字のまま探す
if pwsh_called_with "${h}" -F '$global:LASTEXITCODE = 2; &'; then
  ok "pwsh.exe には、スクリプトを呼ぶ前に \$LASTEXITCODE を 2 にするコマンドを渡す"
else
  ng "\$LASTEXITCODE を先に 2 にしていない" "calls=$(pwsh_calls "${h}")"
fi

# 12. 読み直し済みでも、入っているかは毎回確かめる (確かめてから「読み直し済み」で終わる)
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 2 && $(ncalls "${h}") == 1 ]] && seen "${h}" '読み直し済み'; then
  ok "読み直し済みでも、入っているかは毎回確かめる"
else
  ng "読み直し済み" "rc=$(rc "${h}") pwsh=$(npwsh "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 13. 入っていない (-Check が 3): -IfMissing で入れてから読み直させる
h=$(new_home t13 "${state_on}" 1 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=0 FAKE_PWSH_OUT2="${added_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 2 && $(ncalls "${h}") == 1 && -s $(record "${h}") ]] \
  && pwsh_last_called_with "${h}" -- '-IfMissing' && seen "${h}" 'PowerToys を入れました' \
  && seen "${h}" '読み直させました' && ! seen "${h}" '⚠️' \
  && [[ $(tr '\n' ',' <"${h}/timeout-calls") == "60 pwsh.exe,600 pwsh.exe,60 powershell.exe," ]] \
  && grep -q 'winget で入れます' "${h}/out-at-ifmissing" && grep -q '600 秒まで待ちます' "${h}/out-at-ifmissing"; then
  ok "入っていなければ -IfMissing で入れてから読み直させる"
else
  ng "入っていない → 入れる" "rc=$(rc "${h}") calls=$(pwsh_calls "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 14. 入れられない (-IfMissing が 1): ⚠ で囲んで知らせ、それでも読み直しへ進む
h=$(new_home t14 "${state_on}" 1 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=1 FAKE_PWSH_OUT2=$'winget が失敗した (終了コード 0x8A150011)\e[0m' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && seen "${h}" 'PowerToys を入れられませんでした (終了コード 1)' \
  && seen "${h}" -F '0x8A150011' && seen "${h}" -F 'PowerShell: Install-PowerToys' \
  && [[ $(outerr "${h}" | grep -c '⚠️') -ge 2 ]] && ! seen "${h}" $'\e\[' \
  && ! seen "${h}" $'\r'; then
  ok "入れられなければ ⚠ で囲んで知らせ、読み直しへ進んで exit 0 (端末でなければ色を付けない)"
else
  ng "入れられない" "rc=$(rc "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 15. -Check が 3 でもこちらの出力が無い・pwsh.exe が失敗する: 入れには行かず、手で打つコマンドを出して読み直しへ進む
for t in "3:Exec format error" "126:" "2:PowerToys (winget の Microsoft.PowerToys。版は固定しない)"; do
  h=$(new_home "t15-${t%%:*}" "${state_on}" 1 1)
  FAKE_PWSH_RC=${t%%:*} FAKE_PWSH_OUT=${t#*:} run "${h}" 0
  if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 1 && $(ncalls "${h}") == 1 ]] && seen "${h}" '確かめられませんでした' \
    && seen "${h}" -F 'Install-PowerToys'; then
    ok "pwsh.exe の出力が来ない・失敗する (rc=${t%%:*}) なら、入れずに手で打つコマンドを出して読み直しへ進む"
  else
    ng "pwsh.exe の失敗 (rc=${t%%:*})" "rc=$(rc "${h}") pwsh=$(npwsh "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
  fi
done

# 15b. -Check が 60 秒で時間切れ (124): 時間切れと出し、入れには行かず、手で打つコマンドを出して読み直しへ進む
h=$(new_home t15b "${state_on}" 1 1)
FAKE_PWSH_RC=124 FAKE_PWSH_OUT='' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 1 && $(ncalls "${h}") == 1 ]] && seen "${h}" '60 秒たっても終わりませんでした' \
  && seen "${h}" -F 'Install-PowerToys'; then
  ok "-Check が時間切れなら、時間切れと出して手で打つコマンドを出し、読み直しへ進む"
else
  ng "-Check の時間切れ" "rc=$(rc "${h}") pwsh=$(npwsh "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 15c. -IfMissing が 600 秒で時間切れ (124): ⚠ で囲んで 600 秒待ったと出し、読み直しへ進む
h=$(new_home t15c "${state_on}" 1 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=124 FAKE_PWSH_OUT2='' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && seen "${h}" '600 秒待っても終わらない' \
  && [[ $(outerr "${h}" | grep -c '⚠️') -ge 2 ]]; then
  ok "-IfMissing が時間切れなら、⚠ で囲んで 600 秒待ったと出し、読み直しへ進む"
else
  ng "-IfMissing の時間切れ" "rc=$(rc "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 16. pwsh.exe が無い (powershell.exe はある): 手で打つコマンドを出して、読み直しへ進む
h=$(new_home t16 "${state_on}" 1 1)
run "${h}" 2
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 && -s $(record "${h}") ]] && seen "${h}" 'pwsh.exe が見つかりません' \
  && seen "${h}" -F 'Install-PowerToys'; then
  ok "pwsh.exe が無ければ手で打つコマンドを出して、読み直しへ進む"
else
  ng "pwsh.exe が無い" "rc=$(rc "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 17. default.json がまだ無くても、PowerToys が入っているかは確かめる (入れるのは default.json に依らない)
h=$(new_home t17 "${state_on}" 0 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=0 FAKE_PWSH_OUT2="${added_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 2 && $(ncalls "${h}") == 0 ]] && seen "${h}" 'PowerToys を入れました' \
  && seen "${h}" 'default.json がまだありません'; then
  ok "default.json が無くても、入っていなければ入れてから飛ばす"
else
  ng "default.json が無い" "rc=$(rc "${h}") pwsh=$(npwsh "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 19. setup から走るとき (DOTFILES_SETUP_WARNINGS がある): 入れられなければ、⚠ の見出しと入れるコマンドを
#     まとめ用に残す (winget の出力は残さない。その場の ⚠ の枠には出ている)
h=$(new_home t19 "${state_on}" 1 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=1 \
  FAKE_PWSH_OUT2='winget が失敗した (終了コード 0x8A150011)' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(head -n 1 "${h}/warnings" 2>/dev/null) == 'Windows に PowerToys を入れられませんでした (終了コード 1)' ]] \
  && grep -qE '^[[:space:]]+WSL: .*/bootstrap-windows-powertoys\.sh ' "${h}/warnings" \
  && grep -qE '^[[:space:]]+PowerShell: Install-PowerToys$' "${h}/warnings" \
  && ! grep -q '0x8A150011' "${h}/warnings"; then
  ok "setup から走るとき、入れられなければ ⚠ の見出しと入れるコマンドをまとめ用に残す"
else
  ng "入れられないときのまとめ" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null)"
fi

# 20. 有効なプロファイルが default でない・settings.json が無いときの案内も、まとめ用に残す
h=$(new_home t20 "${state_on}" 1)
printf '%s' '{"properties":{"activeConfiguration":{"value":"work"}},"name":"Keyboard Manager","version":"1"}' \
  >"$(km_settings_json "${h}")"
DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}" 0
h2=$(new_home t20b "${state_on}" 1)
rm "$(km_settings_json "${h2}")"
DOTFILES_SETUP_WARNINGS="${h2}/warnings" run "${h2}" 0
if [[ $(rc "${h}") == 0 && $(head -n 1 "${h}/warnings" 2>/dev/null) == *'default ではありません (work)'* ]] \
  && [[ $(rc "${h2}") == 0 && $(head -n 1 "${h2}/warnings" 2>/dev/null) == *'settings.json'*'がまだ無い'* ]] \
  && grep -qE '^[[:space:]]+PowerToys の設定画面を一度開いてから' "${h2}/warnings"; then
  ok "プロファイルが default でない・settings.json が無いときの案内も、まとめ用に残す"
else
  ng "Keyboard Manager の案内のまとめ" "$(cat "${h}/warnings" "${h2}/warnings" 2>/dev/null)"
fi

# 21. 読み直させられない (powershell.exe が失敗する) ときは、見出し・出力・手で読み直す方法を 1 件として残す
h=$(new_home t21 "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PS_RC=126 FAKE_PS_OUT='Exec format error' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(head -n 1 "${h}/warnings" 2>/dev/null) == 'powershell.exe で Keyboard Manager に読み直させられませんでした'* ]] \
  && grep -qE '^[[:space:]]+Exec format error$' "${h}/warnings" && grep -qE '^[[:space:]]+.*オフにしてオンに戻す' "${h}/warnings" \
  && [[ $(grep -c '^[^[:space:]]' "${h}/warnings") == 1 ]]; then
  ok "読み直させられなければ、見出し・出力・手で読み直す方法を 1 件としてまとめ用に残す"
else
  ng "読み直させられないときのまとめ" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null)"
fi

# 22. 入っていて読み直させられたときは、まとめ用には何も残さない
h=$(new_home t22 "${state_on}" 1 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}" 0
if [[ $(rc "${h}") == 0 && ! -s ${h}/warnings ]] && seen "${h}" '読み直させました'; then
  ok "入っていて読み直させられたときは、まとめ用には何も残さない"
else
  ng "警告が無いのにまとめ用に残した" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null) $(outerr "${h}")"
fi

# 30. 両方オフ: 止める → 書く → 起動する → 確かめる → 読み直させる、の順に進む。ほかの項目は変えない
#     (runner が書いた形のまま。キーの順も、1 行で末尾に改行が無いことも)
h=$(new_home t30 "${state_on}" 1)
global_settings false false >"$(global_json "${h}")"
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'stop,start,wait,event,' ]] \
  && [[ $(cat "${h}/global-at-stop") == "$(global_settings false false)" ]] \
  && [[ $(cat "${h}/global-at-start") == "$(global_settings true true)" ]] \
  && [[ $(cat "$(global_json "${h}")") == "$(global_settings true true)" ]] \
  && [[ $(tail -c 1 "$(global_json "${h}")") == '}' ]] \
  && [[ $(tr '\n' ',' <"${h}/timeout-calls") == '60 powershell.exe,60 powershell.exe,60 powershell.exe,60 powershell.exe,' ]] \
  && [[ -s $(record "${h}") && ! -e $(pending "${h}") ]] && seen "${h}" 'Keyboard Manager と自動起動がオフです' \
  && seen "${h}" 'Keyboard Manager と自動起動をオンにして、PowerToys を起動しました' && seen "${h}" '読み直させました'; then
  ok "両方オフなら、止める → 両方を true に書く → 起動する → 読み直させる (ほかの項目と形は変えない)"
else
  ng "両方オフ" "rc=$(rc "${h}") steps=$(steps "${h}") global=$(cat "$(global_json "${h}")") $(outerr "${h}")"
fi

# 31. 次の回: 両方オンなので、止めない・書かない・起動しない (読み直し済みと出るのは、オンの今は正しい)
before=$(sha256sum <"$(global_json "${h}")")
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'stop,start,wait,event,' && $(sha256sum <"$(global_json "${h}")") == "${before}" ]] \
  && seen "${h}" '読み直し済み' && ! seen "${h}" 'オフです'; then
  ok "オンにした次の回は起動し直さず、読み直し済みと出す"
else
  ng "次の回" "rc=$(rc "${h}") steps=$(steps "${h}") $(outerr "${h}")"
fi

# 32. どちらか一方だけオフ: オフの方を名指しして、同じ順で両方をオンにする
for t in "false:true:Keyboard Manager " "true:false:自動起動"; do
  IFS=: read -r km startup label <<<"${t}"
  h=$(new_home "t32-${km}" "${state_on}" 1)
  global_settings "${km}" "${startup}" >"$(global_json "${h}")"
  run "${h}" 0
  if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'stop,start,wait,event,' && $(cat "$(global_json "${h}")") == "$(global_settings true true)" ]] \
    && seen "${h}" "${label}がオフです" && seen "${h}" "${label}をオンにして" && ! seen "${h}" ' と自動起動'; then
    ok "一方だけオフ (${label}) でも、止める → 書く → 起動する"
  else
    ng "一方だけオフ (${label})" "rc=$(rc "${h}") steps=$(steps "${h}") $(outerr "${h}")"
  fi
done

# 33. 両方オン: 止めない・書かない。待ちもしない
h=$(new_home t33 "${state_on}" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'event,' && $(cat "$(global_json "${h}")") == "$(global_settings true true)" && $(nsleep "${h}") == 0 ]]; then
  ok "両方オンなら止めない・書かない・待たない"
else
  ng "両方オン" "rc=$(rc "${h}") steps=$(steps "${h}") sleep=$(nsleep "${h}") $(outerr "${h}")"
fi

# 34. 全体の settings.json が無い (入れたばかり) で PowerToys も動いていない: 2 つだけのファイルを作って起動する
h=$(new_home t34 "${state_on}" 1)
rm "$(global_json "${h}")"
FAKE_PS_STOP=not-running run "${h}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'stop,start,wait,event,' && -s $(record "${h}") ]] \
  && [[ $(cat "$(global_json "${h}")") == '{"startup":true,"enabled":{"Keyboard Manager":true}}' ]] \
  && [[ ! -e ${h}/global-at-stop || ! -s ${h}/global-at-stop ]] \
  && seen "${h}" 'をオンにして、PowerToys を起動しました'; then
  ok "全体の settings.json が無ければ、2 つだけで作って起動する (動いていなくても起動する)"
else
  ng "全体の settings.json が無い" "rc=$(rc "${h}") steps=$(steps "${h}") global=$(cat "$(global_json "${h}")" 2>/dev/null) $(outerr "${h}")"
fi

# 35. 止められない (管理者で動いている): 書かず、手順を出す。起動のコマンドは打つ (遅れて終わったときのため。動いていれば何もしない)。
#     前の記録が同じ sha でも「読み直し済み」と言わず、記録も変えない。印も残さない
h=$(new_home t35 "${state_on}" 1)
run "${h}" 0
before=$(cat "$(record "${h}")")
: >"${h}/ps-steps"
global_settings false false >"$(global_json "${h}")"
FAKE_PS_STOP=still-running run "${h}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'stop,start,' && $(cat "$(global_json "${h}")") == "$(global_settings false false)" ]] \
  && [[ $(cat "$(record "${h}")") == "${before}" && ! -e $(pending "${h}") ]] && grep -q 'PowerToys を止められないので' "${h}/err" \
  && manual_seen "${h}" && no_false_claim "${h}"; then
  ok "止められなければ書かずに手順を出す (前の記録があっても読み直し済みと言わない)"
else
  ng "止められない" "rc=$(rc "${h}") steps=$(steps "${h}") $(outerr "${h}")"
fi

# 36. powershell.exe が失敗する・知らない出力: 書かない。止める途中で切れたかもしれないので起動しておく。記録しない
for t in "126:Exec format error" "124:" "0:unexpected"; do
  h=$(new_home "t36-${t%%:*}" "${state_on}" 1)
  global_settings false false >"$(global_json "${h}")"
  FAKE_PS_STOP_RC=${t%%:*} FAKE_PS_STOP=${t#*:} run "${h}" 0
  if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'stop,start,' && $(cat "$(global_json "${h}")") == "$(global_settings false false)" && ! -e $(record "${h}") ]] \
    && seen "${h}" "終了コード ${t%%:*}" && manual_seen "${h}" && no_false_claim "${h}"; then
    ok "止めるときに powershell.exe が失敗 (rc=${t%%:*}) したら、書かずに起動だけして手順を出す"
  else
    ng "止めるときの失敗 (rc=${t%%:*})" "rc=$(rc "${h}") steps=$(steps "${h}") $(outerr "${h}")"
  fi
done

# 36b. powershell.exe が無い: 書かない・記録しない
h=$(new_home t36b "${state_on}" 1)
global_settings false false >"$(global_json "${h}")"
run "${h}" 1
if [[ $(rc "${h}") == 0 && $(cat "$(global_json "${h}")") == "$(global_settings false false)" && ! -e $(record "${h}") ]] \
  && manual_seen "${h}" && no_false_claim "${h}"; then
  ok "powershell.exe が無ければ、書かずに手順を出す"
else
  ng "powershell.exe が無い (オフ)" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 37. run_elevated: 起動すると UAC の確認が出るので、止めない・書かない
h=$(new_home t37 "${state_on}" 1)
global_settings false false true >"$(global_json "${h}")"
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == '' && $(cat "$(global_json "${h}")") == "$(global_settings false false true)" && ! -e $(record "${h}") ]] \
  && seen "${h}" 'run_elevated' && manual_seen "${h}" && no_false_claim "${h}"; then
  ok "run_elevated が true なら止めず書かず、手順を出す"
else
  ng "run_elevated" "rc=$(rc "${h}") steps=$(steps "${h}") $(outerr "${h}")"
fi

# 38. PowerToys が入っていない: 書かない (ファイルを作らない)。入れ方を出す
h=$(new_home t38 "${state_on}" 1)
rm "$(global_json "${h}")"
FAKE_PS_STOP=no-exe run "${h}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'stop,' && ! -e $(global_json "${h}") && ! -e $(record "${h}") ]] \
  && seen "${h}" 'PowerToys が見つからない' && seen "${h}" -F 'Install-PowerToys' && no_false_claim "${h}"; then
  ok "PowerToys が見つからなければ、ファイルを作らずに入れ方を出す"
else
  ng "PowerToys が無い" "rc=$(rc "${h}") steps=$(steps "${h}") $(outerr "${h}")"
fi

# 39. 書けない: 止めたので起動し直し、元の設定のまま。記録しない (root でも落ちるよう、隣の一時ファイルの場所をディレクトリにする)
h=$(new_home t39 "${state_on}" 1)
global_settings false false >"$(global_json "${h}")"
mkdir "$(global_json "${h}").dotfiles-tmp"
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'stop,start,' && $(cat "$(global_json "${h}")") == "$(global_settings false false)" && ! -e $(record "${h}") && ! -e $(pending "${h}") ]] \
  && seen "${h}" '全体の設定に書けない' && manual_seen "${h}" && no_false_claim "${h}"; then
  ok "書けなければ起動し直して手順を出す (記録しない)"
else
  ng "書けない" "rc=$(rc "${h}") steps=$(steps "${h}") $(outerr "${h}")"
fi

# 40. 起動できない: 設定には書いてあるので、スタートメニューから起動するよう出す。記録しない
for t in "1:boom" "0:no-exe"; do
  h=$(new_home "t40-${t%%:*}" "${state_on}" 1)
  global_settings false false >"$(global_json "${h}")"
  FAKE_PS_START_RC=${t%%:*} FAKE_PS_START=${t#*:} run "${h}" 0
  if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'stop,start,' && $(cat "$(global_json "${h}")") == "$(global_settings true true)" && ! -e $(record "${h}") ]] \
    && seen "${h}" 'スタートメニューから起動' && no_false_claim "${h}"; then
    ok "起動できなければ (${t#*:}) スタートメニューからの起動を案内し、記録しない"
  else
    ng "起動できない (${t#*:})" "rc=$(rc "${h}") steps=$(steps "${h}") $(outerr "${h}")"
  fi
done

# 41. 起動してもエンジンが動かない・確かめられない: 手順を出し、記録しない
for t in "0:absent task:30 秒たっても" "1:oops:確かめられませんでした"; do
  IFS=: read -r wrc wout wmsg <<<"${t}"
  h=$(new_home "t41-${wrc}" "${state_on}" 1)
  global_settings false false >"$(global_json "${h}")"
  FAKE_PS_WAIT_RC=${wrc} FAKE_PS_WAIT=${wout} run "${h}" 0
  if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'stop,start,wait,' && ! -e $(record "${h}") ]] \
    && seen "${h}" "${wmsg}" && manual_seen "${h}" && no_false_claim "${h}"; then
    ok "起動の後にエンジンを確かめられなければ (${wout}) 手順を出し、記録しない"
  else
    ng "エンジンを確かめられない (${wout})" "rc=$(rc "${h}") steps=$(steps "${h}") $(outerr "${h}")"
  fi
done

# 42. 起動の後に、設定でオフに戻っている (runner がタスクを作れず書き戻した、など): 読み直して確かめ、手順を出す。
#     Keyboard Manager がオンなら読み直しへ進み、オフなら記録しない
h=$(new_home t42a "${state_on}" 1)
global_settings false false >"$(global_json "${h}")"
FAKE_START_WRITES=$(global_settings true false) run "${h}" 0
h2=$(new_home t42b "${state_on}" 1)
global_settings false false >"$(global_json "${h2}")"
FAKE_START_WRITES=$(global_settings false true) run "${h2}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'stop,start,wait,event,' && -s $(record "${h}") && $(nsleep "${h}") == 0 ]] \
  && seen "${h}" '、自動起動が全体の設定でオンになっていません' && manual_seen "${h}" && seen "${h}" '読み直させました' \
  && [[ $(rc "${h2}") == 0 && $(steps "${h2}") == 'stop,start,wait,' && ! -e $(record "${h2}") ]] \
  && seen "${h2}" '、Keyboard Manager が全体の設定でオンになっていません' && no_false_claim "${h2}"; then
  ok "起動の後にオフへ戻っていたら手順を出す (Keyboard Manager がオンのときだけ読み直しへ進む)"
else
  ng "起動の後にオフ" "rc=$(rc "${h}")/$(rc "${h2}") steps=$(steps "${h}")/$(steps "${h2}") sleep=$(nsleep "${h}") $(outerr "${h}") $(outerr "${h2}")"
fi

# 43. 起動の直後は設定画面が同じファイルを書く: 読みかけ (JSON でない) に当たっても、読み直して確かめる
h=$(new_home t43 "${state_on}" 1)
global_settings false false >"$(global_json "${h}")"
FAKE_START_WRITES='{"startup":tr' FAKE_SLEEP_PATH=$(global_json "${h}") FAKE_SLEEP_AT=2 FAKE_SLEEP_WRITE=$(global_settings true true) run "${h}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'stop,start,wait,event,' && -s $(record "${h}") && $(nsleep "${h}") == 2 ]] \
  && ! seen "${h}" 'オンになっていません' && seen "${h}" 'をオンにして、PowerToys を起動しました'; then
  ok "起動の直後に設定を読みかけても、読み直して確かめる"
else
  ng "読みかけ" "rc=$(rc "${h}") steps=$(steps "${h}") sleep=$(nsleep "${h}") $(outerr "${h}")"
fi

# 44. 自動起動のタスクが無い: 知らせる。Keyboard Manager はオンなので読み直しへ進む
h=$(new_home t44 "${state_on}" 1)
global_settings false false >"$(global_json "${h}")"
FAKE_PS_WAIT='ready no-task' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'stop,start,wait,event,' && -s $(record "${h}") ]] \
  && grep -q '自動起動のタスクがありません' "${h}/err" && manual_seen "${h}" && seen "${h}" '読み直させました'; then
  ok "自動起動のタスクが無ければ知らせて、読み直しへ進む"
else
  ng "タスクが無い" "rc=$(rc "${h}") steps=$(steps "${h}") $(outerr "${h}")"
fi

# 45. Keyboard Manager はオンで自動起動だけオフ・止められない: 手順を出すが、読み直しへは進む (割り当ては効く)
h=$(new_home t45 "${state_on}" 1)
global_settings true false >"$(global_json "${h}")"
FAKE_PS_STOP=still-running run "${h}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'stop,start,event,' && $(cat "$(global_json "${h}")") == "$(global_settings true false)" && -s $(record "${h}") ]] \
  && seen "${h}" '自動起動をオンにできませんでした' && manual_seen "${h}" && seen "${h}" '読み直させました'; then
  ok "Keyboard Manager がオンなら、自動起動をオンにできなくても読み直しへ進む"
else
  ng "自動起動だけオフで止められない" "rc=$(rc "${h}") steps=$(steps "${h}") $(outerr "${h}")"
fi

# 46. 全体の settings.json が読めない (JSON でない・空): 触らずに手順を出す
for t in "broken:not json" "empty:"; do
  h=$(new_home "t46-${t%%:*}" "${state_on}" 1)
  printf '%s' "${t#*:}" >"$(global_json "${h}")"
  run "${h}" 0
  if [[ $(rc "${h}") == 0 && $(steps "${h}") == '' && $(cat "$(global_json "${h}")") == "${t#*:}" && ! -e $(record "${h}") ]] \
    && seen "${h}" '全体の設定を読めない' && manual_seen "${h}" && no_false_claim "${h}"; then
    ok "全体の settings.json が読めなければ (${t%%:*}) 触らずに手順を出す"
  else
    ng "読めない (${t%%:*})" "rc=$(rc "${h}") steps=$(steps "${h}") $(outerr "${h}")"
  fi
done

# 47. setup から走るとき: オンにできなければ、見出しと手順を 1 件としてまとめ用に残す
h=$(new_home t47 "${state_on}" 1)
global_settings false false >"$(global_json "${h}")"
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PS_STOP=still-running run "${h}" 0
if [[ $(rc "${h}") == 0 && $(head -n 1 "${h}/warnings" 2>/dev/null) == 'PowerToys を止められないので'* ]] \
  && grep -qE '^[[:space:]]+PowerToys の設定画面で 2 つをオンにしてください' "${h}/warnings" \
  && [[ $(grep -c '^[^[:space:]]' "${h}/warnings") == 1 ]]; then
  ok "オンにできなければ、見出しと手順を 1 件としてまとめ用に残す"
else
  ng "オンにできないときのまとめ" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null)"
fi

# 48. オンにできたときは、まとめ用には何も残さない
h=$(new_home t48 "${state_on}" 1)
global_settings false false >"$(global_json "${h}")"
DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}" 0
if [[ $(rc "${h}") == 0 && ! -s ${h}/warnings ]] && seen "${h}" 'をオンにして、PowerToys を起動しました'; then
  ok "オンにできたときは、まとめ用には何も残さない"
else
  ng "オンにできたのにまとめ用に残した" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null)"
fi

# 49. 起動した直後は、Keyboard Manager の settings.json ができるのを待ってから読み直させる。30 秒待っても無ければ今までどおり案内する
h=$(new_home t49a "${state_on}" 1)
global_settings false false >"$(global_json "${h}")"
rm "$(km_settings_json "${h}")"
FAKE_SLEEP_PATH=$(km_settings_json "${h}") FAKE_SLEEP_AT=3 FAKE_SLEEP_WRITE=${km_settings} run "${h}" 0
h2=$(new_home t49b "${state_on}" 1)
global_settings false false >"$(global_json "${h2}")"
rm "$(km_settings_json "${h2}")"
run "${h2}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'stop,start,wait,event,' && -s $(record "${h}") && $(nsleep "${h}") == 3 ]] && seen "${h}" '読み直させました' \
  && [[ $(rc "${h2}") == 0 && $(steps "${h2}") == 'stop,start,wait,' && ! -e $(record "${h2}") && $(nsleep "${h2}") == 30 ]] \
  && grep -q '設定画面を一度開いてから' "${h2}/err"; then
  ok "起動した直後は settings.json を 30 秒まで待ち、できれば読み直させ、できなければ案内する"
else
  ng "起動した直後に待つ" "rc=$(rc "${h}")/$(rc "${h2}") steps=$(steps "${h}")/$(steps "${h2}") sleep=$(nsleep "${h}")/$(nsleep "${h2}") $(outerr "${h}") $(outerr "${h2}")"
fi

# 50. 入れた直後は、止める前にも待つ (止めると開きかけの設定画面も閉じる)。入れていなければ止める前には待たない
h=$(new_home t50 "${state_on}" 1 1)
global_settings false false >"$(global_json "${h}")"
rm "$(km_settings_json "${h}")"
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=0 FAKE_PWSH_OUT2="${added_out}" \
  FAKE_SLEEP_PATH=$(km_settings_json "${h}") FAKE_SLEEP_AT=2 FAKE_SLEEP_WRITE=${km_settings} run "${h}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'stop,start,wait,event,' && -s $(record "${h}") ]] \
  && [[ $(cat "${h}/km-settings-at-stop" 2>/dev/null) == yes && $(nsleep "${h}") == 2 ]] && seen "${h}" '読み直させました'; then
  ok "入れた直後は、Keyboard Manager の settings.json ができるのを止める前に待つ"
else
  ng "入れた直後に待つ" "rc=$(rc "${h}") steps=$(steps "${h}") sleep=$(nsleep "${h}") $(outerr "${h}")"
fi

# 51. 止めるのは runner のトレイのウィンドウへの WM_CLOSE が先で、だめなら強制で止める (taskkill は /F なしだと先頭のウィンドウにしか
#     送らず、Mouse Highlighter のウィンドウだけ閉じて runner が残る)。起動は Start-Process で、explorer.exe を通さない (ドキュメントが開く)
h=$(new_home t51 "${state_on}" 1)
global_settings false false >"$(global_json "${h}")"
run "${h}" 0
# shellcheck disable=SC2016 # PowerShell の $exe を文字のまま探す
if grep -qF "FindWindow('PToyTrayIconWindow'" "${h}/ps-calls" && grep -qF 'PostMessage($w, 0x0010' "${h}/ps-calls" \
  && ! grep -qF 'taskkill' "${h}/ps-calls" \
  && grep -qF "Get-Mine 'PowerToys' | Stop-Process -Force" "${h}/ps-calls" && grep -qF 'Start-Process -FilePath $exe' "${h}/ps-calls" \
  && grep -qF '$_.SessionId -eq $session' "${h}/ps-calls" \
  && ! grep -qF 'explorer' "${h}/ps-calls" && grep -qF 'PowerToys_KeyboardManager_Event_Settings' "${h}/ps-calls"; then
  ok "止めるのはトレイのウィンドウへの WM_CLOSE が先で、起動は Start-Process"
else
  ng "止め方・起動の仕方" "$(cat "${h}/ps-calls")"
fi

# 52. 書いた後に起動や確認でつまずく: 印を残し、次の回は両方オンでも (止めず書かず) 起動と確認をやり直す。確かめられたら印を消して
#     読み直しへ進む。つまずいた回は記録しない。$1: ケースのディレクトリ、$2: 名前、$3: つまずいた回に出る文
check_retry() {
  local d=$1 first_ok=0
  if [[ $(rc "${d}") == 0 && -e $(pending "${d}") && ! -e $(record "${d}") && $(cat "$(global_json "${d}")") == "$(global_settings true true)" ]] \
    && seen "${d}" "$3" && no_false_claim "${d}"; then
    first_ok=1
  fi
  : >"${d}/ps-steps"
  run "${d}" 0
  if [[ ${first_ok} == 1 && $(rc "${d}") == 0 && $(steps "${d}") == 'start,wait,event,' && ! -e $(pending "${d}") && -s $(record "${d}") ]] \
    && seen "${d}" '確かめ直します' && seen "${d}" '動いていることを確かめました' && seen "${d}" '読み直させました'; then
    ok "書いた後につまずいたら ($2) 印を残し、次の回が起動と確認をやり直して読み直しへ進む"
  else
    ng "つまずいた次の回 ($2)" "first=${first_ok} rc=$(rc "${d}") steps=$(steps "${d}") $(outerr "${d}")"
  fi
}
h=$(new_home t52-start "${state_on}" 1)
global_settings false false >"$(global_json "${h}")"
FAKE_PS_START_RC=1 run "${h}" 0
check_retry "${h}" 起動 'スタートメニューから起動'
h=$(new_home t52-wait "${state_on}" 1)
global_settings false false >"$(global_json "${h}")"
FAKE_PS_WAIT='absent task' run "${h}" 0
check_retry "${h}" エンジン '30 秒たっても'

# 53. 次の回も起動できない: 警告を出し直し、印を残し、記録しない
h=$(new_home t53 "${state_on}" 1)
global_settings true true >"$(global_json "${h}")"
touch "$(pending "${h}")"
FAKE_PS_START_RC=1 run "${h}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'start,' && -e $(pending "${h}") && ! -e $(record "${h}") ]] \
  && seen "${h}" 'スタートメニューから起動' && no_false_claim "${h}"; then
  ok "印があって次の回も起動できなければ、印を残して記録しない"
else
  ng "次の回も起動できない" "rc=$(rc "${h}") steps=$(steps "${h}") $(outerr "${h}")"
fi

# 54. 自動起動のタスクが無かった回も印を残し、次の回でタスクがあれば消す (Keyboard Manager はオンなので読み直しへは進む)
h=$(new_home t54 "${state_on}" 1)
global_settings false false >"$(global_json "${h}")"
FAKE_PS_WAIT='ready no-task' run "${h}" 0
first_pending=$([[ -e $(pending "${h}") ]] && echo yes)
run "${h}" 0
if [[ ${first_pending} == yes && $(rc "${h}") == 0 && ! -e $(pending "${h}") ]] && seen "${h}" '確かめ直します' && ! grep -q 'タスクがありません' "${h}/err"; then
  ok "自動起動のタスクが無かった回は印を残し、次の回で確かめて消す"
else
  ng "タスクが無かった次の回" "first=${first_pending} rc=$(rc "${h}") steps=$(steps "${h}") $(outerr "${h}")"
fi

# 55. 印があっても run_elevated なら起動しない (UAC の確認が出る)
h=$(new_home t55 "${state_on}" 1)
global_settings true true true >"$(global_json "${h}")"
touch "$(pending "${h}")"
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'event,' ]] && ! seen "${h}" '確かめ直します'; then
  ok "印があっても run_elevated なら起動しない"
else
  ng "印と run_elevated" "rc=$(rc "${h}") steps=$(steps "${h}") $(outerr "${h}")"
fi

# 56. 起動した後に Keyboard Manager の settings.json ができたら、前の記録が同じ sha でもイベントを送る
#     (エンジンは無い間に起動すると何も読まず、できても読み直さない)。30 秒待っても無ければ記録を消し、できた後の回で送る
h=$(new_home t56a "${state_on}" 1)
run "${h}" 0
: >"${h}/ps-steps"
global_settings false false >"$(global_json "${h}")"
rm "$(km_settings_json "${h}")"
FAKE_SLEEP_PATH=$(km_settings_json "${h}") FAKE_SLEEP_AT=2 FAKE_SLEEP_WRITE=${km_settings} run "${h}" 0
h2=$(new_home t56b "${state_on}" 1)
run "${h2}" 0
: >"${h2}/ps-steps"
global_settings false false >"$(global_json "${h2}")"
rm "$(km_settings_json "${h2}")"
run "${h2}" 0
gone=$([[ ! -e $(record "${h2}") ]] && echo yes)
printf '%s' "${km_settings}" >"$(km_settings_json "${h2}")"
: >"${h2}/ps-steps"
run "${h2}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'stop,start,wait,event,' && -s $(record "${h}") ]] && seen "${h}" '読み直させました' \
  && [[ ${gone} == yes && $(rc "${h2}") == 0 && $(steps "${h2}") == 'event,' && -s $(record "${h2}") ]] && seen "${h2}" '読み直させました'; then
  ok "起動した後に settings.json ができたら、前の記録が同じ sha でも送る (間に合わなければ記録を消し、次の回で送る)"
else
  ng "待った後の読み直し" "rc=$(rc "${h}")/$(rc "${h2}") steps=$(steps "${h}")/$(steps "${h2}") gone=${gone} $(outerr "${h}") $(outerr "${h2}")"
fi

# 57. Keyboard Manager の settings.json が空や書きかけのうちは待ち続ける (できただけで抜けて、誤った案内を出さない)
h=$(new_home t57 "${state_on}" 1)
global_settings false false >"$(global_json "${h}")"
printf '{"properties":{"activeConf' >"$(km_settings_json "${h}")"
FAKE_SLEEP_PATH=$(km_settings_json "${h}") FAKE_SLEEP_AT=3 FAKE_SLEEP_WRITE=${km_settings} run "${h}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'stop,start,wait,event,' && -s $(record "${h}") && $(nsleep "${h}") == 3 ]] \
  && seen "${h}" '読み直させました' && ! grep -q '設定画面を一度開いてから' "${h}/err"; then
  ok "Keyboard Manager の settings.json が書きかけのうちは待ち続ける"
else
  ng "書きかけの settings.json" "rc=$(rc "${h}") steps=$(steps "${h}") sleep=$(nsleep "${h}") $(outerr "${h}")"
fi

# 58. 入口で全体の設定を読みかけても、読み直して確かめる (両方オンなら止めない)
h=$(new_home t58 "${state_on}" 1)
printf '{"startup":tr' >"$(global_json "${h}")"
FAKE_SLEEP_PATH=$(global_json "${h}") FAKE_SLEEP_AT=2 FAKE_SLEEP_WRITE=$(global_settings true true) run "${h}" 0
if [[ $(rc "${h}") == 0 && $(steps "${h}") == 'event,' && -s $(record "${h}") && $(nsleep "${h}") == 2 ]] && ! seen "${h}" '全体の設定を読めない'; then
  ok "入口で全体の設定を読みかけても、読み直して確かめる"
else
  ng "入口の読みかけ" "rc=$(rc "${h}") steps=$(steps "${h}") sleep=$(nsleep "${h}") $(outerr "${h}")"
fi

# 18. script に実行ビットがある (setup.sh は実行ビットの無い bootstrap を「実行できません」で止める)
if [[ -x ${script} ]]; then
  ok "script に実行ビットがある (setup.sh は実行できない bootstrap で止まる)"
else
  ng "script に実行ビットが無い" "$(ls -l "${script}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
