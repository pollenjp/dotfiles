#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-claude-code.sh の振る舞いを、使い捨ての HOME と偽の pwsh.exe / wslpath で確かめる。
#
#   bash nix/tests/bootstrap-windows-claude-code.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-claude-code-test) が Nix のサンドボックスで流す。
# CI の `nix flake check` もこれを通る。使うのは bash・jq・coreutils・grep・sed だけ。
#
# ## 確かめること
#
#   - 配らないマシン・Claude Code を入れないマシン (windows-files.json の claudeCode が false)・Install-ClaudeCode.ps1 が無いときは
#     pwsh.exe を呼ばずに飛ばす。claudeCode の欄が無い前の世代は、option の既定どおり入れるマシンとして確かめる
#   - pwsh.exe が無い・失敗する・こちらの出力を返さないときは、手で打つコマンドを出して exit 0
#   - -Check が 0 なら 1 行だけ (※ の行は添える)。3 なら -IfMissing で入れ、入れられなければ ⚠ で囲んで知らせる
#   - -Check が 1 で締めの行が「揃える」なら、引数なしで流して揃える。揃わなければ (動いている、など) ⚠ で囲み、
#     出力と揃えるコマンドを出す。締めの行が「※ の手順で直す」だけ (PATH のずれ) なら、揃えずに ⚠ で知らせる
#   - どれも exit 0。--apply は -Check を付けずに流し、失敗なら exit 1。端末でなければ色を付けない
#   - setup から走るとき (DOTFILES_SETUP_WARNINGS がある) は、⚠ の見出しと直し方 (確かめられないときは手で
#     打つコマンド) を setup の最後のまとめ用のファイルにも残す。揃った・入れたときは何も残さない
#
# ## 本物の pwsh.exe を見せない
#
# WSL では PATH に本物の pwsh.exe と wslpath がある。見えると本物の Windows で winget を打ちうるので、
# 要るコマンドだけを symlink で並べた PATH で流す (bootstrap-windows-herdr.test.sh と同じ作り)。
# 偽の pwsh.exe と wslpath の shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-claude-code.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-claude-code-test.XXXXXX")
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

pkg='C:\Users\u\AppData\Local\Microsoft\WinGet\Packages\Anthropic.ClaudeCode_Microsoft.Winget.Source_8wekyb3d8bbwe'
v='2.1.318'

# Install-ClaudeCode.ps1 -Check の出力 (手で入れた新しい版。pin も無い)
drift_out="Claude Code (winget の Anthropic.ClaudeCode、${pkg})
  入っている版    : 2.1.321
⚠ 固定した版      : ${v} → 入れ替える (上げる)
  winget の最新版 : 2.1.321
⚠ winget pin      : 無し → 足す
  PATH の claude  : winget のもの
※ winget に固定した版より新しい 2.1.321 がある。上げるなら Install-ClaudeCode.ps1 の -Version の既定値を変える
⚠️ 固定した版と揃っていない → Install-ClaudeCode で揃える ⚠️"

# Install-ClaudeCode.ps1 -Check の出力 (揃っている。winget に新しい版がある)
synced_out="Claude Code (winget の Anthropic.ClaudeCode、${pkg})
  入っている版    : ${v}
  固定した版      : ${v} → そのまま
  winget の最新版 : 2.1.321
  winget pin      : あり
  PATH の claude  : winget のもの
※ winget に固定した版より新しい 2.1.321 がある。上げるなら Install-ClaudeCode.ps1 の -Version の既定値を変える
揃っている"

# Install-ClaudeCode.ps1 -Check の出力 (入っていない)
missing_out="Claude Code (winget の Anthropic.ClaudeCode、${pkg})
  入っている版    : 入っていない
⚠ 固定した版      : ${v} → 入れる
  winget の最新版 : 2.1.321
⚠ winget pin      : 無し → 足す
  PATH の claude  : 見つからない
⚠️ Claude Code が入っていない → Install-ClaudeCode で入れる ⚠️"

# Install-ClaudeCode.ps1 -Check の出力 (版と pin は揃っていて、PATH で native の installer の claude が先に引かれる)
path_out="Claude Code (winget の Anthropic.ClaudeCode、${pkg})
  入っている版    : ${v}
  固定した版      : ${v} → そのまま
  winget の最新版 : ${v}
  winget pin      : あり
⚠ PATH の claude  : C:\\Users\\u\\.local\\bin\\claude.exe (winget のものではない)
※ PATH のずれは Install-ClaudeCode では直らない。C:\\Users\\u\\.local\\bin の claude.exe を外す (native の installer・claude install・npm で入れたものの外し方は win/README.md の「Claude Code」)
⚠️ PATH の claude が winget のものではない → ※ の手順で直す ⚠️"

# 揃えた・入れた後の出力 (Install-ClaudeCode.ps1 が最後に読み直した表)
done_out="winget download --id Anthropic.ClaudeCode --exact --source winget --version ${v}
winget pin を足した (winget upgrade --all から外れる)

Claude Code (winget の Anthropic.ClaudeCode、${pkg})
  入っている版    : ${v}
  固定した版      : ${v} → そのまま
  winget の最新版 : 2.1.321
  winget pin      : あり
  PATH の claude  : winget のもの
揃った"

# 入れ替えが要るのに claude.exe が動いていて止まったときの出力
busy_out="Claude Code (winget の Anthropic.ClaudeCode、${pkg})
  入っている版    : 2.1.321
⚠ 固定した版      : ${v} → 入れ替える (上げる)
※ claude.exe が 1 個動いている。入れ替えるには、Windows で開いている Claude Code の会話を閉じる (WSL の claude は別のもの)
claude.exe が動いていて置き換えられない。Windows で開いている Claude Code の会話を閉じてから打ち直す:
  1001  claude.exe --dangerously-skip-permissions"

# 揃えた後も PATH のずれが残ったときの出力
after_path_out="Claude Code (winget の Anthropic.ClaudeCode、${pkg})
  入っている版    : ${v}
  固定した版      : ${v} → そのまま
  winget pin      : あり
⚠ PATH の claude  : C:\\Users\\u\\.local\\bin\\claude.exe (winget のものではない)
版と pin は揃った
⚠️ PATH の claude が winget のものではない → ※ の手順で直す ⚠️"

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
#   $3: 1 なら Install-ClaudeCode.ps1 を配った状態にする
# 配り先 (Windows のホームに見立てる) は <HOME>/win。
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.local/state/dotfiles" "${h}/bin" "${h}/win"
  if [[ -n $2 ]]; then
    printf '%s\n' "${2//@WIN@/${h}/win}" >"${h}/.local/state/dotfiles/windows-files.json"
  fi
  if [[ $3 == 1 ]]; then
    mkdir -p "${h}/win/.config/powershell"
    printf '# Install-ClaudeCode.ps1\n' >"${h}/win/.config/powershell/Install-ClaudeCode.ps1"
  fi
  # 偽の pwsh.exe。引数を記録し、出力を行ごとに CRLF で出して終わる。呼び方で出すものを変える:
  #   -IfMissing            FAKE_PWSH_OUT2 / FAKE_PWSH_RC2
  #   -Check                FAKE_PWSH_OUT / FAKE_PWSH_RC
  #   引数なし (揃える)      FAKE_PWSH_OUT3 / FAKE_PWSH_RC3
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/pwsh-calls"
case "$*" in
  *-IfMissing*)
    out=${FAKE_PWSH_OUT2-}
    rc=${FAKE_PWSH_RC2:-0}
    ;;
  *-Check*)
    out=${FAKE_PWSH_OUT-}
    rc=${FAKE_PWSH_RC:-0}
    ;;
  *)
    out=${FAKE_PWSH_OUT3-}
    rc=${FAKE_PWSH_RC3:-0}
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
ncalls() { calls "$1" | grep -c ''; }
warn_lines() { outerr "$1" | grep -c '⚠️'; }

state_on='{"claudeCode":true,"enable":true,"ntn":true,"typeClipboard":false,"version":1,"windowsHome":"@WIN@"}'
state_cc_off='{"claudeCode":false,"enable":true,"ntn":true,"typeClipboard":false,"version":1,"windowsHome":"@WIN@"}'
state_cc_absent='{"enable":true,"ntn":true,"typeClipboard":false,"version":1,"windowsHome":"@WIN@"}'
state_off='{"claudeCode":false,"enable":false,"ntn":false,"typeClipboard":false,"version":1,"windowsHome":null}'

echo "== bootstrap-windows-claude-code.sh: ${script}"

# 1. 状態ファイルが無い・enable = false・claudeCode = false・ps1 が無い: pwsh.exe を呼ばずに飛ばす
h=$(new_home t1 "" 1)
run "${h}" 0
h2=$(new_home t1b "${state_off}" 1)
run "${h2}" 0
h3=$(new_home t1c "${state_cc_off}" 1)
run "${h3}" 0
h4=$(new_home t1d "${state_on}" 0)
run "${h4}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" '飛ばします' \
  && [[ $(rc "${h2}") == 0 ]] && ! pwsh_called "${h2}" && seen "${h2}" '配りません' \
  && [[ $(rc "${h3}") == 0 ]] && ! pwsh_called "${h3}" && seen "${h3}" -F 'dotfiles.wsl.windowsFiles.claudeCode.enable = false' \
  && [[ $(rc "${h4}") == 0 ]] && ! pwsh_called "${h4}" && seen "${h4}" 'まだ配られていません'; then
  ok "状態ファイルが無い・配らない・claudeCode = false・Install-ClaudeCode.ps1 が無いときは、pwsh.exe を呼ばずに飛ばす"
else
  ng "飛ばすとき" "$(outerr "${h}") / $(outerr "${h2}") / $(outerr "${h3}") / $(outerr "${h4}")"
fi

# 2. claudeCode の欄が無い (option を足す前の世代): option の既定どおり入れるマシンとして確かめる
h=$(new_home t2 "${state_cc_absent}" 1)
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${synced_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && called "${h}" -- '-Check' && seen "${h}" '揃っています'; then
  ok "claudeCode の欄が無ければ (前の世代)、入れるマシンとして確かめる (jq の // で false を true に化けさせない)"
else
  ng "claudeCode の欄が無い" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 3. pwsh.exe が無い・失敗する・こちらの出力が来ない: 手で打つコマンドを出して exit 0 (まとめにも残す)
h=$(new_home t3 "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}" 1
h2=$(new_home t3b "${state_on}" 1)
FAKE_PWSH_RC=126 FAKE_PWSH_OUT='' run "${h2}" 0
h3=$(new_home t3c "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT='The term is not recognized as a name of a cmdlet' run "${h3}" 0
if [[ $(rc "${h}") == 0 ]] && seen "${h}" -F 'Install-ClaudeCode -Check' \
  && [[ $(head -n 1 "${h}/warnings" 2>/dev/null) == 'pwsh.exe が見つかりません'* ]] \
  && grep -qE '^[[:space:]]+Install-ClaudeCode -Check$' "${h}/warnings" \
  && [[ $(rc "${h2}") == 0 ]] && seen "${h2}" '確かめられませんでした' \
  && [[ $(rc "${h3}") == 0 && $(warn_lines "${h3}") == 0 && $(ncalls "${h3}") == 1 ]] && seen "${h3}" '確かめられませんでした'; then
  ok "pwsh.exe が無い・失敗する・出力が来ないときは、手で打つコマンドを出して exit 0 (まとめにも残す)"
else
  ng "確かめられない" "$(outerr "${h}") / $(outerr "${h2}") / $(outerr "${h3}")"
fi

# 4. 揃っている (-Check が 0): 1 行と ※ の行だけで ⚠ は出さない。pwsh.exe は -NoProfile と -Check で、配った場所を渡す
h=$(new_home t4 "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${synced_out}" run "${h}" 0
# shellcheck disable=SC2016 # PowerShell の $global:… を文字のまま探す
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 && $(ncalls "${h}") == 1 ]] && seen "${h}" '揃っています' \
  && seen "${h}" -F '  ※ winget に固定した版より新しい 2.1.321 がある' \
  && called "${h}" -- '-NoProfile' && called "${h}" -- '-Check' && called "${h}" -F 'C:\fake\Install-ClaudeCode.ps1' \
  && called "${h}" -F '$global:LASTEXITCODE = 2; &' && [[ ! -s ${h}/warnings ]]; then
  ok "揃っていれば 1 行と ※ の行だけ出して exit 0 (まとめには残さない)"
else
  ng "揃っている" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 5. 入っていない (-Check が 3): -IfMissing で入れる。入ったら ⚠ は出さず、まとめにも残さない
h=$(new_home t5 "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=0 FAKE_PWSH_OUT2="${done_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 && $(ncalls "${h}") == 2 ]] && seen "${h}" '入れました' \
  && called_last "${h}" -- '-IfMissing' && [[ ! -s ${h}/warnings ]]; then
  ok "入っていなければ -IfMissing で入れて exit 0"
else
  ng "入っていない → 入れる" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 6. 入れようとしたが失敗: ⚠ で囲み、出力と揃えるコマンドを出し、まとめに見出し (終了コードつき) を残す
h=$(new_home t6 "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=1 \
  FAKE_PWSH_OUT2="winget が失敗した (終了コード 0x8A15000F)"$'\n'"${missing_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 ]] && seen "${h}" '入れられませんでした' \
  && seen "${h}" -F '0x8A15000F' && seen "${h}" -F -- 'bootstrap-windows-claude-code.sh --apply' \
  && [[ $(head -n 1 "${h}/warnings" 2>/dev/null) == 'Windows の Claude Code を入れられませんでした (終了コード 1)' ]] \
  && grep -qE '^[[:space:]]+PowerShell: Install-ClaudeCode$' "${h}/warnings"; then
  ok "入れられなければ ⚠ で囲んで知らせて exit 0 (まとめに見出しと揃えるコマンド)"
else
  ng "入れられない" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null) $(outerr "${h}")"
fi

# 7. 版と pin がずれている (-Check が 1、締めの行が「揃える」): 引数なしで流して揃える (版を上げる)
h=$(new_home t7 "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${drift_out}" FAKE_PWSH_RC3=0 FAKE_PWSH_OUT3="${done_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 && $(ncalls "${h}") == 2 ]] && seen "${h}" '揃えました' \
  && ! called_last "${h}" -- '-Check' && ! called_last "${h}" -- '-IfMissing' && called_last "${h}" -F 'C:\fake\Install-ClaudeCode.ps1' \
  && [[ ! -s ${h}/warnings ]]; then
  ok "版か pin がずれていれば、引数なしで流して揃え、⚠ は出さない"
else
  ng "ずれ → 揃える" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 8. 揃えようとしたが claude.exe が動いていて止まった: ⚠ で囲み、動いているプロセスと揃えるコマンドを出す
h=$(new_home t8 "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${drift_out}" FAKE_PWSH_RC3=1 FAKE_PWSH_OUT3="${busy_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 ]] && seen "${h}" '揃えられませんでした' \
  && seen "${h}" -F '1001  claude.exe --dangerously' && seen "${h}" -F 'Claude Code の会話を先に閉じる' \
  && [[ $(head -n 1 "${h}/warnings" 2>/dev/null) == 'Windows の Claude Code を揃えられませんでした (終了コード 1)' ]] \
  && grep -qE '^[[:space:]]+WSL: .*/bootstrap-windows-claude-code\.sh --apply$' "${h}/warnings" \
  && ! grep -q '入っている版' "${h}/warnings"; then
  ok "動いていて揃わなければ ⚠ で囲んで知らせ、まとめには見出しと揃えるコマンドだけを残す"
else
  ng "動いていて揃わない" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null) $(outerr "${h}")"
fi
if ! seen "${h}" -F '揃っていない → Install-ClaudeCode' && ! seen "${h}" $'\e\[' && ! seen "${h}" $'\r'; then
  ok "締めの行は枠の直し方と重なるので出さず、色と CR も落とす"
else
  ng "締めの行・色・CR が残る" "$(outerr "${h}" | od -c | head -8)"
fi

# 9. PATH のずれだけ (-Check が 1、締めの行が「※ の手順で直す」): 揃えずに ⚠ で知らせる
h=$(new_home t9 "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${path_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 && $(ncalls "${h}") == 1 ]] \
  && seen "${h}" -F 'C:\Users\u\.local\bin の claude.exe を外す' && seen "${h}" -F '揃える手順では直らない' \
  && ! seen "${h}" -F -- 'bootstrap-windows-claude-code.sh --apply' \
  && [[ $(head -n 1 "${h}/warnings" 2>/dev/null) == *'winget のものではありません' ]]; then
  ok "PATH のずれだけなら揃えずに ⚠ で知らせ、揃えるコマンドは出さない"
else
  ng "PATH のずれだけ" "rc=$(rc "${h}") calls=$(calls "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null) $(outerr "${h}")"
fi

# 10. 揃えた後も PATH のずれが残った: 版と pin は揃ったと言い、PATH の直し方だけを出す
h=$(new_home t10 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${drift_out}" FAKE_PWSH_RC3=1 FAKE_PWSH_OUT3="${after_path_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 2 ]] && seen "${h}" '版と pin は揃いました' \
  && seen "${h}" -F '揃える手順では直らない' && ! seen "${h}" '揃えられませんでした'; then
  ok "揃えた後に PATH のずれだけが残れば、版と pin は揃ったと言い、PATH の直し方を出す"
else
  ng "揃えた後の PATH のずれ" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 11. -Check が 3 でも、こちらの出力が無い: 入れには行かず、手で打つコマンドを出す
h=$(new_home t11 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT='Exec format error' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && seen "${h}" '確かめられませんでした'; then
  ok "-Check が 3 でも出力が来なければ、入れずに手で打つコマンドを出す"
else
  ng "3 だが出力が来ない" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 12. --apply: -Check も -IfMissing も付けずに 1 回流す。成功なら exit 0、失敗なら exit 1。入れないマシンなら飛ばす
h=$(new_home t12 "${state_on}" 1)
FAKE_PWSH_RC3=0 FAKE_PWSH_OUT3='揃った' run "${h}" 0 --apply
h2=$(new_home t12b "${state_on}" 1)
FAKE_PWSH_RC3=1 FAKE_PWSH_OUT3="${busy_out}" run "${h2}" 0 --apply
h3=$(new_home t12c "${state_cc_off}" 1)
run "${h3}" 0 --apply
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && ! called "${h}" -- '-Check' && ! called "${h}" -- '-IfMissing' \
  && seen "${h}" '揃いました' && [[ $(rc "${h2}") == 1 ]] && seen "${h2}" '揃いませんでした' \
  && [[ $(rc "${h3}") == 0 ]] && ! pwsh_called "${h3}"; then
  ok "--apply は -Check を付けずに 1 回流し、成功なら 0・失敗なら 1。入れないマシンなら飛ばす"
else
  ng "--apply" "rc=$(rc "${h}")/$(rc "${h2}")/$(rc "${h3}") $(outerr "${h}") / $(outerr "${h2}")"
fi

# 13. 知らない引数: exit 2
h=$(new_home t13 "${state_on}" 1)
run "${h}" 0 --bogus
if [[ $(rc "${h}") == 2 ]] && ! pwsh_called "${h}"; then
  ok "知らない引数は exit 2"
else
  ng "知らない引数" "rc=$(rc "${h}") $(outerr "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
