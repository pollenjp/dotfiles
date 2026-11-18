#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows に sshd (OpenSSH Server) を入れ、Tailscale (tailnet) と localhost からだけ、鍵でだけ SSH で入れる形に揃っているかを確かめる。
# 冪等。`setup.sh --update` でも毎回走る。sshd を入れるマシン (~/.local/state/dotfiles/group.json の tools.windowsSshd が true) の
# うち、win/ を配るマシンだけが対象。入っていなければ入れて揃え (UAC の確認が出る)、入っていてずれていれば ⚠ で囲んで知らせる
# (揃えはしない)。
#
# order: 96
# tool: windowsSshd (dotfiles.wsl.windowsFiles.sshd.enable)
#
# ^ setup.sh が読む実行順と、設定グループで飛ばす道具。bootstrap-windows-files.sh (order: 90) が Install-Sshd.ps1 を置き、
#   bootstrap-windows-openssh.sh (同じ 96。同じ値は辞書順なのでこちらが後) が OpenSSH (sshd を足す MSI) を入れた後に走る。
#   衝突で exit 1 しうる bootstrap-windows-google-ime.sh (98) より前。sshd を入れないホスト (tools.windowsSshd が false。どの
#   グループでも既定) では setup が流さない。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# iPhone の Herdr のアプリや hc は、各マシンの herdr-core に SSH で直につなぐ。Tailscale SSH のサーバーに Windows はなれないので、
# Windows には sshd を入れる。sshd は win/openssh/Install-Sshd.ps1 が、dotfiles が winget で固定した OpenSSH の MSI に Server を
# 足して入れ、鍵だけ・AllowUsers で tailnet と localhost に限る sshd_config と、Windows Firewall の拒否の規則 (tailnet からは 22 番
# だけ、22 番には tailnet と localhost からだけ) と、鍵 (administrators_authorized_keys) と、自動の起動を揃える
# (win/README.md の「sshd」、dotfiles-private の ADR 078)。PC に外から入る口を開けるので、道具の switch
# (dotfiles.wsl.windowsFiles.sshd.enable) はどのグループでも既定で off にしてある。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json (home-manager が置く) を読み、配らないマシンなら飛ばす。
#    ~/.local/state/dotfiles/group.json の tools.windowsSshd が true でないマシン (false・欄の無い前の世代・ファイルが無い) も
#    飛ばす (setup も # tool: で飛ばすが、手で流したときと前の世代のため)。<windowsHome>/.config/powershell/Install-Sshd.ps1 が
#    無いときも飛ばす
# 2. 鍵の写しを置く (pwsh.exe を呼べないときも先に揃える)。~/.local/state/dotfiles/windows-sshd.json の authorizedKeys (ホストの値の wsl.windowsFiles.sshd.authorizedKeys)
#    が list なら、Windows の %LOCALAPPDATA%\dotfiles\sshd\authorized_keys にその行を書く (中身が同じなら書かない)。null なら
#    写しを消す (Install-Sshd は写しが無ければ鍵の中身に触らない)。windows-sshd.json が無い前の世代では写しに触らない。
#    Install-Sshd.ps1 がこの写しどおりに administrators_authorized_keys を書く (管理者の鍵のファイルは管理者でないと書けないので、
#    利用者が書ける写しを挟む。手で打つ Install-Sshd も同じ鍵を置ける)
# 3. pwsh.exe で Install-Sshd.ps1 -Check を流す (何も変えない)。WSL の interop を通るので、落ちていたら手で打つコマンドを出して
#    飛ばす (exit 0)
# 4. 終了コード 0 なら 1 行を出す (※ の補足があれば添える)。1 なら ⚠ で囲んだ注意と状態の表と揃えるコマンドを出す (揃える前に
#    人が直すこと (OpenSSH が無い・Windows の機能の OpenSSH Server がある・書けないユーザー名・鍵の写しの読めない行) があれば、
#    揃えるコマンドの代わりにその直し方を出す)。3 (sshd が入っていない) なら Install-Sshd.ps1 -IfMissing で入れて揃える (UAC の
#    確認が出る。switch を on にしたマシンの最初の setup で起き、その場にいて押せるはず)。
#    どれも exit 0。待つ上限は -Check が 120 秒、-IfMissing が 600 秒。⚠ の見出しと直し方は、setup の最後の「警告のまとめ」にも
#    残す (summary_warn)
#
# ずれを揃えるのは setup からはしない。揃えるには UAC の確認が要り (外の端末から setup を流すと、押す人がいないまま待つ)、sshd を
# 起こし直すと、つないでいる SSH が切れることがあるため。--apply を付けて手で流すと、写しを置いてから -Check を付けずに流して揃える。

set -eu -o pipefail

usage() {
  cat <<'EOS'
Windows に sshd (OpenSSH Server) を入れ、Tailscale と localhost からだけ、鍵でだけ SSH で入れる形に揃っているかを確かめる。
sshd を入れ (dotfiles.wsl.windowsFiles.sshd.enable = true)、win/ を配るマシンだけが対象。

使い方:
  bootstrap-windows-sshd.sh            確かめる (入っていなければ入れて揃える。UAC の確認が出る。ずれていれば ⚠ で知らせる)
  bootstrap-windows-sshd.sh --apply    揃える (Windows に UAC の確認が出る。sshd を起こし直すと、つないでいる SSH が切れることがある)
EOS
}

apply=0
for arg in "$@"; do
  case ${arg} in
    --apply) apply=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "不明な引数です: ${arg}" >&2
      usage >&2
      exit 2
      ;;
  esac
done

script_dir=$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null || exit
  pwd -P
)
state_file="${HOME}/.local/state/dotfiles/windows-files.json"
group_file="${HOME}/.local/state/dotfiles/group.json"
sshd_file="${HOME}/.local/state/dotfiles/windows-sshd.json"

# ⚠ の枠を色付きで出すか。端末のときだけ (パイプや NO_COLOR では付けない)
if [[ -t 2 && -z ${NO_COLOR-} ]]; then
  c_warn=$'\e[1;33m'
  c_reset=$'\e[0m'
else
  c_warn=""
  c_reset=""
fi

# 手順を止めない警告を出す。引数は 1 つが 1 行で、2 つ目からは字下げした続きの行になる。
# setup.sh から走るときは、最後の「警告のまとめ」にも同じ行を残す (summary_warn)。
warn() {
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  printf '!! %s\n' "${text//${nl}/${nl}   }" >&2
  summary_warn "$@"
}

# setup.sh の最後の「警告のまとめ」にだけ警告を残す (その場には出さない。引数は warn と同じ)。
# setup.sh が手順ごとに DOTFILES_SETUP_WARNINGS でファイルを渡す。単体で流したときは何もしない。
summary_warn() {
  [[ -n ${DOTFILES_SETUP_WARNINGS-} ]] || return 0
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  { printf '%s\n' "${text//${nl}/${nl}   }" >>"${DOTFILES_SETUP_WARNINGS}"; } 2>/dev/null || true
}

# 自動で確かめられないときに、同じことを手で確かめるコマンド (warn の続きの行にする)
manual() {
  echo "Windows の PowerShell で次を打つと、同じことを確かめられます:"
  echo "  Install-Sshd -Check"
}

# jq が無くても setup は止めない (この手順は知らない引数の 2 以外で 0 以外を返さない)
if ! command -v jq &>/dev/null; then
  warn "jq が見つかりません。先に home-manager switch を実行してください。この手順は飛ばします。"
  exit 0
fi

if [[ ! -r ${state_file} ]]; then
  echo "配り先の設定がありません (${state_file})。この手順は飛ばします。"
  exit 0
fi
if [[ $(jq -r '.enable' "${state_file}") != true ]]; then
  echo "このマシンは Windows 側へ配りません (dotfiles.wsl.windowsFiles.enable = false)。"
  exit 0
fi
# sshd を入れるマシンか (home/modules/group.nix が書く)。どのグループでも既定は off なので、ファイルや欄が無い (道具を足す前の
# 世代)・壊れているときも入れないマシンとして扱う
windows_sshd=false
if [[ -r ${group_file} ]]; then
  windows_sshd=$(jq -r '.tools.windowsSshd // false' "${group_file}" 2>/dev/null) || windows_sshd=false
fi
if [[ ${windows_sshd} != true ]]; then
  echo "このマシンには Windows の sshd を入れません (dotfiles.wsl.windowsFiles.sshd.enable = false。どのグループでも既定は off)。"
  exit 0
fi
windows_home=$(jq -r '.windowsHome // ""' "${state_file}")
deployed="${windows_home}/.config/powershell/Install-Sshd.ps1"
if [[ -z ${windows_home} || ! -f ${deployed} ]]; then
  echo "Install-Sshd.ps1 がまだ配られていません (${deployed})。この手順は飛ばします。"
  exit 0
fi

# 鍵の写し (Install-Sshd.ps1 の -KeysCopy の既定と同じ場所。%LOCALAPPDATA%\dotfiles\sshd\authorized_keys)
copy_file="${windows_home}/AppData/Local/dotfiles/sshd/authorized_keys"
copy_head=(
  '# dotfiles の写し (nix/scripts/bootstrap-windows-sshd.sh が書く。手で直さない)。元は WSL のホストの値の wsl.windowsFiles.sshd.authorizedKeys (dotfiles-private)。'
  '# sshd はこのファイルを読まない。Install-Sshd が、この中身どおりに C:\ProgramData\ssh\administrators_authorized_keys を書く。'
)

# 鍵の写しを置く・消す (上の「何をするか」の 2)。置けなければ警告して先へ進む (-Check は、写しの今の中身で確かめる)
sync_keys_copy() {
  local kind want have tmp
  if [[ ! -r ${sshd_file} ]]; then
    echo "鍵の設定がまだありません (${sshd_file}。home-manager switch の前の世代)。鍵の写しには触りません。"
    return 0
  fi
  if ! kind=$(jq -r 'if .authorizedKeys == null then "null" elif (.authorizedKeys | type) == "array" then "list" else "bad" end' "${sshd_file}" 2>/dev/null); then
    warn "鍵の設定を読めませんでした (${sshd_file})。鍵の写しには触りません。"
    return 0
  fi
  case ${kind} in
    null)
      if [[ -e ${copy_file} ]]; then
        if rm -f -- "${copy_file}"; then
          echo "鍵の写しを消しました (ホストの値の wsl.windowsFiles.sshd.authorizedKeys が null。dotfiles は鍵を置かない): ${copy_file}"
        else
          warn "鍵の写しを消せませんでした: ${copy_file}"
        fi
      fi
      return 0
      ;;
    list) ;;
    *)
      warn "鍵の設定の authorizedKeys が list でも null でもありません (${sshd_file})。鍵の写しには触りません。"
      return 0
      ;;
  esac
  if ! want=$(
    printf '%s\n' "${copy_head[@]}"
    jq -r '.authorizedKeys[]' "${sshd_file}"
  ); then
    warn "鍵の設定を読めませんでした (${sshd_file})。鍵の写しには触りません。"
    return 0
  fi
  want+=$'\n'
  # 今の写しと同じなら書かない ($(…) は末尾の改行を落とすので、x を足して比べる)
  have=""
  if [[ -f ${copy_file} ]]; then
    have=$(
      cat -- "${copy_file}"
      printf x
    ) || have=""
  fi
  if [[ ${have} == "${want}x" ]]; then
    return 0
  fi
  if ! mkdir -p -- "${copy_file%/*}" || ! tmp=$(mktemp "${copy_file}.dotfiles-tmp.XXXXXX"); then
    warn "鍵の写しを置けませんでした: ${copy_file}"
    return 0
  fi
  if printf '%s' "${want}" >"${tmp}" && mv -f -- "${tmp}" "${copy_file}"; then
    echo "鍵の写しを置きました ($(jq -r '.authorizedKeys | length' "${sshd_file}") 本): ${copy_file}"
  else
    rm -f -- "${tmp}"
    warn "鍵の写しを置けませんでした: ${copy_file}"
  fi
}

# 写しは pwsh.exe を呼べないときも先に揃える (外した鍵が写しに残ると、後で PowerShell から打つ Install-Sshd が書き戻す)
sync_keys_copy

if ! command -v pwsh.exe &>/dev/null; then
  warn "pwsh.exe が見つかりません (PowerShell 7 が無いか、WSL の PATH に Windows の PATH が入っていない)。" "$(manual)"
  exit 0
fi
if ! win_script=$(wslpath -w "${deployed}" 2>/dev/null) || [[ -z ${win_script} ]]; then
  warn "Install-Sshd.ps1 の場所を Windows のパスに直せませんでした: ${deployed}" "$(manual)"
  exit 0
fi

# pwsh.exe に渡すコマンド。$1 はスクリプトに渡す引数 (" -Check" など。空なら揃える)。
# 出力は UTF-8 にする (日本語と ⚠ が化けないよう)。パスは '' で囲む (中の ' は '' に)。
# 呼ぶ前に $LASTEXITCODE を 2 にしておく。スクリプトが exit まで届かずに終わる (構文の誤りなど) と、
# exit $LASTEXITCODE が中で打った外部コマンドの値 (winget の 0 など) を返し、成功に見えてしまうため。
quoted=${win_script//\'/\'\'}
pwsh_command() {
  echo "[Console]::OutputEncoding = [Text.Encoding]::UTF8; \$global:LASTEXITCODE = 2; & '${quoted}'$1; exit \$LASTEXITCODE"
}

# CRLF と、PowerShell が付けうる色のエスケープを落とす (枠の色はこちらで付ける)
esc=$'\e'
clean() {
  tr -d '\r' | sed "s/${esc}\[[0-9;]*[A-Za-z]//g"
}

# ⚠ で囲んだ注意を出す。$1: 見出し、$2: 枠に入れる出力 (状態の表など)、$3: 直し方の前に添える 1 行 (省略可)
rule="⚠️ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ⚠️"
warn_frame() {
  local line fix=()
  if [[ -n ${3-} ]]; then
    fix+=("$3")
  fi
  # 揃える前に人が直すこと (Install-Sshd.ps1 の締めの行の文言で見分ける)。揃えるコマンドを打っても直らない
  if grep -qF 'OpenSSH が入っていない → 先に Install-OpenSSH' <<<"$2"; then
    fix+=(
      "sshd は OpenSSH の MSI に足すので、先に OpenSSH を入れてください (Windows に UAC の確認が出ます):"
      "  WSL:        ${script_dir}/bootstrap-windows-openssh.sh"
      "  PowerShell: Install-OpenSSH -IfMissing"
    )
  elif grep -qF 'Windows の機能の OpenSSH Server が入っている' <<<"$2"; then
    fix+=("二重にしないため、先に Windows の機能の OpenSSH Server を外してください (管理者の PowerShell で Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0)。外したら setup を流し直します")
  elif grep -qF 'AllowUsers に書けないユーザー名' <<<"$2"; then
    fix+=("Windows のユーザー名を AllowUsers に書けないので、このユーザーでは dotfiles の sshd を使えません (英小文字・数字・. _ - の名前のユーザーだけ。win/README.md の「sshd」)")
  elif grep -qF 'Windows Firewall が効いていないプロファイルがある' <<<"$2"; then
    fix+=("拒否の規則が効かないので揃えません。管理者の PowerShell で Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True を打ってから、setup を流し直してください (グループ ポリシーがローカルの規則を止めている PC では、dotfiles の sshd は使えません)")
  elif grep -qF 'sshd.exe はあるがサービス sshd が無い' <<<"$2"; then
    fix+=("MSI の入り方が崩れています。win/README.md の「sshd を止める・外す」の手順で Server の機能を外してから、setup を流し直してください")
  elif grep -qF '鍵の写しに読めない行がある' <<<"$2"; then
    fix+=("ホストの値の wsl.windowsFiles.sshd.authorizedKeys (dotfiles-private) の、authorized_keys の行として読めない値を直し、home-manager switch と setup を流し直してください")
  else
    fix+=(
      "揃えるには次のどちらかを打つ (Windows に UAC の確認が 1 回出ます。sshd を起こし直すと、つないでいる SSH が切れることがあります。setup は揃えません):"
      "  WSL:        ${script_dir}/bootstrap-windows-sshd.sh --apply"
      "  PowerShell: Install-Sshd"
    )
  fi
  {
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    printf '%s⚠️  %s%s\n' "${c_warn}" "$1" "${c_reset}"
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    # PowerShell の締めの 1 行 (⚠️ … → Install-Sshd …) は、下の直し方と重なるので落とす
    printf '%s\n' "$2" | grep -v '^⚠️ ' | sed 's/^/    /' || true
    for line in "${fix[@]}"; do
      printf '%s⚠️  %s%s\n' "${c_warn}" "${line}" "${c_reset}"
    done
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
  } >&2
  # setup の最後のまとめには、見出しと直し方だけを残す (状態の表は、その場の枠に出ている)
  summary_warn "$1" "${fix[@]}"
}

if ((apply)); then
  # 手で流す前提なので、進み具合をそのまま見せる (UAC を押すまで待つので timeout は付けない)
  echo "+ pwsh.exe -NoProfile -ExecutionPolicy Bypass -Command \"& '${win_script}'\""
  rc=0
  pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command "")" </dev/null | clean || rc=$?
  if ((rc == 0)); then
    echo "揃いました。"
    exit 0
  fi
  echo "!! 揃いませんでした (終了コード ${rc})。上の出力を確かめてください。" >&2
  exit 1
fi

# WSL の interop を通る。落ちていると Exec format error などで失敗する。
# Windows Firewall の規則を一通り読むので、少し長めに待つ。
rc=0
captured=$(timeout 120 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -Check")" </dev/null 2>&1) || rc=$?
captured=$(printf '%s\n' "${captured}" | clean)

# 差がある・入っていないときの出力には、状態の表の見出しが必ず入る。
# 終了コードが 1 や 3 でも見出しが無ければ、スクリプトが動いていない (差とは扱わない)。
header=0
if grep -qF 'sshd (OpenSSH Server' <<<"${captured}"; then
  header=1
fi

if ((rc == 0)); then
  echo "Windows の sshd は、dotfiles の形 (Tailscale と localhost からだけ、鍵でだけ入れる) に揃っています。"
  # 鍵の名札・鍵が 0 本、などの ※ の行は、揃っていても見せる (ずれではないので枠には入れない)
  grep '^※' <<<"${captured}" | sed 's/^/  /' || true
  exit 0
fi
if ((rc == 1 && header)); then
  warn_frame "Windows の sshd が、dotfiles の形と揃っていません" "${captured}"
  exit 0
fi
if ((rc == 3 && header)); then
  echo "Windows に sshd (OpenSSH Server) が入っていないので、OpenSSH の MSI に足して揃えます (Install-Sshd.ps1 -IfMissing)。"
  echo "Windows のデスクトップに UAC の確認が出たら「はい」を押してください (600 秒まで待ちます)。"
  # MSI を取り直して流し、UAC を押すのを待つので長めに待つ
  rc=0
  captured=$(timeout 600 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -IfMissing")" </dev/null 2>&1) || rc=$?
  captured=$(printf '%s\n' "${captured}" | clean)
  if ((rc == 0)); then
    # 鍵の名札や、Herdr を開いたままにする案内は ps1 の出力に入っている (重ねて出さない)
    printf '%s\n' "${captured}" | sed 's/^/  /'
    echo "Windows に sshd を入れて揃えました (Tailscale と localhost からだけ、鍵でだけ入れます)。"
    exit 0
  fi
  if ((rc == 124)); then
    warn_frame "Windows に sshd を入れられませんでした (600 秒待っても終わらない。UAC の確認が出たままかもしれません)" "${captured}" \
      "Windows のデスクトップに UAC の確認が残っていれば、先に押すか閉じてから打ち直してください (残ったまま打ち直すと、別のインストールが進行中 (1618) で落ちます)"
    exit 0
  fi
  warn_frame "Windows に sshd を入れられませんでした (終了コード ${rc})" "${captured}"
  exit 0
fi
if ((rc == 124)); then
  headline="pwsh.exe が 120 秒たっても終わりませんでした (時間切れ。WSL の interop が止まっているかもしれません):"
else
  headline="pwsh.exe で Windows の sshd を確かめられませんでした (終了コード ${rc}。WSL の interop が落ちているかもしれません):"
fi
# pwsh.exe の出力 (あれば) と、手で打つコマンドを続きの行にする
warn "${headline}" ${captured:+"${captured}"} "$(manual)"
exit 0
