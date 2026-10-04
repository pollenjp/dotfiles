#!/usr/bin/env bash
# shellcheck shell=bash
# PowerShell の $PROFILE や $HOME を文字のまま書く所が多いので、ファイル全体で SC2016 を止める
# shellcheck disable=SC2016
#
# nix/scripts/bootstrap-windows-powershell-profile.sh の振る舞いを、使い捨ての HOME と
# 偽の pwsh.exe / wslpath で確かめる。
#
#   bash nix/tests/bootstrap-windows-powershell-profile.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-powershell-profile-test) が Nix のサンドボックスで流す。
# CI の `nix flake check` もこれを通る。使うのは bash・jq・coreutils・grep・sed だけ。
#
# ## 確かめること
#
#   - 配らないマシン・dotfiles.ps1 が無いときは pwsh.exe を呼ばずに飛ばす
#   - pwsh.exe が無い・失敗する・パスを返さないときは、手で打つコマンドを出して exit 0
#   - $PROFILE が無ければ作り、改行 (CRLF / LF・末尾の改行の有無) を合わせて 1 行を足す
#   - 1 行が既にあれば変えない。足した記録があって消えていたら足し直さず、--force で足す
#   - --dry-run は書かない。UTF-16 の $PROFILE には書かない。壊れた記録では止まる
#
# ## 本物の pwsh.exe を見せない
#
# WSL では PATH に本物の pwsh.exe と wslpath がある。見えると本物の $PROFILE を書き換える
# ので、要るコマンドだけを symlink で並べた PATH で流す。偽の pwsh.exe と wslpath は
# ケースごとの bin に置き、その shebang は $BASH から作る (Nix のサンドボックスには
# /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-powershell-profile.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-powershell-profile-test.XXXXXX")
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

# script が足す 1 行 (script 側と同じ文字列)
line='if (Test-Path "$HOME\.config\powershell\dotfiles.ps1") { . "$HOME\.config\powershell\dotfiles.ps1" }'
win_profile='C:\Users\tester\OneDrive\ドキュメント\PowerShell\Microsoft.PowerShell_profile.ps1'

# 要るコマンドだけを並べた PATH (pwsh.exe と wslpath は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env jq grep sed tr cat head tail od mkdir mktemp mv rm dirname chmod timeout; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# 1 ケースぶんの HOME を作る。
#   $1: 名前、$2: windows-files.json の中身 (空なら作らない。@WIN@ は配り先に置き換える)
#   $3: 1 なら dotfiles.ps1 を配った状態にする
# 配り先 (Windows のホームに見立てる) は <HOME>/win、/mnt は <HOME>/mnt。
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.local/state/dotfiles" "${h}/bin" "${h}/win" "${h}/mnt/c/Users/tester"
  if [[ -n $2 ]]; then
    printf '%s\n' "${2//@WIN@/${h}/win}" >"${h}/.local/state/dotfiles/windows-files.json"
  fi
  if [[ $3 == 1 ]]; then
    mkdir -p "${h}/win/.config/powershell"
    printf '# dotfiles.ps1\n' >"${h}/win/.config/powershell/dotfiles.ps1"
  fi
  # 偽の pwsh.exe。引数を記録し、FAKE_PWSH_OUT を CRLF で出して FAKE_PWSH_RC で終わる
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/pwsh-calls"
if [[ -n ${FAKE_PWSH_OUT-} ]]; then
  printf '%s\r\n' "${FAKE_PWSH_OUT}"
fi
exit "${FAKE_PWSH_RC:-0}"
EOF
  } >"${h}/bin/pwsh.exe"
  # 偽の wslpath。-u C:\… を <HOME>/mnt/c/… にする
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
[[ $1 == -u ]] || exit 1
p=${2//\\//}
printf '%s\n' "${HOME}/mnt/c${p#C:}"
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
profile() { printf '%s' "$1/mnt/c/Users/tester/OneDrive/ドキュメント/PowerShell/Microsoft.PowerShell_profile.ps1"; }
record() { cat "$1/.local/state/dotfiles/windows-powershell-profile.json" 2>/dev/null; }
pwsh_called() { [[ -s $1/pwsh-calls ]]; }
hex() { od -An -tx1 "$1" | tr -d ' \n'; }

state_on='{"enable":true,"version":1,"windowsHome":"@WIN@"}'
state_off='{"enable":false,"version":1,"windowsHome":null}'
export FAKE_PWSH_OUT="${win_profile}"

echo "== bootstrap-windows-powershell-profile.sh: ${script}"

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

# 3. dotfiles.ps1 が配られていない: 飛ばす
h=$(new_home t3 "${state_on}" 0)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && outerr "${h}" | grep -q 'まだ配られていません'; then
  ok "dotfiles.ps1 が配られていなければ飛ばす"
else
  ng "dotfiles.ps1 が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 4. pwsh.exe が無い: 手で打つコマンドを出して exit 0
h=$(new_home t4 "${state_on}" 1)
run "${h}" 1
if [[ $(rc "${h}") == 0 && ! -e $(profile "${h}") ]] && outerr "${h}" | grep -qF "Add-Content -Path \$PROFILE -Value '${line}'"; then
  ok "pwsh.exe が無ければ手で打つコマンドを出して exit 0"
else
  ng "pwsh.exe が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 5. pwsh.exe が失敗する (interop が落ちている): 手で打つコマンドを出して exit 0
h=$(new_home t5 "${state_on}" 1)
FAKE_PWSH_RC=126 FAKE_PWSH_OUT='' run "${h}" 0
if [[ $(rc "${h}") == 0 && ! -e $(profile "${h}") ]] && outerr "${h}" | grep -qF 'Add-Content -Path $PROFILE'; then
  ok "pwsh.exe が失敗したら手で打つコマンドを出して exit 0"
else
  ng "pwsh.exe が失敗する" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 6. pwsh.exe が Windows のパスを返さない: 手で打つコマンドを出して exit 0
h=$(new_home t6 "${state_on}" 1)
FAKE_PWSH_OUT='WARNING: something' run "${h}" 0
if [[ $(rc "${h}") == 0 && ! -e $(profile "${h}") ]] && outerr "${h}" | grep -qF 'Add-Content -Path $PROFILE'; then
  ok "pwsh.exe が Windows のパスを返さなければ手で打つコマンドを出して exit 0"
else
  ng "パスを返さない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 7. $PROFILE が無い: 親ごと作って 1 行 (LF) を書き、記録する。pwsh.exe は -NoProfile で呼ぶ
h=$(new_home t7 "${state_on}" 1)
run "${h}" 0
p=$(profile "${h}")
if [[ $(rc "${h}") == 0 && -f ${p} && $(cat "${p}") == "${line}" ]] && [[ $(hex "${p}") == *0a && $(hex "${p}") != *0d0a ]] \
  && [[ $(jq -r --arg k "${p}" '.[$k]' <<<"$(record "${h}")") == added ]] && grep -q -- '-NoProfile' "${h}/pwsh-calls"; then
  ok "\$PROFILE が無ければ作って 1 行を書き (LF)、記録する"
else
  ng "\$PROFILE が無い" "rc=$(rc "${h}") record=$(record "${h}") calls=$(cat "${h}/pwsh-calls" 2>/dev/null) $(outerr "${h}")"
fi
if outerr "${h}" | grep -qF '. $PROFILE'; then
  ok "足したら . \$PROFILE で読み直すよう案内する"
else
  ng "読み直しの案内" "$(outerr "${h}")"
fi

# 8. 2 回目: 変えない
before=$(hex "${p}")
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(hex "${p}") == "${before}" ]] && outerr "${h}" | grep -q '読み込み済み'; then
  ok "2 回流しても変わらない"
else
  ng "2 回目" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 9. CRLF で末尾に改行が無い $PROFILE: CRLF を補ってから CRLF で足す
h=$(new_home t9 "${state_on}" 1)
p=$(profile "${h}")
mkdir -p "$(dirname "${p}")"
printf 'Invoke-Expression (&starship init powershell)\r\n# 末尾に改行なし' >"${p}"
run "${h}" 0
want=$(printf 'Invoke-Expression (&starship init powershell)\r\n# 末尾に改行なし\r\n%s\r\n' "${line}" | od -An -tx1 | tr -d ' \n')
if [[ $(rc "${h}") == 0 && $(hex "${p}") == "${want}" ]]; then
  ok "CRLF の \$PROFILE には末尾の改行を補ってから CRLF で足す"
else
  ng "CRLF・末尾の改行なし" "rc=$(rc "${h}") got=$(cat -A "${p}" 2>/dev/null || cat "${p}")"
fi

# 10. LF で末尾に改行がある $PROFILE: そのまま LF で足す
h=$(new_home t10 "${state_on}" 1)
p=$(profile "${h}")
mkdir -p "$(dirname "${p}")"
printf 'Set-PSReadLineOption -EditMode Emacs\n' >"${p}"
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(cat "${p}") == "Set-PSReadLineOption -EditMode Emacs"$'\n'"${line}" ]] && [[ $(hex "${p}") != *0d* ]]; then
  ok "LF の \$PROFILE には LF で足す"
else
  ng "LF" "rc=$(rc "${h}") got=$(cat "${p}")"
fi

# 11. 既に 1 行がある (記録なし): 変えずに記録だけ付ける
h=$(new_home t11 "${state_on}" 1)
p=$(profile "${h}")
mkdir -p "$(dirname "${p}")"
printf '. "$HOME\\.config\\powershell\\dotfiles.ps1"\n' >"${p}"
before=$(hex "${p}")
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(hex "${p}") == "${before}" ]] && [[ $(jq -r --arg k "${p}" '.[$k]' <<<"$(record "${h}")") == added ]]; then
  ok "dotfiles.ps1 を読む行が既にあれば変えず、記録だけ付ける"
else
  ng "既にある" "rc=$(rc "${h}") record=$(record "${h}") $(outerr "${h}")"
fi

# 12. 記録があって 1 行が消えている: 足し直さず知らせる
printf 'Invoke-Expression (&starship init powershell)\n' >"${p}"
before=$(hex "${p}")
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(hex "${p}") == "${before}" ]] && outerr "${h}" | grep -q -- '--force'; then
  ok "足した記録があって消えていれば、足し直さず --force を案内する"
else
  ng "消えている" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 13. 12 の後に --force: 足し直す
run "${h}" 0 --force
if [[ $(rc "${h}") == 0 && $(cat "${p}") == "Invoke-Expression (&starship init powershell)"$'\n'"${line}" ]]; then
  ok "--force なら足し直す"
else
  ng "--force" "rc=$(rc "${h}") got=$(cat "${p}") $(outerr "${h}")"
fi

# 14. --dry-run: $PROFILE も記録も書かない
h=$(new_home t14 "${state_on}" 1)
run "${h}" 0 --dry-run
if [[ $(rc "${h}") == 0 && ! -e $(profile "${h}") && -z $(record "${h}") ]] && outerr "${h}" | grep -q '\[dry-run\]'; then
  ok "--dry-run は \$PROFILE にも記録にも書かない"
else
  ng "--dry-run" "rc=$(rc "${h}") record=$(record "${h}") $(outerr "${h}")"
fi

# 15. UTF-16LE の $PROFILE: 書かずに手で打つコマンドを出す
h=$(new_home t15 "${state_on}" 1)
p=$(profile "${h}")
mkdir -p "$(dirname "${p}")"
printf '\xff\xfe#\x00\n\x00' >"${p}"
before=$(hex "${p}")
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(hex "${p}") == "${before}" ]] && outerr "${h}" | grep -qF 'Add-Content -Path $PROFILE'; then
  ok "UTF-16 の \$PROFILE には書かず、手で打つコマンドを出す"
else
  ng "UTF-16" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 16. 記録が壊れている: exit 1
h=$(new_home t16 "${state_on}" 1)
printf 'not json\n' >"${h}/.local/state/dotfiles/windows-powershell-profile.json"
run "${h}" 0
if [[ $(rc "${h}") == 1 && ! -e $(profile "${h}") ]]; then
  ok "記録が壊れていれば書かずに exit 1"
else
  ng "壊れた記録" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 17. 知らない引数: exit 2
h=$(new_home t17 "${state_on}" 1)
run "${h}" 0 --bogus
if [[ $(rc "${h}") == 2 ]]; then
  ok "知らない引数は exit 2"
else
  ng "知らない引数" "rc=$(rc "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
