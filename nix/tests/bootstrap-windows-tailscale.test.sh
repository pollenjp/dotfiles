#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-tailscale.sh の振る舞いを、使い捨ての HOME と
# 偽の pwsh.exe / wslpath で確かめる。
#
#   bash nix/tests/bootstrap-windows-tailscale.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-tailscale-test) が Nix のサンドボックスで流す。
# CI の `nix flake check` もこれを通る。使うのは bash・jq・coreutils・grep・sed だけ。
#
# ## 確かめること
#
#   - 配らないマシン・Tailscale を入れないマシン (group.json の tools.windowsTailscale が false・欄が無い・group.json が無い)・
#     Install-Tailscale.ps1 が無いときは pwsh.exe を呼ばずに飛ばす (入れないときは option の名前を出す)。--apply でも同じ
#   - script の冒頭に setup が読む `# tool: windowsTailscale (dotfiles.wsl.windowsFiles.tailscale.enable)` と `# order: 96` がある
#   - pwsh.exe が無い・失敗する・こちらの出力を返さないときは、手で打つコマンドを出して exit 0
#     (-Check が時間切れ (124) のときは、時間切れと出す)
#   - -Check が 0 なら 1 行 (※ の補足があれば添える。入っている版の方が新しいときも ⚠ にせず ※ だけ)。1 なら ⚠ で囲んだ注意・
#     状態・揃えるコマンドを出す (上げはしない)。固定した版が winget に無いときは repo の版の直し方、入っている版が読めない
#     ときは確かめ方を出す。新しい版で pin だけが無いときは、揃えるコマンド (pin を足す) を出す
#   - -Check が 3 (入っていない) なら、UAC の確認が出ると先に出してから -IfMissing で入れる。入ったら、tailnet への
#     ログインは手でするよう出す。入れられない・時間切れなら ⚠ で囲んで知らせる (時間切れなら、UAC の確認が残っている
#     ときの打ち直し方も)。ただし固定した版が winget に無いときは、-IfMissing を打たず、UAC の案内も出さずに repo の版の
#     直し方を出す
#   - 偽の timeout が上限の秒数を記録し、-Check は 120 秒・-IfMissing は 600 秒で打つこと、UAC の案内が
#     -IfMissing を打つより前に出ることを確かめる
#   - どれも exit 0。--apply は -Check を付けずに流し、失敗なら exit 1。端末でなければ色を付けない
#   - script に実行ビットがある (setup.sh は -x でない bootstrap を流さずに止まる)
#   - jq が無くても exit 0 (知らない引数の 2 以外で 0 以外を返さない)
#   - setup から走るとき (DOTFILES_SETUP_WARNINGS がある) は、⚠ の見出しと、枠に出したのと同じ直し方
#     (確かめられないときは手で打つコマンド) を setup の最後のまとめ用のファイルにも残す
#
# ## 本物の pwsh.exe を見せない
#
# WSL では PATH に本物の pwsh.exe と wslpath がある。見えると本物の Windows で winget を
# 呼びうるので、要るコマンドだけを symlink で並べた PATH で流す (bootstrap-windows-google-ime-install.test.sh
# と同じ作り)。偽の pwsh.exe と wslpath の shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-tailscale.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-tailscale-test.XXXXXX")
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

v='1.104.5'

# Install-Tailscale.ps1 -Check の出力 (古い版が入っていて pin が無い)
older_out="Tailscale (winget の Tailscale.Tailscale)
  入っている版    : 1.98.10 (C:\\Program Files\\Tailscale)
⚠ 固定した版      : ${v} → 上げる
  winget の最新版 : ${v}
⚠ winget pin      : 無し → 足す
⚠️ 固定した版より古い → Install-Tailscale で揃える (UAC の確認が出る。上げる間、Tailscale の接続が少しの間切れる) ⚠️"

# Install-Tailscale.ps1 -Check の出力 (揃っている)
synced_out="Tailscale (winget の Tailscale.Tailscale)
  入っている版    : ${v} (C:\\Program Files\\Tailscale)
  固定した版      : ${v} → そのまま
  winget の最新版 : ${v}
  winget pin      : あり
揃っている"

# Install-Tailscale.ps1 -Check の出力 (入っている版の方が新しい。Tailscale の自動更新で上がった。pin はある)
newer_note='※ 入っている版の方が新しい (Tailscale の自動更新で上がった?)。下げない。固定した版は、新しく入れるときの版 (自動更新の切り替えは Tailscale のタスクトレイの Preferences → Automatically install updates)'
newer_out="Tailscale (winget の Tailscale.Tailscale)
  入っている版    : 1.106.2 (C:\\Program Files\\Tailscale)
  固定した版      : ${v} → 入っている版の方が新しい (下げない)
  winget の最新版 : 1.106.2
  winget pin      : あり
※ winget に固定した版より新しい 1.106.2 がある。上げるなら Install-Tailscale.ps1 の -Version の既定値を変える (入っている Tailscale は、自動更新が有効なら自分で上がる)
${newer_note}
揃っている (入っている版の方が新しい。下げない)"

# Install-Tailscale.ps1 -Check の出力 (入っている版の方が新しいが、pin が無い)
newer_nopin_out="Tailscale (winget の Tailscale.Tailscale)
  入っている版    : 1.106.2 (C:\\Program Files\\Tailscale)
  固定した版      : ${v} → 入っている版の方が新しい (下げない)
  winget の最新版 : 1.106.2
⚠ winget pin      : 無し → 足す
${newer_note}
⚠️ winget pin が無い → Install-Tailscale で足す (UAC の確認は出ない) ⚠️"

# Install-Tailscale.ps1 -Check の出力 (入っている版が読めない)
unknown_out="Tailscale (winget の Tailscale.Tailscale)
  入っている版    : 不明 (tailscale.exe version が読めない。C:\\Program Files\\Tailscale)
⚠ 固定した版      : ${v} → 比べられない
  winget の最新版 : ${v}
  winget pin      : あり
※ 版が読めないので比べられない。winget list --id Tailscale.Tailscale で入っている版を確かめる
⚠️ 入っている版が読めない → winget list --id Tailscale.Tailscale で入っている版を確かめる ⚠️"

# Install-Tailscale.ps1 -Check の出力 (上げたいが、固定した版が winget に無い)
notlisted_out="Tailscale (winget の Tailscale.Tailscale)
  入っている版    : 1.98.10 (C:\\Program Files\\Tailscale)
⚠ 固定した版      : ${v} → 上げる
  winget の最新版 : 1.106.2
⚠ winget pin      : 無し → 足す
⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない
⚠️ 固定した版 ${v} が winget に無い → Install-Tailscale.ps1 の -Version を winget show --id Tailscale.Tailscale --versions にある版へ変える ⚠️"

# Install-Tailscale.ps1 -Check の出力 (入っていないが、固定した版が winget に無い)
missing_notlisted_out="Tailscale (winget の Tailscale.Tailscale)
  入っている版    : 入っていない
⚠ 固定した版      : ${v} → 入れる
  winget の最新版 : 1.106.2
⚠ winget pin      : 無し → 足す
⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない
⚠️ 固定した版 ${v} が winget に無い → Install-Tailscale.ps1 の -Version を winget show --id Tailscale.Tailscale --versions にある版へ変える ⚠️"

# Install-Tailscale.ps1 -Check の出力 (入っていない)
missing_out="Tailscale (winget の Tailscale.Tailscale)
  入っている版    : 入っていない
⚠ 固定した版      : ${v} → 入れる
  winget の最新版 : ${v}
⚠ winget pin      : 無し → 足す
⚠️ Tailscale が入っていない → Install-Tailscale で入れる (UAC の確認が出る) ⚠️"

# Install-Tailscale.ps1 -IfMissing が入れ終えたときの出力 (本物と同じく、入れる前の表から始まる)
installed_out="${missing_out%$'\n'*}
Windows のデスクトップに UAC の確認が出る。「はい」を押す (進み具合の小さな窓も出る)
winget install --id Tailscale.Tailscale --exact --source winget --version ${v} --installer-type wix --accept-source-agreements --accept-package-agreements --disable-interactivity
  Successfully installed
winget pin を足した (winget upgrade --all から外れる。Tailscale の自動更新は止めない)

${synced_out%揃っている}tailnet へのログインは手でする (タスクトレイの Tailscale のアイコンから Log in。dotfiles はログインに触らない)
揃った"

# 要るコマンドだけを並べた PATH (pwsh.exe と wslpath は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env jq grep sed tr cat head tail od mkdir mktemp mv rm dirname basename chmod timeout cut; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# 1 ケースぶんの HOME を作る。
#   $1: 名前、$2: windows-files.json の中身 (空なら作らない。@WIN@ は配り先に置き換える)
#   $3: 1 なら Install-Tailscale.ps1 を配った状態にする
#   $4: group.json の中身 (省けば Tailscale を入れるホスト。none なら作らない)
# 配り先 (Windows のホームに見立てる) は <HOME>/win。
new_home() {
  local h="${work}/$1" group=${4-${group_on}}
  mkdir -p "${h}/.local/state/dotfiles" "${h}/bin" "${h}/win"
  if [[ -n $2 ]]; then
    printf '%s\n' "${2//@WIN@/${h}/win}" >"${h}/.local/state/dotfiles/windows-files.json"
  fi
  if [[ ${group} != none ]]; then
    printf '%s\n' "${group}" >"${h}/.local/state/dotfiles/group.json"
  fi
  if [[ $3 == 1 ]]; then
    mkdir -p "${h}/win/.config/powershell"
    printf '# Install-Tailscale.ps1\n' >"${h}/win/.config/powershell/Install-Tailscale.ps1"
  fi
  # 偽の pwsh.exe。引数を記録し、出力を行ごとに CRLF で出して終わる。
  # -IfMissing の呼び出しは FAKE_PWSH_OUT2 / FAKE_PWSH_RC2、ほかは FAKE_PWSH_OUT / FAKE_PWSH_RC を使う
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/pwsh-calls"
case "$*" in
  *-IfMissing*)
    cat "${HOME}/out" >"${HOME}/out-at-ifmissing"
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
  # 偽の timeout。上限 (秒) を記録して、残りをそのまま流す
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$1" >>"${HOME}/timeout-calls"
shift
exec "$@"
EOF
  } >"${h}/bin/timeout"
  chmod +x "${h}/bin/timeout"
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
# 判定の grep -q はパイプで受けず、ファイルを直に読む (pipefail の下で、grep が先に抜けると cat が SIGPIPE で終わる。
# check-test-grep-q.sh が CI の lint で落とす)。$1: ケースのディレクトリ、残り: grep の引数
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

state_on='{"enable":true,"version":1,"windowsHome":"@WIN@"}'
state_off='{"enable":false,"version":1,"windowsHome":null}'
group_on='{"group":"all","tools":{"windowsTailscale":true},"version":2}'
group_off='{"group":"all","tools":{"windowsTailscale":false},"version":2}'
# 道具を足す前の世代の group.json (windowsTailscale の欄が無い)
group_absent='{"group":"all","tools":{"claude":true},"version":2}'

echo "== bootstrap-windows-tailscale.sh: ${script}"

# 0. setup が読む冒頭の見出し (# order: と # tool:)
head40=$(head -n 40 "${script}")
if grep -qxF '# order: 96' <<<"${head40}" \
  && grep -qxF '# tool: windowsTailscale (dotfiles.wsl.windowsFiles.tailscale.enable)' <<<"${head40}"; then
  ok "冒頭 40 行に # order: 96 と # tool: windowsTailscale (dotfiles.wsl.windowsFiles.tailscale.enable) がある"
else
  ng "冒頭の見出し" "${head40}"
fi

# 1. 状態ファイルが無い: 飛ばす
h=$(new_home t1 "" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" '飛ばします'; then
  ok "windows-files.json が無ければ pwsh.exe を呼ばずに飛ばす"
else
  ng "状態ファイルが無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 2. enable = false: 飛ばす
h=$(new_home t2 "${state_off}" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" '配りません'; then
  ok "enable = false なら pwsh.exe を呼ばずに飛ばす"
else
  ng "enable = false" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 3. Tailscale を入れないマシン (tools.windowsTailscale が false・欄が無い・group.json が無い): option の名前を出して飛ばす
for c in off absent none; do
  case ${c} in
    off) g=${group_off} ;;
    absent) g=${group_absent} ;;
    none) g=none ;;
  esac
  h=$(new_home "t3-${c}" "${state_on}" 1 "${g}")
  run "${h}" 0
  if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" -F 'dotfiles.wsl.windowsFiles.tailscale.enable = false'; then
    ok "Tailscale を入れないマシン (${c}) なら pwsh.exe を呼ばずに飛ばす (option の名前を出す)"
  else
    ng "Tailscale を入れないマシン (${c})" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
done

# 3b. --apply でも、入れないマシンなら飛ばす (手で流しても、switch を off にしたマシンには入れない)
h=$(new_home t3b "${state_on}" 1 "${group_off}")
run "${h}" 0 --apply
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" -F 'dotfiles.wsl.windowsFiles.tailscale.enable = false'; then
  ok "--apply でも、Tailscale を入れないマシンなら pwsh.exe を呼ばずに飛ばす"
else
  ng "--apply と入れないマシン" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 4. Install-Tailscale.ps1 が配られていない: 飛ばす
h=$(new_home t4 "${state_on}" 0)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" 'まだ配られていません'; then
  ok "Install-Tailscale.ps1 が配られていなければ飛ばす"
else
  ng "Install-Tailscale.ps1 が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 5. pwsh.exe が無い: 手で打つコマンドを出して exit 0
h=$(new_home t5 "${state_on}" 1)
run "${h}" 1
if [[ $(rc "${h}") == 0 ]] && seen "${h}" -F 'Install-Tailscale -Check'; then
  ok "pwsh.exe が無ければ手で打つコマンドを出して exit 0"
else
  ng "pwsh.exe が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 6. pwsh.exe が失敗する (interop が落ちている): 手で打つコマンドを出して exit 0
h=$(new_home t6 "${state_on}" 1)
FAKE_PWSH_RC=126 FAKE_PWSH_OUT='' run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && seen "${h}" -F 'Install-Tailscale -Check' && seen "${h}" '確かめられませんでした'; then
  ok "pwsh.exe が失敗したら手で打つコマンドを出して exit 0"
else
  ng "pwsh.exe が失敗する" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 7. 揃っている (-Check が 0): 1 行だけで ⚠ は出さない。pwsh.exe は -NoProfile と -Check で、配った場所を渡す
h=$(new_home t7 "${state_on}" 1)
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${synced_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 ]] && seen "${h}" -F 'Windows の Tailscale は、dotfiles で固定した版以上で入っています。' \
  && called "${h}" -- '-NoProfile' && called "${h}" -- '-Check' \
  && called "${h}" -F 'C:\fake\Install-Tailscale.ps1' \
  && [[ $(cat "${h}/timeout-calls") == 120 ]]; then
  ok "揃っていれば 1 行だけ出して exit 0 (pwsh.exe は -NoProfile -Check、配った場所を渡す)"
else
  ng "揃っている" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 7b. スクリプトが exit まで届かずに終わっても成功扱いにしない: 呼ぶ前に $LASTEXITCODE を 2 にしておく
# shellcheck disable=SC2016 # PowerShell の $global:… を文字のまま探す
if called "${h}" -F '$global:LASTEXITCODE = 2; &'; then
  ok "pwsh.exe には、スクリプトを呼ぶ前に \$LASTEXITCODE を 2 にするコマンドを渡す"
else
  ng "\$LASTEXITCODE を先に 2 にしていない" "calls=$(calls "${h}")"
fi

# 8. 入っている版の方が新しい (-Check が 0。Tailscale の自動更新で上がった): ⚠ にせず、1 行と ※ の行だけを出す
h=$(new_home t8 "${state_on}" 1)
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${newer_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 && $(ncalls "${h}") == 1 ]] \
  && seen "${h}" -F 'Windows の Tailscale は、dotfiles で固定した版以上で入っています。' \
  && seen "${h}" -F "${newer_note}" && ! seen "${h}" -F -- '--apply'; then
  ok "入っている版の方が新しければ ⚠ にせず、1 行と ※ の行 (自動更新のこと) だけを出す"
else
  ng "入っている版の方が新しい" "rc=$(rc "${h}") warn_lines=$(warn_lines "${h}") $(outerr "${h}")"
fi

# 9. 古い (-Check が 1): ⚠ で上下を囲み、状態と揃えるコマンドを出す。上げはしない
h=$(new_home t9 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${older_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 ]] && seen "${h}" '揃っていません' \
  && seen "${h}" -F "⚠ 固定した版      : ${v} → 上げる" && seen "${h}" -F '1.98.10' \
  && seen "${h}" -F -- 'bootstrap-windows-tailscale.sh --apply' \
  && seen "${h}" -F 'PowerShell: Install-Tailscale' && seen "${h}" -F 'UAC' && seen "${h}" -F '接続が少しの間切れる' \
  && [[ $(ncalls "${h}") == 1 ]]; then
  ok "古ければ ⚠ で囲んだ注意と状態と揃えるコマンドを出して exit 0 (上げはしない)"
else
  ng "古い" "rc=$(rc "${h}") warn_lines=$(warn_lines "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi
if ! seen "${h}" -F '古い → Install-Tailscale'; then
  ok "PowerShell の締めの 1 行は、枠の揃えるコマンドと重なるので出さない"
else
  ng "締めの 1 行が重なっている" "$(outerr "${h}")"
fi
if ! seen "${h}" $'\e\['; then
  ok "端末でなければ色 (エスケープ) を付けない"
else
  ng "端末でないのに色が付いている" "$(outerr "${h}" | od -c | head -5)"
fi
if ! seen "${h}" $'\r'; then
  ok "pwsh.exe の CRLF は落として出す"
else
  ng "CR が残っている" "$(outerr "${h}" | od -c | head -5)"
fi

# 9b. 入っている版の方が新しいが pin が無い (-Check が 1): 下げるとは言わず、揃えるコマンド (pin を足す) を出す
h=$(new_home t9b "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${newer_nopin_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 && $(ncalls "${h}") == 1 ]] \
  && seen "${h}" -F 'PowerShell: Install-Tailscale' && seen "${h}" -F 'pin を足すだけなら UAC は出ない' \
  && ! seen "${h}" '下げはしません'; then
  ok "新しい版で pin だけが無ければ、揃えるコマンド (pin を足す) を出す"
else
  ng "新しい版で pin が無い" "rc=$(rc "${h}") warn_lines=$(warn_lines "${h}") $(outerr "${h}")"
fi

# 10. 固定した版が winget に無い (-Check が 1): 枠に入れるが、揃えるコマンドではなく repo の版の直し方を出す
h=$(new_home t10 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${notlisted_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 && $(ncalls "${h}") == 1 ]] && seen "${h}" 'winget に無いので、入れることも上げることもできません' \
  && seen "${h}" -F 'winget show --id Tailscale.Tailscale --versions' && ! seen "${h}" -F -- '--apply'; then
  ok "固定した版が winget に無ければ、揃えるコマンドの代わりに repo の版の直し方を出す"
else
  ng "固定した版が winget に無い" "rc=$(rc "${h}") warn_lines=$(warn_lines "${h}") $(outerr "${h}")"
fi

# 11. 入っている版が読めない (-Check が 1): 枠に入れるが、揃えるコマンドではなく確かめ方を出す
h=$(new_home t11 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${unknown_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 && $(ncalls "${h}") == 1 ]] && seen "${h}" '入っている版が読めないので、揃えられません' \
  && seen "${h}" -F 'winget list --id Tailscale.Tailscale' && ! seen "${h}" -F -- '--apply'; then
  ok "入っている版が読めなければ、揃えるコマンドの代わりに確かめ方を出す"
else
  ng "入っている版が読めない" "rc=$(rc "${h}") warn_lines=$(warn_lines "${h}") $(outerr "${h}")"
fi

# 12. -Check が 1 でも、こちらの出力が無い (スクリプトが壊れている等): 差とは扱わず、手で打つコマンドを出す
h=$(new_home t12 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT='The term is not recognized as a name of a cmdlet' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 ]] && seen "${h}" '確かめられませんでした' \
  && seen "${h}" -F 'Install-Tailscale -Check'; then
  ok "-Check の出力が来なければ差とは扱わず、手で打つコマンドを出して exit 0"
else
  ng "出力が来ない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 13. 入っていない (-Check が 3): UAC の確認が出ると先に出してから -IfMissing で入れる。入ったら ⚠ は出さず、
#     tailnet へのログインは手でするよう出す (ps1 が出す 1 行をそのまま見せ、重ねて出さない)
h=$(new_home t13 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=0 FAKE_PWSH_OUT2="${installed_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 && $(ncalls "${h}") == 2 ]] && seen "${h}" 'UAC の確認が出たら' \
  && grep -q 'UAC の確認が出たら' "${h}/out-at-ifmissing" && [[ $(tr '\n' ' ' <"${h}/timeout-calls") == "120 600 " ]] \
  && seen "${h}" 'Windows に Tailscale を入れました' && [[ $(outerr "${h}" | grep -c 'tailnet へのログインは手で') == 1 ]] \
  && called_last "${h}" -- '-IfMissing' && ! called_last "${h}" -- '-Check'; then
  ok "入っていなければ UAC が出ると出してから -IfMissing で入れ、ログインは手でするよう 1 回だけ出して exit 0"
else
  ng "入っていない → 入れる" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 14. 入っていないので入れようとしたが失敗 (UAC で断った など): ⚠ で囲んで知らせる。setup は止めない
h=$(new_home t14 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=1 FAKE_PWSH_OUT2='winget が失敗した (終了コード 0x8A150011)。UAC で「いいえ」を押したなら、Install-Tailscale を打ち直す' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 ]] && seen "${h}" '入れられませんでした (終了コード 1)' \
  && seen "${h}" -F '0x8A150011' && seen "${h}" -F -- 'bootstrap-windows-tailscale.sh --apply'; then
  ok "入れられなければ ⚠ で囲んで知らせて exit 0"
else
  ng "入れられない" "rc=$(rc "${h}") warn_lines=$(warn_lines "${h}") $(outerr "${h}")"
fi

# 15. UAC を押さないまま 600 秒たった (timeout の 124): 時間切れと出して ⚠ で囲む。UAC の確認が残っていれば
#     先に押すか閉じてから打ち直すよう添える (残ったまま打ち直すと 1618 で落ちる)。setup は止めない
h=$(new_home t15 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=124 FAKE_PWSH_OUT2='' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 ]] && seen "${h}" '600 秒待っても終わらない' \
  && seen "${h}" -F 'PowerShell: Install-Tailscale' \
  && grep -qF 'UAC の確認が残っていれば、先に押すか閉じてから打ち直して' "${h}/err" && grep -qF '(1618)' "${h}/err"; then
  ok "UAC を押さないまま時間切れになったら ⚠ で囲んで知らせ、確認が残っているときの打ち直し方も添えて exit 0"
else
  ng "時間切れ" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 16. -Check が 3 でも、こちらの出力が無い: 入れには行かず、手で打つコマンドを出す
h=$(new_home t16 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT='Exec format error' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && seen "${h}" '確かめられませんでした' \
  && seen "${h}" -F 'Install-Tailscale -Check'; then
  ok "-Check が 3 でも出力が来なければ、入れずに手で打つコマンドを出す"
else
  ng "3 だが出力が来ない" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 16b. 入っていないが、固定した版が winget に無い (-Check が 3): -IfMissing は打たず、UAC の案内も出さずに、repo の版の直し方を出す
h=$(new_home t16b "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_notlisted_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 && $(ncalls "${h}") == 1 ]] && seen "${h}" 'winget に無いので、入れることも上げることもできません' \
  && ! seen "${h}" 'UAC の確認が出たら' && ! seen "${h}" -F -- '--apply'; then
  ok "入っていなくても固定した版が winget に無ければ、-IfMissing を打たずに repo の版の直し方を出す"
else
  ng "入っていないが固定した版が winget に無い" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 17. -Check が 2 (winget が無い・例外): 手で打つコマンドを出して exit 0
h=$(new_home t17 "${state_on}" 1)
FAKE_PWSH_RC=2 FAKE_PWSH_OUT='winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && seen "${h}" '確かめられませんでした (終了コード 2' \
  && seen "${h}" -F 'アプリ インストーラー'; then
  ok "-Check が 2 (winget が無い) なら、スクリプトの出力と手で打つコマンドを出して exit 0"
else
  ng "-Check が 2" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 17b. -Check が 120 秒で時間切れ (124): 時間切れと出して、手で打つコマンドを出す (exit 0)
h=$(new_home t17b "${state_on}" 1)
FAKE_PWSH_RC=124 FAKE_PWSH_OUT='' run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && seen "${h}" '120 秒たっても終わりませんでした' && seen "${h}" 'Install-Tailscale -Check'; then
  ok "-Check が時間切れなら、時間切れと出して手で打つコマンドを出す"
else
  ng "-Check の時間切れ" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 18. --apply: -Check も -IfMissing も付けずに流す。成功なら exit 0
h=$(new_home t18 "${state_on}" 1)
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="揃った" run "${h}" 0 --apply
if [[ $(rc "${h}") == 0 ]] && pwsh_called "${h}" && ! called "${h}" -- '-Check' \
  && ! called "${h}" -- '-IfMissing' && called "${h}" -F 'C:\fake\Install-Tailscale.ps1' \
  && seen "${h}" '揃いました'; then
  ok "--apply は -Check を付けずに流し、成功なら exit 0"
else
  ng "--apply 成功" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 19. --apply が失敗: exit 1 (手で流すものなので失敗を返す)
h=$(new_home t19 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="tailscale.exe の版が読めないので、何もしない" run "${h}" 0 --apply
if [[ $(rc "${h}") == 1 ]] && seen "${h}" '揃いませんでした'; then
  ok "--apply が失敗したら exit 1"
else
  ng "--apply 失敗" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 20. 揃っているが winget に新しい版がある: 1 行に加えて ※ の行も出す (ずれではないので ⚠ にはしない)
h=$(new_home t20 "${state_on}" 1)
newer_listed='※ winget に固定した版より新しい 1.104.7 がある。上げるなら Install-Tailscale.ps1 の -Version の既定値を変える (入っている Tailscale は、自動更新が有効なら自分で上がる)'
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${synced_out}"$'\n'"${newer_listed}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 ]] && seen "${h}" '固定した版以上で入っています' \
  && seen "${h}" -F "${newer_listed}"; then
  ok "揃っていても、winget に新しい版があれば ※ の行を出す"
else
  ng "新しい版がある" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 21. pwsh.exe の出力に色のエスケープが混ざっていても、取り除いてから枠に入れる
h=$(new_home t21 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT='Tailscale (winget の Tailscale.Tailscale)'$'\n\e[33m⚠ winget pin      : 無し → 足す\e[0m' run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! seen "${h}" $'\e' && seen "${h}" -F '⚠ winget pin      : 無し → 足す'; then
  ok "pwsh.exe の色のエスケープは取り除いて出す"
else
  ng "エスケープが残る" "rc=$(rc "${h}") $(outerr "${h}" | od -c | head -8)"
fi

# 22. 知らない引数: exit 2
h=$(new_home t22 "${state_on}" 1)
run "${h}" 0 --bogus
if [[ $(rc "${h}") == 2 ]] && ! pwsh_called "${h}"; then
  ok "知らない引数は exit 2"
else
  ng "知らない引数" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 23. setup から走るとき (DOTFILES_SETUP_WARNINGS がある): 差があれば、⚠ の見出しと揃えるコマンドを
#     まとめ用に残す (状態の表は残さない。その場の ⚠ の枠には出ている)
h=$(new_home t23 "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${older_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(head -n 1 "${h}/warnings" 2>/dev/null) == 'Windows の Tailscale が、dotfiles で固定した版と揃っていません' ]] \
  && grep -qE '^[[:space:]]+揃えるには次のどちらかを打つ' "${h}/warnings" \
  && grep -qE '^[[:space:]]+WSL: .*/bootstrap-windows-tailscale\.sh --apply$' "${h}/warnings" \
  && grep -qE '^[[:space:]]+PowerShell: Install-Tailscale$' "${h}/warnings" \
  && ! grep -q 'winget pin' "${h}/warnings"; then
  ok "setup から走るとき、差があれば ⚠ の見出しと揃えるコマンドをまとめ用に残す"
else
  ng "差をまとめ用に残す" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null)"
fi

# 24. -IfMissing の時間切れでは、UAC の確認が残っているときの打ち直し方も、揃えるコマンドの前に残す
h=$(new_home t24 "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=124 FAKE_PWSH_OUT2='' run "${h}" 0
uac_at=$(grep -m 1 -n 'UAC の確認が残っていれば' "${h}/warnings" 2>/dev/null | cut -d: -f1)
apply_at=$(grep -m 1 -n -- '--apply' "${h}/warnings" 2>/dev/null | cut -d: -f1)
if [[ $(rc "${h}") == 0 && $(head -n 1 "${h}/warnings" 2>/dev/null) == 'Windows に Tailscale を入れられませんでした (600 秒待っても'* ]] \
  && [[ -n ${uac_at} && -n ${apply_at} ]] && ((uac_at < apply_at)); then
  ok "-IfMissing の時間切れでは、UAC の確認が残っているときの打ち直し方も揃えるコマンドの前に残す"
else
  ng "時間切れのまとめ" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null)"
fi

# 25. 揃っていれば (入っている版の方が新しいときも)、まとめ用には何も残さない。pwsh.exe が無ければ、見出しと手で打つコマンドを残す
h=$(new_home t25 "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${synced_out}" run "${h}" 0
h1=$(new_home t25a "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h1}/warnings" FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${newer_out}" run "${h1}" 0
h2=$(new_home t25b "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h2}/warnings" run "${h2}" 1
if [[ $(rc "${h}") == 0 && ! -s ${h}/warnings ]] && [[ $(rc "${h1}") == 0 && ! -s ${h1}/warnings ]] \
  && [[ $(rc "${h2}") == 0 && $(head -n 1 "${h2}/warnings" 2>/dev/null) == 'pwsh.exe が見つかりません'* ]] \
  && grep -qE '^[[:space:]]+Install-Tailscale -Check$' "${h2}/warnings"; then
  ok "揃っていれば (新しい版でも) 何も残さず、pwsh.exe が無ければ見出しと手で打つコマンドをまとめ用に残す"
else
  ng "揃っている・pwsh.exe が無いときのまとめ" "$(cat "${h}/warnings" 2>/dev/null) / $(cat "${h1}/warnings" 2>/dev/null) / $(cat "${h2}/warnings" 2>/dev/null)"
fi

# 26. script に実行ビットがある (setup.sh は実行ビットの無い bootstrap を「実行できません」で止める)
if [[ -x ${script} ]]; then
  ok "script に実行ビットがある (setup.sh は実行できない bootstrap で止まる)"
else
  ng "script に実行ビットが無い" "$(ls -l "${script}")"
fi

# 27. jq が無い: setup を止めないよう exit 0 で飛ばす (pwsh.exe は呼ばない)
nojq_bin="${work}/sys-bin-nojq"
mkdir -p "${nojq_bin}"
for c in "${sys_bin}"/*; do
  if [[ ${c##*/} != jq ]]; then
    ln -s "${c}" "${nojq_bin}/${c##*/}"
  fi
done
h=$(new_home t27 "${state_on}" 1)
env HOME="${h}" PATH="${h}/bin:${nojq_bin}" "${BASH}" "${script}" >"${h}/out" 2>"${h}/err"
echo $? >"${h}/rc"
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" 'jq が見つかりません'; then
  ok "jq が無くても exit 0 で飛ばす (setup を止めない)"
else
  ng "jq が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
