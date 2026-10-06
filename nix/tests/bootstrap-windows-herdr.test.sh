#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-herdr.sh の振る舞いを、使い捨ての HOME と
# 偽の pwsh.exe / wslpath で確かめる。
#
#   bash nix/tests/bootstrap-windows-herdr.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-herdr-test) が Nix のサンドボックスで流す。
# CI の `nix flake check` もこれを通る。使うのは bash・jq・coreutils・grep・sed だけ。
#
# ## 確かめること
#
#   - 配らないマシン・Install-Herdr.ps1 が無いときは pwsh.exe を呼ばずに飛ばす
#   - pwsh.exe が無い・失敗する・こちらの出力を返さないときは、手で打つコマンドを出して exit 0
#   - -Check が 0 なら 1 行だけ。1 なら ⚠ で囲んだ注意・状態・揃えるコマンドを出す
#   - -Check が 3 (入っていない) なら -IfMissing で入れる。入れられなければ ⚠ で囲んで知らせる
#   - どれも exit 0。--apply は -Check を付けずに流し、失敗なら exit 1。端末でなければ色を付けない
#
# ## 本物の pwsh.exe を見せない
#
# WSL では PATH に本物の pwsh.exe と wslpath がある。見えると本物の Windows で winget を
# 呼びうるので、要るコマンドだけを symlink で並べた PATH で流す (bootstrap-windows-openssh.test.sh
# と同じ作り)。偽の pwsh.exe と wslpath の shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-herdr.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-herdr-test.XXXXXX")
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

pkg='C:\Users\u\AppData\Local\Microsoft\WinGet\Packages\Herdr.Herdr.Preview_Microsoft.Winget.Source_8wekyb3d8bbwe'
v='0.9.2-preview.2026-09-29-8e78f929d8f0'

# Install-Herdr.ps1 -Check の出力 (pin だけ無いとき)
check_out="herdr (winget の Herdr.Herdr.Preview、${pkg})
  入っている版    : ${v}
  固定した版      : ${v} → そのまま
  winget の最新版 : ${v}
⚠ winget pin      : 無し → 足す
  PATH の herdr   : winget のもの
⚠️ 固定した版と揃っていない → Install-Herdr で揃える ⚠️"

# Install-Herdr.ps1 -Check の出力 (入っていないとき)
missing_out="herdr (winget の Herdr.Herdr.Preview、${pkg})
  入っている版    : 入っていない
⚠ 固定した版      : ${v} → 入れる
  winget の最新版 : ${v}
⚠ winget pin      : 無し → 足す
  PATH の herdr   : 見つからない
⚠️ herdr が入っていない → Install-Herdr で入れる ⚠️"

# Install-Herdr.ps1 -IfMissing が入れ終えたときの出力
installed_out="winget install --id Herdr.Herdr.Preview --exact --source winget --silent --accept-source-agreements --disable-interactivity --version ${v} --accept-package-agreements
  Successfully installed
winget pin を足した (winget upgrade --all から外れる)

herdr (winget の Herdr.Herdr.Preview、${pkg})
  入っている版    : ${v}
  固定した版      : ${v} → そのまま
  winget の最新版 : ${v}
  winget pin      : あり
  PATH の herdr   : winget のもの
揃った"

# 要るコマンドだけを並べた PATH (pwsh.exe と wslpath は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env jq grep sed tr cat head tail od mkdir mktemp mv rm dirname basename chmod timeout; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# 1 ケースぶんの HOME を作る。
#   $1: 名前、$2: windows-files.json の中身 (空なら作らない。@WIN@ は配り先に置き換える)
#   $3: 1 なら Install-Herdr.ps1 を配った状態にする
# 配り先 (Windows のホームに見立てる) は <HOME>/win。
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.local/state/dotfiles" "${h}/bin" "${h}/win"
  if [[ -n $2 ]]; then
    printf '%s\n' "${2//@WIN@/${h}/win}" >"${h}/.local/state/dotfiles/windows-files.json"
  fi
  if [[ $3 == 1 ]]; then
    mkdir -p "${h}/win/.config/powershell"
    printf '# Install-Herdr.ps1\n' >"${h}/win/.config/powershell/Install-Herdr.ps1"
  fi
  # 偽の pwsh.exe。引数を記録し、出力を行ごとに CRLF で出して終わる。
  # -IfMissing の呼び出しは FAKE_PWSH_OUT2 / FAKE_PWSH_RC2、ほかは FAKE_PWSH_OUT / FAKE_PWSH_RC を使う
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/pwsh-calls"
case "$*" in
  *-IfMissing*)
    out=${FAKE_PWSH_OUT2-}
    rc=${FAKE_PWSH_RC2:-0}
    ;;
  *)
    out=${FAKE_PWSH_OUT-}
    rc=${FAKE_PWSH_RC:-0}
    ;;
esac
if [[ -n ${out} ]]; then
  while IFS= read -r l; do printf '%s\r\n' "${l}"; done <<<"${out}"
fi
exit "${rc}"
EOF
  } >"${h}/bin/pwsh.exe"
  # 偽の wslpath。-w <パス> を C:\fake\<ファイル名> にする
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
[[ $1 == -w ]] || exit 1
printf 'C:\\fake\\%s\n' "${2##*/}"
EOF
  } >"${h}/bin/wslpath"
  chmod +x "${h}/bin/pwsh.exe" "${h}/bin/wslpath"
  echo "${h}"
}

# $1: HOME、$2: 1 なら偽の pwsh.exe を PATH に置かない、残り: script の引数。
# 環境変数 (FAKE_PWSH_*) は呼び出し側で付ける。
run() {
  local h=$1 nopwsh=$2
  shift 2
  local path="${h}/bin:${sys_bin}"
  if [[ ${nopwsh} == 1 ]]; then
    path="${h}/bin-nopwsh:${sys_bin}"
    mkdir -p "${h}/bin-nopwsh"
    ln -sf "${h}/bin/wslpath" "${h}/bin-nopwsh/wslpath"
  fi
  env HOME="${h}" PATH="${path}" "${BASH}" "${script}" "$@" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }
pwsh_called() { [[ -s $1/pwsh-calls ]]; }
calls() { cat "$1/pwsh-calls" 2>/dev/null; }
ncalls() { calls "$1" | grep -c ''; }
warn_lines() { outerr "$1" | grep -c '⚠️'; }

state_on='{"enable":true,"version":1,"windowsHome":"@WIN@"}'
state_off='{"enable":false,"version":1,"windowsHome":null}'

echo "== bootstrap-windows-herdr.sh: ${script}"

# 1. 状態ファイルが無い: 飛ばす
h=$(new_home t1 "" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && outerr "${h}" | grep -q '飛ばします'; then
  ok "windows-files.json が無ければ pwsh.exe を呼ばずに飛ばす"
else
  ng "状態ファイルが無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 2. enable = false: 飛ばす
h=$(new_home t2 "${state_off}" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && outerr "${h}" | grep -q '配りません'; then
  ok "enable = false なら pwsh.exe を呼ばずに飛ばす"
else
  ng "enable = false" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 3. Install-Herdr.ps1 が配られていない: 飛ばす
h=$(new_home t3 "${state_on}" 0)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && outerr "${h}" | grep -q 'まだ配られていません'; then
  ok "Install-Herdr.ps1 が配られていなければ飛ばす"
else
  ng "Install-Herdr.ps1 が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 4. pwsh.exe が無い: 手で打つコマンドを出して exit 0
h=$(new_home t4 "${state_on}" 1)
run "${h}" 1
if [[ $(rc "${h}") == 0 ]] && outerr "${h}" | grep -qF 'Install-Herdr -Check'; then
  ok "pwsh.exe が無ければ手で打つコマンドを出して exit 0"
else
  ng "pwsh.exe が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 5. pwsh.exe が失敗する (interop が落ちている): 手で打つコマンドを出して exit 0
h=$(new_home t5 "${state_on}" 1)
FAKE_PWSH_RC=126 FAKE_PWSH_OUT='' run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && outerr "${h}" | grep -qF 'Install-Herdr -Check' && outerr "${h}" | grep -q '確かめられませんでした'; then
  ok "pwsh.exe が失敗したら手で打つコマンドを出して exit 0"
else
  ng "pwsh.exe が失敗する" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 6. 揃っている (-Check が 0): 1 行だけで ⚠ は出さない。pwsh.exe は -NoProfile と -Check で、配った場所を渡す
h=$(new_home t6 "${state_on}" 1)
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${check_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 ]] && outerr "${h}" | grep -q '揃っています' \
  && calls "${h}" | grep -q -- '-NoProfile' && calls "${h}" | grep -q -- '-Check' \
  && calls "${h}" | grep -qF 'C:\fake\Install-Herdr.ps1'; then
  ok "揃っていれば 1 行だけ出して exit 0 (pwsh.exe は -NoProfile -Check、配った場所を渡す)"
else
  ng "揃っている" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 6b. スクリプトが exit まで届かずに終わっても成功扱いにしない: 呼ぶ前に $LASTEXITCODE を 2 にしておく
# shellcheck disable=SC2016 # PowerShell の $global:… を文字のまま探す
if calls "${h}" | grep -qF '$global:LASTEXITCODE = 2; &'; then
  ok "pwsh.exe には、スクリプトを呼ぶ前に \$LASTEXITCODE を 2 にするコマンドを渡す"
else
  ng "\$LASTEXITCODE を先に 2 にしていない" "calls=$(calls "${h}")"
fi

# 7. 差がある (-Check が 1): ⚠ で上下を囲み、状態と揃えるコマンドと hsvstop を出す。setup は止めない
h=$(new_home t7 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${check_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 ]] && outerr "${h}" | grep -q '揃っていません' \
  && outerr "${h}" | grep -qF '⚠ winget pin      : 無し → 足す' \
  && outerr "${h}" | grep -qF -- 'bootstrap-windows-herdr.sh --apply' && outerr "${h}" | grep -qF 'Install-Herdr' \
  && outerr "${h}" | grep -qF 'hsvstop' && [[ $(ncalls "${h}") == 1 ]]; then
  ok "差があれば ⚠ で囲んだ注意と状態と揃えるコマンドを出して exit 0 (入れ替えはしない)"
else
  ng "差がある" "rc=$(rc "${h}") warn_lines=$(warn_lines "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi
if ! outerr "${h}" | grep -qF '揃っていない → Install-Herdr'; then
  ok "PowerShell の締めの 1 行は、枠の揃えるコマンドと重なるので出さない"
else
  ng "締めの 1 行が重なっている" "$(outerr "${h}")"
fi
if ! outerr "${h}" | grep -q $'\e\['; then
  ok "端末でなければ色 (エスケープ) を付けない"
else
  ng "端末でないのに色が付いている" "$(outerr "${h}" | od -c | head -5)"
fi
if ! outerr "${h}" | grep -q $'\r'; then
  ok "pwsh.exe の CRLF は落として出す"
else
  ng "CR が残っている" "$(outerr "${h}" | od -c | head -5)"
fi

# 8. -Check が 1 でも、こちらの出力が無い (スクリプトが壊れている等): 差とは扱わず、手で打つコマンドを出す
h=$(new_home t8 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT='The term is not recognized as a name of a cmdlet' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 ]] && outerr "${h}" | grep -q '確かめられませんでした' \
  && outerr "${h}" | grep -qF 'Install-Herdr -Check'; then
  ok "-Check の出力が来なければ差とは扱わず、手で打つコマンドを出して exit 0"
else
  ng "出力が来ない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 9. 入っていない (-Check が 3): -IfMissing で入れる。入ったら ⚠ は出さない
h=$(new_home t9 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=0 FAKE_PWSH_OUT2="${installed_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 && $(ncalls "${h}") == 2 ]] && outerr "${h}" | grep -q '入れました' \
  && calls "${h}" | tail -n 1 | grep -q -- '-IfMissing' && ! calls "${h}" | tail -n 1 | grep -q -- '-Check'; then
  ok "入っていなければ -IfMissing で入れて exit 0"
else
  ng "入っていない → 入れる" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 10. 入っていないので入れようとしたが失敗: ⚠ で囲んで知らせる。setup は止めない
h=$(new_home t10 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=1 FAKE_PWSH_OUT2='winget が失敗した (終了コード 0x8A150014)' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 ]] && outerr "${h}" | grep -q '入れられませんでした' \
  && outerr "${h}" | grep -qF '0x8A150014' && outerr "${h}" | grep -qF -- 'bootstrap-windows-herdr.sh --apply'; then
  ok "入れられなければ ⚠ で囲んで知らせて exit 0"
else
  ng "入れられない" "rc=$(rc "${h}") warn_lines=$(warn_lines "${h}") $(outerr "${h}")"
fi

# 11. -Check が 3 でも、こちらの出力が無い: 入れには行かず、手で打つコマンドを出す
h=$(new_home t11 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT='Exec format error' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q '確かめられませんでした' \
  && outerr "${h}" | grep -qF 'Install-Herdr -Check'; then
  ok "-Check が 3 でも出力が来なければ、入れずに手で打つコマンドを出す"
else
  ng "3 だが出力が来ない" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 12. --apply: -Check も -IfMissing も付けずに流す。成功なら exit 0
h=$(new_home t12 "${state_on}" 1)
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="揃った" run "${h}" 0 --apply
if [[ $(rc "${h}") == 0 ]] && pwsh_called "${h}" && ! calls "${h}" | grep -q -- '-Check' \
  && ! calls "${h}" | grep -q -- '-IfMissing' && calls "${h}" | grep -qF 'C:\fake\Install-Herdr.ps1' \
  && outerr "${h}" | grep -q '揃いました'; then
  ok "--apply は -Check を付けずに流し、成功なら exit 0"
else
  ng "--apply 成功" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 13. --apply が失敗: exit 1 (手で流すものなので失敗を返す)
h=$(new_home t13 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="herdr.exe などが動いていて置き換えられない" run "${h}" 0 --apply
if [[ $(rc "${h}") == 1 ]] && outerr "${h}" | grep -q '揃いませんでした'; then
  ok "--apply が失敗したら exit 1"
else
  ng "--apply 失敗" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 14. 揃っているが winget に新しい版がある: 1 行に加えて ※ の行も出す (ずれではないので ⚠ にはしない)
h=$(new_home t14 "${state_on}" 1)
newer='※ winget に固定した版より新しい 0.9.3-preview.2026-10-05-0123456789ab がある。上げるなら Install-Herdr.ps1 の -Version の既定値を変える'
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${check_out}"$'\n'"${newer}"$'\n揃っている' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 ]] && outerr "${h}" | grep -q '揃っています' \
  && outerr "${h}" | grep -qF "${newer}"; then
  ok "揃っていても、winget に新しい版があれば ※ の行を出す"
else
  ng "新しい版がある" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 15. pwsh.exe の出力に色のエスケープが混ざっていても、取り除いてから枠に入れる
h=$(new_home t15 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="herdr (winget の Herdr.Herdr.Preview、${pkg})"$'\n\e[33m⚠ winget pin      : 無し → 足す\e[0m' run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! outerr "${h}" | grep -q $'\e' && outerr "${h}" | grep -qF '⚠ winget pin      : 無し → 足す'; then
  ok "pwsh.exe の色のエスケープは取り除いて出す"
else
  ng "エスケープが残る" "rc=$(rc "${h}") $(outerr "${h}" | od -c | head -8)"
fi

# 16. 知らない引数: exit 2
h=$(new_home t16 "${state_on}" 1)
run "${h}" 0 --bogus
if [[ $(rc "${h}") == 2 ]] && ! pwsh_called "${h}"; then
  ok "知らない引数は exit 2"
else
  ng "知らない引数" "rc=$(rc "${h}") $(outerr "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
