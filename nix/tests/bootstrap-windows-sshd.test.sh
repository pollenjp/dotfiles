#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-sshd.sh の振る舞いを、使い捨ての HOME と
# 偽の pwsh.exe / wslpath で確かめる。
#
#   bash nix/tests/bootstrap-windows-sshd.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-sshd-test) が Nix のサンドボックスで流す。
# CI の `nix flake check` もこれを通る。使うのは bash・jq・coreutils・grep・sed だけ。
#
# ## 確かめること
#
#   - 配らないマシン・sshd を入れないマシン (group.json の tools.windowsSshd が false・欄が無い・group.json が無い)・
#     Install-Sshd.ps1 が無いときは pwsh.exe を呼ばずに飛ばす (入れないときは option の名前を出す)。--apply でも同じ
#   - script の冒頭に setup が読む `# tool: windowsSshd (dotfiles.wsl.windowsFiles.sshd.enable)` と `# order: 96` がある
#   - 鍵の写し (%LOCALAPPDATA%\dotfiles\sshd\authorized_keys): windows-sshd.json の authorizedKeys が list なら、見出しの後ろに
#     その行を書き、-Check より前に置く (空の list なら見出しだけ)。中身が同じなら書き直さない。null なら消す。windows-sshd.json が
#     無い前の世代では触らない。--apply でも先に置き、pwsh.exe を呼べないときも先に揃える
#   - pwsh.exe が無い・失敗する・こちらの出力を返さないときは、手で打つコマンドを出して exit 0
#     (-Check が時間切れ (124) のときは、時間切れと出す)
#   - -Check が 0 なら 1 行 (※ の補足があれば添える)。1 なら ⚠ で囲んだ注意・状態・揃えるコマンド (--apply と Install-Sshd) を出す
#     (揃えはしない)。揃える前に人が直すこと (OpenSSH が無い・Windows の機能の OpenSSH Server がある・書けないユーザー名・鍵の写しの
#     読めない行・拒否の規則が効かないプロファイル・サービスの無い sshd.exe) なら、揃えるコマンドの代わりにその直し方を出す
#   - -Check が 3 (sshd が入っていない) なら、UAC の確認が出ると先に出してから -IfMissing で入れる。入れられない・時間切れなら ⚠ で
#     囲んで知らせる (時間切れなら、UAC の確認が残っているときの打ち直し方も)
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
# WSL では PATH に本物の pwsh.exe と wslpath がある。見えると本物の Windows で winget や msiexec を
# 呼びうるので、要るコマンドだけを symlink で並べた PATH で流す (bootstrap-windows-tailscale.test.sh
# と同じ作り)。偽の pwsh.exe と wslpath の shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-sshd.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-sshd-test.XXXXXX")
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

# 例の鍵 (作り物。from= の IP は tailnet の範囲の例)
key1='from="100.64.0.1" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample01 phone'
key2='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample02 tablet'

# Install-Sshd.ps1 -Check の出力 (揃っている)
synced_out='sshd (OpenSSH Server、C:\Program Files\OpenSSH)
  server          : 入っている (C:\Program Files\OpenSSH\sshd.exe)
  サービス        : Running / Automatic
  sshd_config     : dotfiles の中身と同じ
  鍵              : 1 本 (写しと同じ)
  鍵の権限        : 読めない (管理者と SYSTEM だけが読める形とみる)
  拒否の規則      : 3 つとも揃っている (グループ dotfiles (sshd))
  22 番の受信の許可: 有効なものは無い
※ 鍵: phone (ssh-ed25519)
揃っている'

# Install-Sshd.ps1 -Check の出力 (ずれている。MSI の 22 番の許可が有効に戻った)
drift_out='sshd (OpenSSH Server、C:\Program Files\OpenSSH)
  server          : 入っている (C:\Program Files\OpenSSH\sshd.exe)
  サービス        : Running / Automatic
  sshd_config     : dotfiles の中身と同じ
  鍵              : 1 本 (写しと同じ)
  鍵の権限        : 読めない (管理者と SYSTEM だけが読める形とみる)
  拒否の規則      : 3 つとも揃っている (グループ dotfiles (sshd))
⚠ 22 番の受信の許可: 有効 (OpenSSH SSH Server Preview (sshd)) → 無効にする
※ 鍵: phone (ssh-ed25519)
⚠️ dotfiles の形と揃っていない → Install-Sshd で揃える (UAC の確認が 1 回出る。sshd を起こし直すと、つないでいる SSH が切れることがある) ⚠️'

# Install-Sshd.ps1 -Check の出力 (sshd が入っていない)
missing_out='sshd (OpenSSH Server、C:\Program Files\OpenSSH)
⚠ server          : 入っていない → 足す (Install-OpenSSH が入れた MSI の Server の機能)
⚠ サービス        : 無い → server を足した後に、自動で起こし、動かす
⚠ sshd_config     : 無い → dotfiles の中身を書く
⚠ 鍵              : ファイルが無い → 写しの 0 本を書く
⚠ 拒否の規則      : 無い・違うものが 3 つ (dotfiles-sshd-tailnet-tcp・dotfiles-sshd-tailnet-udp・dotfiles-sshd-outside-tcp22) → 作り直す
  22 番の受信の許可: 有効なものは無い
※ 鍵が 0 本 (誰も入れない)。入れる端末の公開鍵は、ホストの値 (dotfiles-private の wsl.windowsFiles.sshd.authorizedKeys) に足して setup を流す
⚠️ sshd が入っていない → Install-Sshd -IfMissing で入れる (UAC の確認が 1 回出る) ⚠️'

# Install-Sshd.ps1 -IfMissing が入れ終えたときの出力 (本物と同じく、入れる前の表から始まる)
installed_out="${missing_out%$'\n'*}
UAC で管理者の PowerShell を起動する (終わると閉じる)。Windows のデスクトップに UAC の確認が出たら「はい」を押す
  [管理者] MSI に Server の機能を足した (10.4.0.0)

${synced_out%揃っている}入れた
iPhone の Herdr のアプリや hc からつなぐときは、この PC で Herdr を開いたままにしておく (管理者の SSH の会話は昇格する。そこから core を起こすと、デスクトップの会話をふさぎうる)"

# 揃える前に人が直すことの出力 (どれも -Check が 1)
blocked_openssh_out='sshd (OpenSSH Server、C:\Program Files\OpenSSH)
⚠ server          : OpenSSH が入っていない (C:\Program Files\OpenSSH\ssh.exe が無い)。sshd はその MSI に足す
⚠️ OpenSSH が入っていない → 先に Install-OpenSSH -IfMissing で入れる (sshd はその MSI に足す) ⚠️'
blocked_inbox_out='sshd (OpenSSH Server、C:\Program Files\OpenSSH)
⚠ server          : Windows の機能の OpenSSH Server (System32\OpenSSH) が入っている。二重にしない
※ Windows の機能の OpenSSH Server を外すには、管理者の PowerShell で Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 を打つ (その後 Install-Sshd を打ち直す)
⚠️ Windows の機能の OpenSSH Server が入っている → 先に外す (二重にしない。上の ※ の行) ⚠️'
blocked_user_out='sshd (OpenSSH Server、C:\Program Files\OpenSSH)
※ AllowUsers に書けないユーザー名: john doe (dotfiles は英小文字・数字・. _ - の名前だけを書く。sshd はログインした本当の名前と比べるので、別の名前は渡せない)
⚠️ AllowUsers に書けないユーザー名 → このユーザーでは dotfiles の sshd を使えない (上の ※ の行) ⚠️'
blocked_firewall_out='sshd (OpenSSH Server、C:\Program Files\OpenSSH)
※ 拒否の規則が効かない Windows Firewall のプロファイル: Public (無効か、グループ ポリシーがローカルの規則を止めている)。有効にするには、管理者の PowerShell で Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True を打つ
⚠️ Windows Firewall が効いていないプロファイルがある → 先に有効にする (拒否の規則が効かない。上の ※ の行) ⚠️'
blocked_service_out='sshd (OpenSSH Server、C:\Program Files\OpenSSH)
⚠ server          : C:\Program Files\OpenSSH\sshd.exe はあるが、サービス sshd が無い (MSI の入り方が崩れている)
⚠️ sshd.exe はあるがサービス sshd が無い → Server の機能を外してから入れ直す (上の ※ の行) ⚠️'
blocked_keys_out='sshd (OpenSSH Server、C:\Program Files\OpenSSH)
※ 鍵の写しの読めない行: garbage line
⚠️ 鍵の写しに読めない行がある → ホストの値 (wsl.windowsFiles.sshd.authorizedKeys) を直して setup を流し直す ⚠️'

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

state_on='{"enable":true,"version":1,"windowsHome":"@WIN@"}'
state_off='{"enable":false,"version":1,"windowsHome":null}'
group_on='{"group":"personal","tiers":{"aiTools":true,"personalAccounts":true},"tools":{"windowsFiles":true,"windowsSshd":true},"version":1}'
group_off='{"group":"personal","tiers":{"aiTools":true,"personalAccounts":true},"tools":{"windowsFiles":true,"windowsSshd":false},"version":1}'
# 道具を足す前の世代の group.json (windowsSshd の欄が無い)
group_absent='{"group":"personal","tiers":{"aiTools":true,"personalAccounts":true},"tools":{"windowsFiles":true},"version":1}'
# windows-sshd.json の中身
keys_two=$(jq -nc --arg a "${key1}" --arg b "${key2}" '{version: 1, authorizedKeys: [$a, $b]}')
keys_empty='{"authorizedKeys":[],"version":1}'
keys_null='{"authorizedKeys":null,"version":1}'

# 1 ケースぶんの HOME を作る。
#   $1: 名前、$2: windows-files.json の中身 (空なら作らない。@WIN@ は配り先に置き換える)
#   $3: 1 なら Install-Sshd.ps1 を配った状態にする
#   $4: group.json の中身 (省けば sshd を入れるホスト。none なら作らない)
#   $5: windows-sshd.json の中身 (省けば鍵 2 本。none なら作らない)
# 配り先 (Windows のホームに見立てる) は <HOME>/win。鍵の写しは <HOME>/win/AppData/Local/dotfiles/sshd/authorized_keys。
new_home() {
  local h="${work}/$1" group=${4-${group_on}} keys=${5-${keys_two}}
  mkdir -p "${h}/.local/state/dotfiles" "${h}/bin" "${h}/win"
  if [[ -n $2 ]]; then
    printf '%s\n' "${2//@WIN@/${h}/win}" >"${h}/.local/state/dotfiles/windows-files.json"
  fi
  if [[ ${group} != none ]]; then
    printf '%s\n' "${group}" >"${h}/.local/state/dotfiles/group.json"
  fi
  if [[ ${keys} != none ]]; then
    printf '%s\n' "${keys}" >"${h}/.local/state/dotfiles/windows-sshd.json"
  fi
  if [[ $3 == 1 ]]; then
    mkdir -p "${h}/win/.config/powershell"
    printf '# Install-Sshd.ps1\n' >"${h}/win/.config/powershell/Install-Sshd.ps1"
  fi
  # 偽の pwsh.exe。引数を記録し、呼ばれた時点の鍵の写しを写し取り、出力を行ごとに CRLF で出して終わる。
  # -IfMissing の呼び出しは FAKE_PWSH_OUT2 / FAKE_PWSH_RC2、ほかは FAKE_PWSH_OUT / FAKE_PWSH_RC を使う
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/pwsh-calls"
copy="${HOME}/win/AppData/Local/dotfiles/sshd/authorized_keys"
if [[ -f ${copy} ]]; then cat "${copy}" >"${HOME}/copy-at-pwsh"; else printf 'none\n' >"${HOME}/copy-at-pwsh"; fi
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
  # 偽の wslpath。-w <パス> を C:\fake\<ファイル名> にする
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
[[ $1 == -w ]] || exit 1
printf 'C:\\fake\\%s\n' "${2##*/}"
EOF
  } >"${h}/bin/wslpath"
  chmod +x "${h}/bin/pwsh.exe" "${h}/bin/timeout" "${h}/bin/wslpath"
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
copy_of() { printf '%s' "$1/win/AppData/Local/dotfiles/sshd/authorized_keys"; }
# 鍵の写しの鍵の行 (# で始まる見出しを除く)
copy_keys() { grep -v '^#' "$(copy_of "$1")" 2>/dev/null; }

echo "== bootstrap-windows-sshd.sh: ${script}"

# 0. setup が読む冒頭の見出し (# order: と # tool:)
head40=$(head -n 40 "${script}")
if grep -qxF '# order: 96' <<<"${head40}" \
  && grep -qxF '# tool: windowsSshd (dotfiles.wsl.windowsFiles.sshd.enable)' <<<"${head40}"; then
  ok "冒頭 40 行に # order: 96 と # tool: windowsSshd (dotfiles.wsl.windowsFiles.sshd.enable) がある"
else
  ng "冒頭の見出し" "${head40}"
fi

# 1. 状態ファイルが無い: 飛ばす
h=$(new_home t1 "" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" '飛ばします' && [[ ! -e $(copy_of "${h}") ]]; then
  ok "windows-files.json が無ければ pwsh.exe を呼ばずに飛ばす (鍵の写しも置かない)"
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

# 3. sshd を入れないマシン (tools.windowsSshd が false・欄が無い・group.json が無い): option の名前を出して飛ばす
for c in off absent none; do
  case ${c} in
    off) g=${group_off} ;;
    absent) g=${group_absent} ;;
    none) g=none ;;
  esac
  h=$(new_home "t3-${c}" "${state_on}" 1 "${g}")
  run "${h}" 0
  if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" -F 'dotfiles.wsl.windowsFiles.sshd.enable = false' \
    && [[ ! -e $(copy_of "${h}") ]]; then
    ok "sshd を入れないマシン (${c}) なら pwsh.exe を呼ばずに飛ばす (option の名前を出す。鍵の写しも置かない)"
  else
    ng "sshd を入れないマシン (${c})" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
done

# 3b. --apply でも、入れないマシンなら飛ばす (手で流しても、switch を off にしたマシンには入れない)
h=$(new_home t3b "${state_on}" 1 "${group_off}")
run "${h}" 0 --apply
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" -F 'dotfiles.wsl.windowsFiles.sshd.enable = false'; then
  ok "--apply でも、sshd を入れないマシンなら pwsh.exe を呼ばずに飛ばす"
else
  ng "--apply と入れないマシン" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 4. Install-Sshd.ps1 が配られていない: 飛ばす
h=$(new_home t4 "${state_on}" 0)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" 'まだ配られていません'; then
  ok "Install-Sshd.ps1 が配られていなければ飛ばす"
else
  ng "Install-Sshd.ps1 が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 5. pwsh.exe が無い: 手で打つコマンドを出して exit 0。鍵の写しは先に揃える (外した鍵が写しに残らない)
h=$(new_home t5 "${state_on}" 1)
run "${h}" 1
if [[ $(rc "${h}") == 0 ]] && seen "${h}" -F 'Install-Sshd -Check' && [[ $(grep -c -v '^#' "$(copy_of "${h}")") == 2 ]]; then
  ok "pwsh.exe が無ければ手で打つコマンドを出して exit 0 (鍵の写しは先に揃える)"
else
  ng "pwsh.exe が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 6. pwsh.exe が失敗する (interop が落ちている): 手で打つコマンドを出して exit 0
h=$(new_home t6 "${state_on}" 1)
FAKE_PWSH_RC=126 FAKE_PWSH_OUT='' run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && seen "${h}" -F 'Install-Sshd -Check' && seen "${h}" '確かめられませんでした'; then
  ok "pwsh.exe が失敗したら手で打つコマンドを出して exit 0"
else
  ng "pwsh.exe が失敗する" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 7. 揃っている (-Check が 0): 1 行と ※ の行だけで ⚠ は出さない。pwsh.exe は -NoProfile と -Check で、配った場所を渡す
h=$(new_home t7 "${state_on}" 1)
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${synced_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 && $(ncalls "${h}") == 1 ]] \
  && seen "${h}" -F 'Windows の sshd は、dotfiles の形 (Tailscale と localhost からだけ、鍵でだけ入れる) に揃っています。' \
  && seen "${h}" -F '※ 鍵: phone (ssh-ed25519)' \
  && called "${h}" -- '-NoProfile' && called "${h}" -- '-Check' && called "${h}" -F 'C:\fake\Install-Sshd.ps1' \
  && [[ $(cat "${h}/timeout-calls") == 120 ]]; then
  ok "揃っていれば 1 行と ※ の行だけ出して exit 0 (pwsh.exe は -NoProfile -Check、配った場所を渡す)"
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

# 8. 鍵の写し: list なら見出しの後ろにその行を書き、-Check より前に置く
want_two=$(printf '%s\n%s' "${key1}" "${key2}")
if [[ $(copy_keys "${h}") == "${want_two}" ]] && [[ $(head -c 1 "$(copy_of "${h}")") == '#' ]] \
  && [[ $(grep -v '^#' "${h}/copy-at-pwsh") == "${want_two}" ]] && seen "${h}" -F '鍵の写しを置きました (2 本)'; then
  ok "鍵の list を、見出しの後ろに 1 行 1 本で写しに書き、-Check より前に置く"
else
  ng "鍵の写し (list)" "copy=$(cat "$(copy_of "${h}")" 2>/dev/null) at-pwsh=$(cat "${h}/copy-at-pwsh" 2>/dev/null) $(outerr "${h}")"
fi

# 8b. 中身が同じなら書き直さない (もう一度流しても「置きました」と出さない)
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${synced_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! seen "${h}" -F '鍵の写しを置きました' && [[ $(copy_keys "${h}") == "${want_two}" ]]; then
  ok "鍵の写しの中身が同じなら書き直さない"
else
  ng "同じ中身の写し" "$(outerr "${h}")"
fi

# 8c. 空の list なら見出しだけ (鍵 0 本)
h=$(new_home t8c "${state_on}" 1 "${group_on}" "${keys_empty}")
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${synced_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && -f $(copy_of "${h}") ]] && [[ -z $(copy_keys "${h}") ]] && seen "${h}" -F '鍵の写しを置きました (0 本)'; then
  ok "空の list なら、見出しだけの写し (鍵 0 本) を置く"
else
  ng "鍵の写し (空の list)" "copy=$(cat "$(copy_of "${h}")" 2>/dev/null) $(outerr "${h}")"
fi

# 8d. null なら写しを消す (前に置いた写しがあっても)
h=$(new_home t8d "${state_on}" 1 "${group_on}" "${keys_null}")
mkdir -p "$(dirname "$(copy_of "${h}")")"
printf '# old\n%s\n' "${key1}" >"$(copy_of "${h}")"
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${synced_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && ! -e $(copy_of "${h}") && $(cat "${h}/copy-at-pwsh") == none ]] && seen "${h}" -F '鍵の写しを消しました'; then
  ok "null なら、-Check より前に写しを消す (dotfiles は鍵を置かない)"
else
  ng "鍵の写し (null)" "$(outerr "${h}")"
fi

# 8e. windows-sshd.json が無い (前の世代): 写しに触らない
h=$(new_home t8e "${state_on}" 1 "${group_on}" none)
mkdir -p "$(dirname "$(copy_of "${h}")")"
printf '# old\n%s\n' "${key1}" >"$(copy_of "${h}")"
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${synced_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(copy_keys "${h}") == "${key1}" ]] && seen "${h}" -F '鍵の写しには触りません'; then
  ok "windows-sshd.json が無い前の世代では、写しに触らない"
else
  ng "windows-sshd.json が無い" "copy=$(cat "$(copy_of "${h}")" 2>/dev/null) $(outerr "${h}")"
fi

# 9. ずれている (-Check が 1): ⚠ で上下を囲み、状態と揃えるコマンドを出す。揃えはしない
h=$(new_home t9 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${drift_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 && $(ncalls "${h}") == 1 ]] && seen "${h}" '揃っていません' \
  && seen "${h}" -F '⚠ 22 番の受信の許可: 有効 (OpenSSH SSH Server Preview (sshd)) → 無効にする' \
  && seen "${h}" -F -- 'bootstrap-windows-sshd.sh --apply' && seen "${h}" -F 'PowerShell: Install-Sshd' \
  && seen "${h}" -F 'UAC' && seen "${h}" -F 'SSH が切れることがあります'; then
  ok "ずれていれば ⚠ で囲んだ注意と状態と揃えるコマンドを出して exit 0 (揃えはしない)"
else
  ng "ずれている" "rc=$(rc "${h}") warn_lines=$(warn_lines "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi
if ! seen "${h}" -F '揃っていない → Install-Sshd で揃える'; then
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

# 10. 揃える前に人が直すこと (-Check が 1): 揃えるコマンドの代わりに、その直し方を出す
for c in openssh inbox user keys firewall service; do
  case ${c} in
    openssh)
      o=${blocked_openssh_out}
      want='bootstrap-windows-openssh.sh'
      ;;
    inbox)
      o=${blocked_inbox_out}
      want='Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0'
      ;;
    user)
      o=${blocked_user_out}
      want='このユーザーでは dotfiles の sshd を使えません'
      ;;
    firewall)
      o=${blocked_firewall_out}
      want='Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True'
      ;;
    service)
      o=${blocked_service_out}
      want='「sshd を止める・外す」'
      ;;
    keys)
      o=${blocked_keys_out}
      want='wsl.windowsFiles.sshd.authorizedKeys (dotfiles-private)'
      ;;
  esac
  h=$(new_home "t10-${c}" "${state_on}" 1)
  FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${o}" run "${h}" 0
  if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 && $(ncalls "${h}") == 1 ]] && seen "${h}" -F "${want}" \
    && ! seen "${h}" -F -- 'bootstrap-windows-sshd.sh --apply'; then
    ok "揃える前に人が直すこと (${c}) なら、揃えるコマンドの代わりにその直し方を出す"
  else
    ng "揃える前に人が直すこと (${c})" "rc=$(rc "${h}") warn_lines=$(warn_lines "${h}") $(outerr "${h}")"
  fi
done

# 11. -Check が 1 でも、こちらの出力が無い (スクリプトが壊れている等): 差とは扱わず、手で打つコマンドを出す
h=$(new_home t11 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT='The term is not recognized as a name of a cmdlet' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 ]] && seen "${h}" '確かめられませんでした' \
  && seen "${h}" -F 'Install-Sshd -Check'; then
  ok "-Check の出力が来なければ差とは扱わず、手で打つコマンドを出して exit 0"
else
  ng "出力が来ない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 12. 入っていない (-Check が 3): UAC の確認が出ると先に出してから -IfMissing で入れる。入ったら ⚠ は出さない
h=$(new_home t12 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=0 FAKE_PWSH_OUT2="${installed_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 && $(ncalls "${h}") == 2 ]] && seen "${h}" 'UAC の確認が出たら' \
  && grep -q 'UAC の確認が出たら' "${h}/out-at-ifmissing" && [[ $(tr '\n' ' ' <"${h}/timeout-calls") == "120 600 " ]] \
  && seen "${h}" 'Windows に sshd を入れて揃えました' && [[ $(outerr "${h}" | grep -c 'Herdr を開いたままにしておく') == 1 ]] \
  && called_last "${h}" -- '-IfMissing' && ! called_last "${h}" -- '-Check' \
  && [[ $(grep -v '^#' "${h}/copy-at-pwsh") == "${want_two}" ]]; then
  ok "入っていなければ UAC が出ると出してから -IfMissing で入れ (鍵の写しは先に置く)、Herdr の案内を 1 回だけ出して exit 0"
else
  ng "入っていない → 入れる" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 13. 入れようとしたが失敗 (UAC で断った など): ⚠ で囲んで知らせる。setup は止めない
h=$(new_home t13 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=1 FAKE_PWSH_OUT2='管理者で起動できなかった (UAC で断った?): The operation was canceled by the user.' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 ]] && seen "${h}" '入れられませんでした (終了コード 1)' \
  && seen "${h}" -F 'UAC で断った' && seen "${h}" -F -- 'bootstrap-windows-sshd.sh --apply'; then
  ok "入れられなければ ⚠ で囲んで知らせて exit 0"
else
  ng "入れられない" "rc=$(rc "${h}") warn_lines=$(warn_lines "${h}") $(outerr "${h}")"
fi

# 14. UAC を押さないまま 600 秒たった (timeout の 124): 時間切れと出して ⚠ で囲む。UAC の確認が残っていれば
#     先に押すか閉じてから打ち直すよう添える (残ったまま打ち直すと 1618 で落ちる)。setup は止めない
h=$(new_home t14 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=124 FAKE_PWSH_OUT2='' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 ]] && seen "${h}" '600 秒待っても終わらない' \
  && seen "${h}" -F 'PowerShell: Install-Sshd' \
  && grep -qF 'UAC の確認が残っていれば、先に押すか閉じてから打ち直して' "${h}/err" && grep -qF '(1618)' "${h}/err"; then
  ok "UAC を押さないまま時間切れになったら ⚠ で囲んで知らせ、確認が残っているときの打ち直し方も添えて exit 0"
else
  ng "時間切れ" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 15. -Check が 3 でも、こちらの出力が無い: 入れには行かず、手で打つコマンドを出す
h=$(new_home t15 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT='Exec format error' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && seen "${h}" '確かめられませんでした' \
  && seen "${h}" -F 'Install-Sshd -Check'; then
  ok "-Check が 3 でも出力が来なければ、入れずに手で打つコマンドを出す"
else
  ng "3 だが出力が来ない" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 16. -Check が 2 (思わぬ例外): スクリプトの出力と手で打つコマンドを出して exit 0
h=$(new_home t16 "${state_on}" 1)
FAKE_PWSH_RC=2 FAKE_PWSH_OUT='エラーで止まった: Cannot bind argument to parameter' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && seen "${h}" '確かめられませんでした (終了コード 2' \
  && seen "${h}" -F 'エラーで止まった'; then
  ok "-Check が 2 なら、スクリプトの出力と手で打つコマンドを出して exit 0"
else
  ng "-Check が 2" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 16b. -Check が 120 秒で時間切れ (124): 時間切れと出して、手で打つコマンドを出す (exit 0)
h=$(new_home t16b "${state_on}" 1)
FAKE_PWSH_RC=124 FAKE_PWSH_OUT='' run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && seen "${h}" '120 秒たっても終わりませんでした' && seen "${h}" 'Install-Sshd -Check'; then
  ok "-Check が時間切れなら、時間切れと出して手で打つコマンドを出す"
else
  ng "-Check の時間切れ" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 17. --apply: 鍵の写しを置いてから、-Check も -IfMissing も付けずに流す。成功なら exit 0
h=$(new_home t17 "${state_on}" 1)
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="揃った" run "${h}" 0 --apply
if [[ $(rc "${h}") == 0 ]] && pwsh_called "${h}" && ! called "${h}" -- '-Check' \
  && ! called "${h}" -- '-IfMissing' && called "${h}" -F 'C:\fake\Install-Sshd.ps1' \
  && seen "${h}" '揃いました' && [[ $(grep -v '^#' "${h}/copy-at-pwsh") == "${want_two}" ]]; then
  ok "--apply は鍵の写しを置いてから -Check を付けずに流し、成功なら exit 0"
else
  ng "--apply 成功" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 18. --apply が失敗: exit 1 (手で流すものなので失敗を返す)
h=$(new_home t18 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="msiexec が失敗した (終了コード 1603。ログ: C:\\x.log)" run "${h}" 0 --apply
if [[ $(rc "${h}") == 1 ]] && seen "${h}" '揃いませんでした'; then
  ok "--apply が失敗したら exit 1"
else
  ng "--apply 失敗" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 19. pwsh.exe の出力に色のエスケープが混ざっていても、取り除いてから枠に入れる
h=$(new_home t19 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT='sshd (OpenSSH Server、C:\Program Files\OpenSSH)'$'\n\e[33m⚠ サービス        : Stopped / Manual → 自動で起こし、動かす\e[0m' run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! seen "${h}" $'\e' && seen "${h}" -F '⚠ サービス        : Stopped / Manual'; then
  ok "pwsh.exe の色のエスケープは取り除いて出す"
else
  ng "エスケープが残る" "rc=$(rc "${h}") $(outerr "${h}" | od -c | head -8)"
fi

# 20. 知らない引数: exit 2
h=$(new_home t20 "${state_on}" 1)
run "${h}" 0 --bogus
if [[ $(rc "${h}") == 2 ]] && ! pwsh_called "${h}"; then
  ok "知らない引数は exit 2"
else
  ng "知らない引数" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 21. setup から走るとき (DOTFILES_SETUP_WARNINGS がある): 差があれば、⚠ の見出しと揃えるコマンドを
#     まとめ用に残す (状態の表は残さない。その場の ⚠ の枠には出ている)
h=$(new_home t21 "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${drift_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(head -n 1 "${h}/warnings" 2>/dev/null) == 'Windows の sshd が、dotfiles の形と揃っていません' ]] \
  && grep -qE '^[[:space:]]+揃えるには次のどちらかを打つ' "${h}/warnings" \
  && grep -qE '^[[:space:]]+WSL: .*/bootstrap-windows-sshd\.sh --apply$' "${h}/warnings" \
  && grep -qE '^[[:space:]]+PowerShell: Install-Sshd$' "${h}/warnings" \
  && ! grep -q '22 番の受信の許可' "${h}/warnings"; then
  ok "setup から走るとき、差があれば ⚠ の見出しと揃えるコマンドをまとめ用に残す"
else
  ng "差をまとめ用に残す" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null)"
fi

# 22. -IfMissing の時間切れでは、UAC の確認が残っているときの打ち直し方も、揃えるコマンドの前に残す
h=$(new_home t22 "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=124 FAKE_PWSH_OUT2='' run "${h}" 0
uac_at=$(grep -m 1 -n 'UAC の確認が残っていれば' "${h}/warnings" 2>/dev/null | cut -d: -f1)
apply_at=$(grep -m 1 -n -- '--apply' "${h}/warnings" 2>/dev/null | cut -d: -f1)
if [[ $(rc "${h}") == 0 && $(head -n 1 "${h}/warnings" 2>/dev/null) == 'Windows に sshd を入れられませんでした (600 秒待っても'* ]] \
  && [[ -n ${uac_at} && -n ${apply_at} ]] && ((uac_at < apply_at)); then
  ok "-IfMissing の時間切れでは、UAC の確認が残っているときの打ち直し方も揃えるコマンドの前に残す"
else
  ng "時間切れのまとめ" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null)"
fi

# 23. 揃っていれば、まとめ用には何も残さない。pwsh.exe が無ければ、見出しと手で打つコマンドを残す
h=$(new_home t23 "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${synced_out}" run "${h}" 0
h2=$(new_home t23b "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h2}/warnings" run "${h2}" 1
if [[ $(rc "${h}") == 0 && ! -s ${h}/warnings ]] \
  && [[ $(rc "${h2}") == 0 && $(head -n 1 "${h2}/warnings" 2>/dev/null) == 'pwsh.exe が見つかりません'* ]] \
  && grep -qE '^[[:space:]]+Install-Sshd -Check$' "${h2}/warnings"; then
  ok "揃っていれば何も残さず、pwsh.exe が無ければ見出しと手で打つコマンドをまとめ用に残す"
else
  ng "揃っている・pwsh.exe が無いときのまとめ" "$(cat "${h}/warnings" 2>/dev/null) / $(cat "${h2}/warnings" 2>/dev/null)"
fi

# 24. script に実行ビットがある (setup.sh は実行ビットの無い bootstrap を「実行できません」で止める)
if [[ -x ${script} ]]; then
  ok "script に実行ビットがある (setup.sh は実行できない bootstrap で止まる)"
else
  ng "script に実行ビットが無い" "$(ls -l "${script}")"
fi

# 25. jq が無い: setup を止めないよう exit 0 で飛ばす (pwsh.exe は呼ばない)
nojq_bin="${work}/sys-bin-nojq"
mkdir -p "${nojq_bin}"
for c in "${sys_bin}"/*; do
  if [[ ${c##*/} != jq ]]; then
    ln -s "${c}" "${nojq_bin}/${c##*/}"
  fi
done
h=$(new_home t25 "${state_on}" 1)
env HOME="${h}" PATH="${h}/bin:${nojq_bin}" "${BASH}" "${script}" >"${h}/out" 2>"${h}/err"
echo $? >"${h}/rc"
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" 'jq が見つかりません'; then
  ok "jq が無くても exit 0 で飛ばす (setup を止めない)"
else
  ng "jq が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
