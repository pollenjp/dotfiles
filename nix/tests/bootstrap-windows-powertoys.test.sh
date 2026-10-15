#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-powertoys.sh の振る舞いを、使い捨ての HOME と
# 偽の powershell.exe / pwsh.exe / wslpath で確かめる。
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
# Install-PowerToys.ps1 -IfMissing が入れ終えたときの出力
added_out="winget install --id Microsoft.PowerToys --exact --source winget --scope user --silent --accept-source-agreements --disable-interactivity --accept-package-agreements
  Successfully installed

${installed_out%入っている}入った"

sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env jq grep sed tr cat head tail cut mkdir dirname sha256sum timeout od; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# $1: 名前、$2: windows-files.json の中身 (空なら作らない)、$3: 1 なら default.json と settings.json を置く、
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
  fi
  if [[ ${4:-0} == 1 ]]; then
    mkdir -p "${h}/win/.config/powershell"
    printf '# Install-PowerToys.ps1\n' >"${h}/win/.config/powershell/Install-PowerToys.ps1"
  fi
  # 偽の powershell.exe。引数を記録し、FAKE_PS_OUT (既定 set) を CRLF で出して FAKE_PS_RC で終わる
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/ps-calls"
printf '%s\r\n' "${FAKE_PS_OUT-set}"
exit "${FAKE_PS_RC:-0}"
EOF
  } >"${h}/bin/powershell.exe"
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
  chmod +x "${h}/bin/powershell.exe" "${h}/bin/pwsh.exe" "${h}/bin/wslpath" "${h}/bin/timeout"
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
ncalls() { grep -c '' "$1/ps-calls" 2>/dev/null || echo 0; }
npwsh() { grep -c '' "$1/pwsh-calls" 2>/dev/null || echo 0; }
pwsh_calls() { cat "$1/pwsh-calls" 2>/dev/null; }
record() { echo "$1/.local/state/dotfiles/powertoys-keyboard-manager.reloaded"; }
km_settings_json() { echo "$1/win/AppData/Local/Microsoft/PowerToys/Keyboard Manager/settings.json"; }

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
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 && -s $(record "${h}") ]] && outerr "${h}" | grep -q '読み直させました' \
  && grep -qF 'PowerToys_KeyboardManager_Event_Settings' "${h}/ps-calls" && grep -qF -- '-NoProfile' "${h}/ps-calls"; then
  ok "送れたら記録し、イベントの名前を渡す (CRLF の出力も読める)"
else
  ng "送れた" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 3. 同じ default.json: 呼ばない
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q '読み直し済み'; then
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
if [[ $(rc "${h}") == 0 && -s $(record "${h}") ]] && outerr "${h}" | grep -q '動いていません'; then
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
  if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 && -s $(record "${h}") ]] && outerr "${h}" | grep -q '読み直させました'; then
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
  && grep -q '設定画面を一度開いてから' "${h}/err" && ! outerr "${h}" | grep -q '読み直し済み'; then
  ok "記録があっても settings.json が無ければ、読み直し済みとは言わずに設定画面を一度開くよう出す (記録は変えない)"
else
  ng "記録があって settings.json が無い" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 7. powershell.exe が無い: 手で読み直す方法を出し、記録しない
h=$(new_home t7 "${state_on}" 1)
run "${h}" 1
if [[ $(rc "${h}") == 0 && ! -e $(record "${h}") ]] && outerr "${h}" | grep -q 'オフにしてオンに戻す'; then
  ok "powershell.exe が無ければ手で読み直す方法を出し、記録しない"
else
  ng "powershell.exe が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 8. powershell.exe が失敗する / 知らない出力: 手で読み直す方法を出し、記録しない
for t in "126:" "0:Exec format error"; do
  h=$(new_home "t8-${t%%:*}" "${state_on}" 1)
  FAKE_PS_RC=${t%%:*} FAKE_PS_OUT=${t#*:} run "${h}" 0
  if [[ $(rc "${h}") == 0 && ! -e $(record "${h}") ]] && outerr "${h}" | grep -q 'オフにしてオンに戻す'; then
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
if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 0 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q 'Install-PowerToys.ps1 がまだ配られていません'; then
  ok "Install-PowerToys.ps1 が配られていなければ pwsh.exe を呼ばずに、読み直しへ進む"
else
  ng "Install-PowerToys.ps1 が無い" "rc=$(rc "${h}") pwsh=$(npwsh "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 11. 入っている (-Check が 0): 入れずに読み直させる。pwsh.exe は -NoProfile -Check で、配った場所を渡す
h=$(new_home t11 "${state_on}" 1 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 1 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q 'PowerToys は入っています' \
  && outerr "${h}" | grep -q '読み直させました' && pwsh_calls "${h}" | grep -q -- '-NoProfile' \
  && pwsh_calls "${h}" | grep -q -- '-Check' && ! pwsh_calls "${h}" | grep -q -- '-IfMissing' \
  && pwsh_calls "${h}" | grep -qF 'C:\fake\Install-PowerToys.ps1' \
  && [[ $(head -n 1 "${h}/timeout-calls") == "60 pwsh.exe" ]]; then
  ok "入っていれば入れずに読み直させる (pwsh.exe は -NoProfile -Check、配った場所を渡す)"
else
  ng "入っている" "rc=$(rc "${h}") calls=$(pwsh_calls "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 11b. スクリプトが exit まで届かずに終わっても成功扱いにしない: 呼ぶ前に $LASTEXITCODE を 2 にしておく
# shellcheck disable=SC2016 # PowerShell の $global:… を文字のまま探す
if pwsh_calls "${h}" | grep -qF '$global:LASTEXITCODE = 2; &'; then
  ok "pwsh.exe には、スクリプトを呼ぶ前に \$LASTEXITCODE を 2 にするコマンドを渡す"
else
  ng "\$LASTEXITCODE を先に 2 にしていない" "calls=$(pwsh_calls "${h}")"
fi

# 12. 読み直し済みでも、入っているかは毎回確かめる (確かめてから「読み直し済み」で終わる)
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 2 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q '読み直し済み'; then
  ok "読み直し済みでも、入っているかは毎回確かめる"
else
  ng "読み直し済み" "rc=$(rc "${h}") pwsh=$(npwsh "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 13. 入っていない (-Check が 3): -IfMissing で入れてから読み直させる
h=$(new_home t13 "${state_on}" 1 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=0 FAKE_PWSH_OUT2="${added_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 2 && $(ncalls "${h}") == 1 && -s $(record "${h}") ]] \
  && pwsh_calls "${h}" | tail -n 1 | grep -q -- '-IfMissing' && outerr "${h}" | grep -q 'PowerToys を入れました' \
  && outerr "${h}" | grep -q '読み直させました' && ! outerr "${h}" | grep -q '⚠️' \
  && [[ $(tr '\n' ',' <"${h}/timeout-calls") == "60 pwsh.exe,600 pwsh.exe,60 powershell.exe," ]] \
  && grep -q 'winget で入れます' "${h}/out-at-ifmissing" && grep -q '600 秒まで待ちます' "${h}/out-at-ifmissing"; then
  ok "入っていなければ -IfMissing で入れてから読み直させる"
else
  ng "入っていない → 入れる" "rc=$(rc "${h}") calls=$(pwsh_calls "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 14. 入れられない (-IfMissing が 1): ⚠ で囲んで知らせ、それでも読み直しへ進む
h=$(new_home t14 "${state_on}" 1 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=1 FAKE_PWSH_OUT2=$'winget が失敗した (終了コード 0x8A150011)\e[0m' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q 'PowerToys を入れられませんでした (終了コード 1)' \
  && outerr "${h}" | grep -qF '0x8A150011' && outerr "${h}" | grep -qF 'PowerShell: Install-PowerToys' \
  && [[ $(outerr "${h}" | grep -c '⚠️') -ge 2 ]] && ! outerr "${h}" | grep -q $'\e\[' \
  && ! outerr "${h}" | grep -q $'\r'; then
  ok "入れられなければ ⚠ で囲んで知らせ、読み直しへ進んで exit 0 (端末でなければ色を付けない)"
else
  ng "入れられない" "rc=$(rc "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 15. -Check が 3 でもこちらの出力が無い・pwsh.exe が失敗する: 入れには行かず、手で打つコマンドを出して読み直しへ進む
for t in "3:Exec format error" "126:" "2:PowerToys (winget の Microsoft.PowerToys。版は固定しない)"; do
  h=$(new_home "t15-${t%%:*}" "${state_on}" 1 1)
  FAKE_PWSH_RC=${t%%:*} FAKE_PWSH_OUT=${t#*:} run "${h}" 0
  if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 1 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q '確かめられませんでした' \
    && outerr "${h}" | grep -qF 'Install-PowerToys'; then
    ok "pwsh.exe の出力が来ない・失敗する (rc=${t%%:*}) なら、入れずに手で打つコマンドを出して読み直しへ進む"
  else
    ng "pwsh.exe の失敗 (rc=${t%%:*})" "rc=$(rc "${h}") pwsh=$(npwsh "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
  fi
done

# 15b. -Check が 60 秒で時間切れ (124): 時間切れと出し、入れには行かず、手で打つコマンドを出して読み直しへ進む
h=$(new_home t15b "${state_on}" 1 1)
FAKE_PWSH_RC=124 FAKE_PWSH_OUT='' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 1 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q '60 秒たっても終わりませんでした' \
  && outerr "${h}" | grep -qF 'Install-PowerToys'; then
  ok "-Check が時間切れなら、時間切れと出して手で打つコマンドを出し、読み直しへ進む"
else
  ng "-Check の時間切れ" "rc=$(rc "${h}") pwsh=$(npwsh "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 15c. -IfMissing が 600 秒で時間切れ (124): ⚠ で囲んで 600 秒待ったと出し、読み直しへ進む
h=$(new_home t15c "${state_on}" 1 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=124 FAKE_PWSH_OUT2='' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q '600 秒待っても終わらない' \
  && [[ $(outerr "${h}" | grep -c '⚠️') -ge 2 ]]; then
  ok "-IfMissing が時間切れなら、⚠ で囲んで 600 秒待ったと出し、読み直しへ進む"
else
  ng "-IfMissing の時間切れ" "rc=$(rc "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 16. pwsh.exe が無い (powershell.exe はある): 手で打つコマンドを出して、読み直しへ進む
h=$(new_home t16 "${state_on}" 1 1)
run "${h}" 2
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 && -s $(record "${h}") ]] && outerr "${h}" | grep -q 'pwsh.exe が見つかりません' \
  && outerr "${h}" | grep -qF 'Install-PowerToys'; then
  ok "pwsh.exe が無ければ手で打つコマンドを出して、読み直しへ進む"
else
  ng "pwsh.exe が無い" "rc=$(rc "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 17. default.json がまだ無くても、PowerToys が入っているかは確かめる (入れるのは default.json に依らない)
h=$(new_home t17 "${state_on}" 0 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=0 FAKE_PWSH_OUT2="${added_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 2 && $(ncalls "${h}") == 0 ]] && outerr "${h}" | grep -q 'PowerToys を入れました' \
  && outerr "${h}" | grep -q 'default.json がまだありません'; then
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
if [[ $(rc "${h}") == 0 && ! -s ${h}/warnings ]] && outerr "${h}" | grep -q '読み直させました'; then
  ok "入っていて読み直させられたときは、まとめ用には何も残さない"
else
  ng "警告が無いのにまとめ用に残した" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null) $(outerr "${h}")"
fi

# 18. script に実行ビットがある (setup.sh は実行ビットの無い bootstrap を「実行できません」で止める)
if [[ -x ${script} ]]; then
  ok "script に実行ビットがある (setup.sh は実行できない bootstrap で止まる)"
else
  ng "script に実行ビットが無い" "$(ls -l "${script}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
