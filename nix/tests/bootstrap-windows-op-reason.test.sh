#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-op-reason.sh の振る舞いを、使い捨ての HOME と
# 偽の pwsh.exe / wslpath で確かめる。
#
#   bash nix/tests/bootstrap-windows-op-reason.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-op-reason-test) が Nix のサンドボックスで流す。
# CI の `nix flake check` もこれを通る。使うのは bash・jq・coreutils・grep・sed だけ。
#
# ## 確かめること
#
#   - 配らないマシン (windows-files.json が無い・enable が false)・WSL の op の wrapper を入れないマシン
#     (claude-op-reason.json の enable が false か、そのファイルが無い)・Install-OpReason.ps1 が無いときは pwsh.exe を呼ばずに
#     飛ばす。配らないのに WSL の op を入れるマシンでだけ、Windows に手で入れるよう 1 行添える (まとめ用には残さない)
#   - pwsh.exe が無い・失敗する・こちらの出力を返さないときは、手で打つコマンドを出して exit 0
#   - -Check が 0 なら 1 行だけ。1 (差がある) でも 3 (入っていない) でも、引数なしで流して揃え、揃えば ⚠ は出さない
#   - 揃える流れが失敗したら、⚠ で囲んだ注意・pwsh.exe の出力・揃えるコマンド (op の呼び出しが終わってから) を出す
#   - どれも exit 0。--apply は -Check を付けずに流し、失敗なら exit 1。端末でなければ色を付けず、CRLF と色を落とす
#   - setup から走るとき (DOTFILES_SETUP_WARNINGS がある) は、⚠ の見出しと揃えるコマンド
#     (確かめられないときは手で打つコマンド) を setup の最後のまとめ用のファイルにも残す
#   - 冒頭の見出しに setup が読む order (97) と tool (onePassword) がある
#
# ## 本物の pwsh.exe を見せない
#
# WSL では PATH に本物の pwsh.exe と wslpath がある。見えると本物の Windows で zip を落として置きうるので、
# 要るコマンドだけを symlink で並べた PATH で流す (bootstrap-windows-type-clipboard.test.sh と同じ作り)。
# 偽の pwsh.exe と wslpath の shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-op-reason.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-op-reason-test.XXXXXX")
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

dir='C:\Users\u\AppData\Local\Programs\op-reason'
v='0.1.0'

# Install-OpReason.ps1 -Check の出力 (古い版が入っているとき)
check_out="op-reason (GitHub の Release、${dir})
  入っている版     : 0.0.9
⚠ 固定した版       : ${v} → 入れ替える (上げる)
⚠️ 固定した版と揃っていない → Install-OpReason で揃える ⚠️"

# Install-OpReason.ps1 -Check の出力 (揃っているとき)
synced_out="op-reason (GitHub の Release、${dir})
  入っている版     : ${v}
  固定した版       : ${v} → そのまま
揃っている"

# Install-OpReason.ps1 -Check の出力 (入っていないとき)
missing_out="op-reason (GitHub の Release、${dir})
  入っている版     : 入っていない
⚠ 固定した版       : ${v} → 入れる
⚠️ op-reason が入っていない → Install-OpReason で入れる ⚠️"

# Install-OpReason.ps1 (引数なし) が揃え終えたときの出力
applied_out="op-reason (GitHub の Release、${dir})
  入っている版     : 0.0.9
⚠ 固定した版       : ${v} → 入れ替える (上げる)
落とす: https://github.com/pollenjp/op-reason/releases/download/v${v}/op-reason-windows.zip
置いた: ${dir}

op-reason (GitHub の Release、${dir})
  入っている版     : ${v}
  固定した版       : ${v} → そのまま
揃った"

# Install-OpReason.ps1 (引数なし) が、動いている op-reason.exe で止まったときの出力
busy_out="op-reason (GitHub の Release、${dir})
  入っている版     : 0.0.9
⚠ 固定した版       : ${v} → 入れ替える (上げる)
※ op-reason.exe が 1 個動いている (op の呼び出しの途中)。入れ替えるには、その呼び出しが終わってから打ち直す (このスクリプトは止めない)
op-reason.exe が動いていて置き場所を入れ替えられない。op の呼び出しが終わってから打ち直す (このスクリプトは止めない):
  4242  ${dir}\\op-reason.exe"

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
#   $3: claude-op-reason.json の中身 (空なら作らない)、$4: 1 なら Install-OpReason.ps1 を配った状態にする
# 配り先 (Windows のホームに見立てる) は <HOME>/win。
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.local/state/dotfiles" "${h}/bin" "${h}/win"
  if [[ -n $2 ]]; then
    printf '%s\n' "${2//@WIN@/${h}/win}" >"${h}/.local/state/dotfiles/windows-files.json"
  fi
  if [[ -n $3 ]]; then
    printf '%s\n' "$3" >"${h}/.local/state/dotfiles/claude-op-reason.json"
  fi
  if [[ $4 == 1 ]]; then
    mkdir -p "${h}/win/.config/powershell"
    printf '# Install-OpReason.ps1\n' >"${h}/win/.config/powershell/Install-OpReason.ps1"
  fi
  # 偽の pwsh.exe。引数を記録し、出力を行ごとに CRLF で出して終わる。
  # -Check の呼び出しは FAKE_PWSH_OUT / FAKE_PWSH_RC、揃える呼び出し (引数なし) は FAKE_PWSH_OUT2 / FAKE_PWSH_RC2 を使う
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/pwsh-calls"
case "$*" in
  *-Check*)
    o=${FAKE_PWSH_OUT-}
    rc=${FAKE_PWSH_RC:-0}
    ;;
  *)
    o=${FAKE_PWSH_OUT2-}
    rc=${FAKE_PWSH_RC2:-0}
    ;;
esac
if [[ -n ${o} ]]; then
  while IFS= read -r l; do printf '%s\r\n' "${l}"; done <<<"${o}"
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
# 判定の grep -q はパイプで受けず、ファイルを直に読む (pjp-shell-traps の SIGPIPE と pipefail)。
# $1: ケースのディレクトリ、残り: grep の引数
seen() {
  local d=$1
  shift
  grep -q "$@" "${d}/out" "${d}/err"
}
pwsh_called() { [[ -s $1/pwsh-calls ]]; }
calls() { cat "$1/pwsh-calls" 2>/dev/null; }
# pwsh.exe の呼び出しの記録 (1 回 1 行) に、grep の引数で合う行があるか。記録が無ければ合わない
called() {
  local h=$1
  shift
  grep -qs "$@" "${h}/pwsh-calls"
}
# 最後の pwsh.exe の呼び出しが、grep の引数で合うか
called_last() {
  local h=$1
  shift
  grep -q "$@" <<<"$(tail -n 1 "${h}/pwsh-calls" 2>/dev/null)"
}
ncalls() { grep -cs '' "$1/pwsh-calls"; }

state_on='{"enable":true,"version":1,"windowsHome":"@WIN@"}'
state_off='{"enable":false,"version":1,"windowsHome":null}'
op_on='{"enable":true}'
op_off='{"enable":false}'

echo "== bootstrap-windows-op-reason.sh: ${script}"

# 0. 見出しに setup が読む order と tool がある (setup.sh の script_order・script_tool が先頭 40 行から読む)
if head -n 40 "${script}" >"${work}/head" && grep -qxF '# order: 97' "${work}/head" \
  && grep -qxF '# tool: onePassword (dotfiles.onePassword.enable)' "${work}/head"; then
  ok "見出しに order: 97 と tool: onePassword がある"
else
  ng "見出しの order・tool" "$(cat "${work}/head")"
fi

# 1. windows-files.json が無い: 飛ばす
h=$(new_home t1 "" "${op_on}" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" '飛ばします'; then
  ok "windows-files.json が無ければ pwsh.exe を呼ばずに飛ばす"
else
  ng "windows-files.json が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 2. enable = false で WSL の op を入れるマシン: 飛ばし、Windows に手で入れるよう 1 行添える
h=$(new_home t2 "${state_off}" "${op_on}" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" '配りません' && seen "${h}" -F '手で入れます'; then
  ok "enable = false でも WSL の op を入れるマシンなら、飛ばして Windows に手で入れるよう添える"
else
  ng "enable = false (op あり)" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 2b. enable = false で WSL の op を入れないマシン: 飛ばすだけ (手で入れる話はしない)
h=$(new_home t2b "${state_off}" "${op_off}" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" '配りません' && ! seen "${h}" -F '手で入れます'; then
  ok "enable = false で WSL の op も入れないマシンなら、飛ばすだけ"
else
  ng "enable = false (op なし)" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 3. claude-op-reason.json の enable = false: 飛ばす (条件の option の名前を出す)
h=$(new_home t3 "${state_on}" "${op_off}" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" -F 'dotfiles.onePassword.enable'; then
  ok "WSL の op の wrapper を入れないマシン (claude-op-reason.json の enable が false) なら pwsh.exe を呼ばずに飛ばす"
else
  ng "op の wrapper を入れない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 4. claude-op-reason.json が無い (switch の前の世代): 入れないマシンとして飛ばす
h=$(new_home t4 "${state_on}" "" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" -F 'op の wrapper (op-reason) を入れません'; then
  ok "claude-op-reason.json が無ければ、入れないマシンとして飛ばす"
else
  ng "claude-op-reason.json が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 5. Install-OpReason.ps1 が配られていない: 飛ばす
h=$(new_home t5 "${state_on}" "${op_on}" 0)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" 'まだ配られていません'; then
  ok "Install-OpReason.ps1 が配られていなければ飛ばす"
else
  ng "Install-OpReason.ps1 が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 6. pwsh.exe が無い: 手で打つコマンドを出して exit 0
h=$(new_home t6 "${state_on}" "${op_on}" 1)
run "${h}" 1
if [[ $(rc "${h}") == 0 ]] && seen "${h}" -F 'Install-OpReason -Check'; then
  ok "pwsh.exe が無ければ手で打つコマンドを出して exit 0"
else
  ng "pwsh.exe が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 7. pwsh.exe が失敗する (interop が落ちている): 手で打つコマンドを出して exit 0
h=$(new_home t7 "${state_on}" "${op_on}" 1)
FAKE_PWSH_RC=126 FAKE_PWSH_OUT='' run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && seen "${h}" -F 'Install-OpReason -Check' && seen "${h}" '確かめられませんでした' \
  && [[ $(ncalls "${h}") == 1 ]]; then
  ok "pwsh.exe が失敗したら手で打つコマンドを出して exit 0 (揃えには行かない)"
else
  ng "pwsh.exe が失敗する" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 8. 揃っている (-Check が 0): 1 行だけで ⚠ は出さない。pwsh.exe は -NoProfile と -Check で、配った場所を渡す
h=$(new_home t8 "${state_on}" "${op_on}" 1)
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${synced_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! seen "${h}" -F '⚠️' && seen "${h}" '揃っています' \
  && called "${h}" -- '-NoProfile' && called "${h}" -- '-Check' \
  && called "${h}" -F 'C:\fake\Install-OpReason.ps1' && [[ $(ncalls "${h}") == 1 ]]; then
  ok "揃っていれば 1 行だけ出して exit 0 (pwsh.exe は -NoProfile -Check、配った場所を渡す)"
else
  ng "揃っている" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 8b. スクリプトが exit まで届かずに終わっても成功扱いにしない: 呼ぶ前に $LASTEXITCODE を 2 にしておく
# shellcheck disable=SC2016 # PowerShell の $global:… を文字のまま探す
if called "${h}" -F '$global:LASTEXITCODE = 2; &'; then
  ok "pwsh.exe には、スクリプトを呼ぶ前に \$LASTEXITCODE を 2 にするコマンドを渡す"
else
  ng "\$LASTEXITCODE を先に 2 にしていない" "calls=$(calls "${h}")"
fi

# 9. 差がある (-Check が 1): 引数なしで流して入れ替え、揃えば ⚠ は出さない
h=$(new_home t9 "${state_on}" "${op_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${check_out}" FAKE_PWSH_RC2=0 FAKE_PWSH_OUT2="${applied_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 2 ]] && ! seen "${h}" -F '⚠️ ━' && seen "${h}" '入れ替えます' \
  && seen "${h}" '揃えました' && called_last "${h}" -F 'C:\fake\Install-OpReason.ps1' && ! called_last "${h}" -- '-Check'; then
  ok "差があれば、引数なしで流して入れ替え、揃えば exit 0 (type-clipboard と違って入れ替えまでする)"
else
  ng "差がある → 入れ替える" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi
if ! seen "${h}" $'\r'; then
  ok "pwsh.exe の CRLF は落として出す"
else
  ng "CR が残っている" "$(outerr "${h}" | od -c | head -5)"
fi

# 10. -Check が 1 でも、こちらの出力が無い (スクリプトが壊れている等): 差とは扱わず、手で打つコマンドを出す
h=$(new_home t10 "${state_on}" "${op_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT='The term is not recognized as a name of a cmdlet' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && ! seen "${h}" -F '⚠️' && seen "${h}" '確かめられませんでした' \
  && seen "${h}" -F 'Install-OpReason -Check'; then
  ok "-Check の出力が来なければ差とは扱わず、揃えに行かずに手で打つコマンドを出して exit 0"
else
  ng "出力が来ない" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 11. 入っていない (-Check が 3): 引数なしで流して入れる。入ったら ⚠ は出さない
h=$(new_home t11 "${state_on}" "${op_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=0 FAKE_PWSH_OUT2="${applied_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 2 ]] && ! seen "${h}" -F '⚠️ ━' && seen "${h}" '入れました' \
  && seen "${h}" -F 'OPREASON_EXE' && ! called_last "${h}" -- '-Check'; then
  ok "入っていなければ、引数なしで流して入れて exit 0"
else
  ng "入っていない → 入れる" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 12. 入っていないので入れようとしたが失敗: ⚠ で囲んで知らせる。setup は止めない
h=$(new_home t12 "${state_on}" "${op_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=1 FAKE_PWSH_OUT2='zip の SHA-256 が固定した値と合わないので置かない (何も変えていない)' run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && seen "${h}" -F '⚠️ ━' && seen "${h}" '入れられませんでした' \
  && seen "${h}" -F 'zip の SHA-256 が固定した値と合わない' && seen "${h}" -F -- 'bootstrap-windows-op-reason.sh --apply' \
  && seen "${h}" -F 'PowerShell: Install-OpReason'; then
  ok "入れられなければ ⚠ で囲んで、出力と揃えるコマンドを出して exit 0"
else
  ng "入れられない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 13. 入れ替えようとしたが、op-reason.exe が動いていて止まった: 枠に出力と、呼び出しが終わってから揃えることを出す
h=$(new_home t13 "${state_on}" "${op_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${check_out}" FAKE_PWSH_RC2=1 FAKE_PWSH_OUT2="${busy_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && seen "${h}" '揃えられませんでした (終了コード 1)' && seen "${h}" -F '4242' \
  && seen "${h}" -F 'op の呼び出しが終わってから' && seen "${h}" -F -- 'bootstrap-windows-op-reason.sh --apply'; then
  ok "動いていて入れ替えられなければ、PID と、op の呼び出しが終わってから揃えることを ⚠ の枠に出す"
else
  ng "動いていて入れ替えられない" "rc=$(rc "${h}") $(outerr "${h}")"
fi
if ! seen "${h}" -F '揃っていない → Install-OpReason'; then
  ok "-Check の締めの 1 行 (⚠️ … → Install-OpReason) は出さない (揃える流れの出力と枠の揃えるコマンドだけ)"
else
  ng "-Check の締めの 1 行が出ている" "$(outerr "${h}")"
fi
if ! seen "${h}" $'\e\['; then
  ok "端末でなければ色 (エスケープ) を付けない"
else
  ng "端末でないのに色が付いている" "$(outerr "${h}" | od -c | head -5)"
fi

# 14. -Check が 3 でも、こちらの出力が無い: 入れには行かず、手で打つコマンドを出す
h=$(new_home t14 "${state_on}" "${op_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT='Exec format error' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && seen "${h}" '確かめられませんでした' \
  && seen "${h}" -F 'Install-OpReason -Check'; then
  ok "-Check が 3 でも出力が来なければ、入れずに手で打つコマンドを出す"
else
  ng "3 だが出力が来ない" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 15. --apply: -Check を付けずに流す。成功なら exit 0
h=$(new_home t15 "${state_on}" "${op_on}" 1)
FAKE_PWSH_RC2=0 FAKE_PWSH_OUT2="揃った" run "${h}" 0 --apply
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && ! called "${h}" -- '-Check' \
  && called "${h}" -F 'C:\fake\Install-OpReason.ps1' && seen "${h}" '揃いました'; then
  ok "--apply は -Check を付けずに流し、成功なら exit 0"
else
  ng "--apply 成功" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 16. --apply が失敗: exit 1 (手で流すものなので失敗を返す)
h=$(new_home t16 "${state_on}" "${op_on}" 1)
FAKE_PWSH_RC2=1 FAKE_PWSH_OUT2="op-reason.exe が動いていて置き場所を入れ替えられない" run "${h}" 0 --apply
if [[ $(rc "${h}") == 1 ]] && seen "${h}" '揃いませんでした'; then
  ok "--apply が失敗したら exit 1"
else
  ng "--apply 失敗" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 17. --apply でも、WSL の op の wrapper を入れないマシンなら pwsh.exe を呼ばずに飛ばす
h=$(new_home t17 "${state_on}" "${op_off}" 1)
run "${h}" 0 --apply
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}"; then
  ok "--apply でも、入れないマシンなら pwsh.exe を呼ばずに飛ばす"
else
  ng "--apply で入れないマシン" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 18. pwsh.exe の出力に色のエスケープが混ざっていても、取り除いてから枠に入れる
h=$(new_home t18 "${state_on}" "${op_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${check_out}" FAKE_PWSH_RC2=1 \
  FAKE_PWSH_OUT2="op-reason (GitHub の Release、${dir})"$'\n\e[33m⚠ 固定した版       : 0.1.0 → 入れ替える (上げる)\e[0m' run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! seen "${h}" $'\e' && seen "${h}" -F '⚠ 固定した版       : 0.1.0 → 入れ替える (上げる)'; then
  ok "pwsh.exe の色のエスケープは取り除いて出す"
else
  ng "エスケープが残る" "rc=$(rc "${h}") $(outerr "${h}" | od -c | head -8)"
fi

# 19. setup から走るとき (DOTFILES_SETUP_WARNINGS がある): 揃えられなければ、⚠ の見出しと揃えるコマンドを
#     まとめ用に残す (pwsh.exe の出力は残さない。その場の ⚠ の枠には出ている)
h=$(new_home t19 "${state_on}" "${op_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${check_out}" FAKE_PWSH_RC2=1 FAKE_PWSH_OUT2="${busy_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(head -n 1 "${h}/warnings" 2>/dev/null) == 'Windows の op-reason を、dotfiles で固定した版に揃えられませんでした (終了コード 1)' ]] \
  && grep -qE '^[[:space:]]+揃えるには.*op の呼び出しが終わってから' "${h}/warnings" \
  && grep -qE '^[[:space:]]+WSL: .*/bootstrap-windows-op-reason\.sh --apply$' "${h}/warnings" \
  && grep -qE '^[[:space:]]+PowerShell: Install-OpReason$' "${h}/warnings" \
  && ! grep -q '入っている版' "${h}/warnings"; then
  ok "setup から走るとき、揃えられなければ ⚠ の見出しと揃えるコマンドをまとめ用に残す"
else
  ng "揃えられないときのまとめ" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null)"
fi

# 20. 入れられなかったときも、⚠ の見出し (終了コードつき) と揃えるコマンドを残す
h=$(new_home t20 "${state_on}" "${op_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=1 \
  FAKE_PWSH_OUT2='落とせなかった: The remote name could not be resolved' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(head -n 1 "${h}/warnings" 2>/dev/null) == 'Windows に op-reason を入れられませんでした (終了コード 1)' ]] \
  && grep -qE '^[[:space:]]+WSL: .*/bootstrap-windows-op-reason\.sh --apply$' "${h}/warnings"; then
  ok "入れられなければ、⚠ の見出しと揃えるコマンドをまとめ用に残す"
else
  ng "入れられないときのまとめ" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null)"
fi

# 21. 揃っている・揃えられた・入れないマシン・配らないマシン (手で入れる 1 行を添えるときも) は、まとめ用には何も残さない
h=$(new_home t21 "${state_on}" "${op_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=0 \
  FAKE_PWSH_OUT2="${applied_out}" run "${h}" 0
h2=$(new_home t21b "${state_on}" "${op_on}" 1)
DOTFILES_SETUP_WARNINGS="${h2}/warnings" FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${synced_out}" run "${h2}" 0
h3=$(new_home t21c "${state_on}" "${op_off}" 1)
DOTFILES_SETUP_WARNINGS="${h3}/warnings" run "${h3}" 0
h4=$(new_home t21d "${state_off}" "${op_on}" 1)
DOTFILES_SETUP_WARNINGS="${h4}/warnings" run "${h4}" 0
if [[ $(rc "${h}") == 0 && ! -s ${h}/warnings && $(rc "${h2}") == 0 && ! -s ${h2}/warnings ]] \
  && [[ $(rc "${h3}") == 0 && ! -s ${h3}/warnings && $(rc "${h4}") == 0 && ! -s ${h4}/warnings ]]; then
  ok "揃っている・揃えられた・入れないマシン・配らないマシンのときは、まとめ用には何も残さない"
else
  ng "警告が無いのにまとめ用に残した" "$(cat "${h}/warnings" "${h2}/warnings" "${h3}/warnings" "${h4}/warnings" 2>/dev/null)"
fi

# 22. pwsh.exe が無いときも、見出しと手で打つコマンドをまとめ用に残す
h=$(new_home t22 "${state_on}" "${op_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}" 1
if [[ $(rc "${h}") == 0 && $(head -n 1 "${h}/warnings" 2>/dev/null) == 'pwsh.exe が見つかりません'* ]] \
  && grep -qE '^[[:space:]]+Install-OpReason -Check$' "${h}/warnings"; then
  ok "pwsh.exe が無ければ、見出しと手で打つコマンドをまとめ用に残す"
else
  ng "pwsh.exe が無いときのまとめ" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null)"
fi

# 23. 知らない引数: exit 2
h=$(new_home t23 "${state_on}" "${op_on}" 1)
run "${h}" 0 --bogus
if [[ $(rc "${h}") == 2 ]] && ! pwsh_called "${h}"; then
  ok "知らない引数は exit 2"
else
  ng "知らない引数" "rc=$(rc "${h}") $(outerr "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
