#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows の Tailscale (winget の Tailscale.Tailscale) を、dotfiles で固定した版で入れる (入っていないときだけ)。
# 冪等。`setup.sh --update` でも毎回走る。Tailscale を入れるマシン (~/.local/state/dotfiles/group.json の
# tools.windowsTailscale が true) のうち、win/ を配るマシンだけが対象。入っていれば固定した版と比べて知らせるだけで、上げはしない。
#
# order: 96
# tool: windowsTailscale (dotfiles.wsl.windowsFiles.tailscale.enable)
#
# ^ setup.sh が読む実行順と、設定グループで飛ばす道具。bootstrap-windows-files.sh (order: 90) が Install-Tailscale.ps1 を
#   置いた後、衝突で exit 1 しうる bootstrap-windows-google-ime.sh (98) より前に走らせる。machine スコープで UAC の出る
#   bootstrap-windows-openssh.sh と同じ 96 で、同じ値は辞書順なのでこちらが後 (どちらも相手を使わない)。Tailscale を入れない
#   ホスト (tools.windowsTailscale が false。minimum の既定) では setup が流さない。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# Windows の Tailscale は winget の Tailscale.Tailscale (MSI) で入れ、版は win/tailscale/Install-Tailscale.ps1 の -Version の
# 既定値で固定する (win/README.md の「Tailscale を入れる」)。VPN の道具で、会社の PC などには勝手に入れないよう、道具の switch
# (dotfiles.wsl.windowsFiles.tailscale.enable) は minimum では既定で off (all の win/ を配るマシンでは on)。入れるのは新しいマシンの最初だけで、
# その後は Tailscale が自分で上がる (自動更新) ので、入っている版の方が新しくても下げず、揃っている扱いにする。
# tailnet へのログイン (tailscale up・GUI のログイン) には触らない。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json (home-manager が置く) を読み、配らないマシンなら飛ばす。
#    ~/.local/state/dotfiles/group.json の tools.windowsTailscale が true でないマシン (false・欄の無い前の世代・ファイルが無い)
#    も飛ばす (setup も # tool: で飛ばすが、手で流したときと前の世代のため)。<windowsHome>/.config/powershell/Install-Tailscale.ps1
#    が無いときも飛ばす
# 2. pwsh.exe で Install-Tailscale.ps1 -Check を流す (何も変えない)。
#    WSL の interop を通るので、落ちていたら手で打つコマンドを出して飛ばす (exit 0)
# 3. 終了コード 0 なら 1 行を出す (入っている版の方が新しい・winget に新しい版があるなどの ※ の補足があれば添える)。
#    1 なら ⚠ で囲んだ注意と状態の表と揃えるコマンドを出す (固定した版が winget に無い・入っている版が読めないときは、
#    打っても直らないので、揃えるコマンドの代わりに repo の版の直し方・確かめ方を出す)。
#    3 (入っていない) なら Install-Tailscale.ps1 -IfMissing で入れる。machine スコープの MSI なので Windows に UAC の確認と
#    進み具合の小さな窓が出る (その場にいて押せるはずの、新しいマシンで起きる)。ただし固定した版が winget に無いときは、打っても
#    入れられない (UAC も出ない) ので -IfMissing は打たず、直し方を出す。
#    どれも exit 0。待つ上限は -Check が 120 秒、-IfMissing が 600 秒 (-Check が時間切れなら、そう出す)。
#    ⚠ の見出しと直し方は、setup の最後の「警告のまとめ」にも残す (summary_warn)
#
# 上げるのは setup からはしない。Tailscale の自動更新が有効なら自分で上がり、上げる間は Tailscale の接続が切れるため。
# --apply を付けて手で流すと、-Check を付けずに流して揃える (bootstrap-windows-google-ime-install.sh と同じ。古ければ
# UAC の確認が出る)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
Windows の Tailscale (winget の Tailscale.Tailscale) を、dotfiles で固定した版で入れる (入っていないときだけ)。
Tailscale を入れ (dotfiles.wsl.windowsFiles.tailscale.enable = true)、win/ を配るマシンだけが対象。

使い方:
  bootstrap-windows-tailscale.sh            確かめる (入っていなければ入れる。古ければ ⚠ で知らせる)
  bootstrap-windows-tailscale.sh --apply    揃える (上げるときは Windows に UAC の確認が出て、Tailscale の接続が少しの間切れる)
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
  echo "  Install-Tailscale -Check"
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
# Tailscale を入れるマシンか (home/modules/group.nix が書く)。前はどのグループでも既定が off だったので、ファイルや欄が無い (道具を足す前の
# 世代)・壊れているときも入れないマシンとして扱う
windows_tailscale=false
if [[ -r ${group_file} ]]; then
  windows_tailscale=$(jq -r '.tools.windowsTailscale // false' "${group_file}" 2>/dev/null) || windows_tailscale=false
fi
if [[ ${windows_tailscale} != true ]]; then
  echo "このマシンには Windows の Tailscale を入れません (dotfiles.wsl.windowsFiles.tailscale.enable が false。minimum では既定で off)。"
  exit 0
fi
windows_home=$(jq -r '.windowsHome // ""' "${state_file}")
deployed="${windows_home}/.config/powershell/Install-Tailscale.ps1"
if [[ -z ${windows_home} || ! -f ${deployed} ]]; then
  echo "Install-Tailscale.ps1 がまだ配られていません (${deployed})。この手順は飛ばします。"
  exit 0
fi

if ! command -v pwsh.exe &>/dev/null; then
  warn "pwsh.exe が見つかりません (PowerShell 7 が無いか、WSL の PATH に Windows の PATH が入っていない)。" "$(manual)"
  exit 0
fi
if ! win_script=$(wslpath -w "${deployed}" 2>/dev/null) || [[ -z ${win_script} ]]; then
  warn "Install-Tailscale.ps1 の場所を Windows のパスに直せませんでした: ${deployed}" "$(manual)"
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

# ⚠ で囲んだ注意を出す。$1: 見出し、$2: 枠に入れる出力 (状態の表など)、$3: 揃えるコマンドの前に添える 1 行 (省略可)
rule="⚠️ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ⚠️"
warn_frame() {
  local line fix=()
  # 添える 1 行 ($3) があれば、揃えるコマンドの前に出す
  if [[ -n ${3-} ]]; then
    fix+=("$3")
  fi
  if grep -qF 'winget show --versions に無い' <<<"$2"; then
    # 固定した版が winget に無い: 揃えるコマンドを打っても入れられないので、repo の版の直し方だけを出す
    fix+=("固定した版が winget に無いので、入れることも上げることもできません。repo の版 (Install-Tailscale.ps1 の -Version) を winget show --id Tailscale.Tailscale --versions にある版へ変えてください")
  elif grep -qF '比べられない' <<<"$2"; then
    # 入っている版が読めない: 揃えるコマンドは何もしないので、確かめ方だけを出す
    fix+=("入っている版が読めないので、揃えられません。上の ※ のとおり、PowerShell で winget list --id Tailscale.Tailscale を打って入っている版を確かめてください")
  else
    # 古い・pin が無い (入っている版の方が新しいときも、pin が無ければここ。下げはしない)
    fix+=(
      "揃えるには次のどちらかを打つ (上げるときは Windows に UAC の確認が出て、上げる間 Tailscale の接続が少しの間切れる。pin を足すだけなら UAC は出ない。setup は上げない: Tailscale の自動更新を有効にしてあれば、自分で上がる):"
      "  WSL:        ${script_dir}/bootstrap-windows-tailscale.sh --apply"
      "  PowerShell: Install-Tailscale"
    )
  fi
  {
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    printf '%s⚠️  %s%s\n' "${c_warn}" "$1" "${c_reset}"
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    # PowerShell の締めの 1 行 (⚠️ … → Install-Tailscale …) は、下の揃えるコマンドと重なるので落とす
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
# winget show (ネットワーク) を挟むので、少し長めに待つ。
rc=0
out=$(timeout 120 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -Check")" </dev/null 2>&1) || rc=$?
out=$(printf '%s\n' "${out}" | clean)

# 差がある・入っていないときの出力には、状態の表の見出し (パッケージ名) が必ず入る。
# 終了コードが 1 や 3 でも見出しが無ければ、スクリプトが動いていない (差とは扱わない)。
header=0
if grep -qF 'Tailscale.Tailscale' <<<"${out}"; then
  header=1
fi

if ((rc == 0)); then
  echo "Windows の Tailscale は、dotfiles で固定した版以上で入っています。"
  # 入っている版の方が新しい・winget に新しい版がある、などの ※ の行は、揃っていても見せる (ずれではないので枠には入れない)
  grep '^※' <<<"${out}" | sed 's/^/  /' || true
  exit 0
fi
if ((rc == 1 && header)); then
  warn_frame "Windows の Tailscale が、dotfiles で固定した版と揃っていません" "${out}"
  exit 0
fi
# 入っていないが、固定した版が winget に無い: -IfMissing を打っても入れられない (UAC も出ない) ので、打たずに直し方を出す
if ((rc == 3 && header)) && grep -qF 'winget show --versions に無い' <<<"${out}"; then
  warn_frame "Windows に Tailscale が入っていませんが、固定した版が winget に無いので入れられません" "${out}"
  exit 0
fi
if ((rc == 3 && header)); then
  echo "Windows に Tailscale が入っていないので、winget で固定した版を入れます (Install-Tailscale.ps1 -IfMissing)。"
  echo "Windows のデスクトップに UAC の確認が出たら「はい」を押してください (進み具合の小さな窓も出ます。600 秒まで待ちます)。"
  # MSI のダウンロードと、UAC を押すのを待つので長めに待つ
  rc=0
  out=$(timeout 600 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -IfMissing")" </dev/null 2>&1) || rc=$?
  out=$(printf '%s\n' "${out}" | clean)
  if ((rc == 0)); then
    # tailnet へのログインは手でする、の案内は ps1 の出力に入っている (重ねて出さない)
    printf '%s\n' "${out}" | sed 's/^/  /'
    echo "Windows に Tailscale を入れました。"
    exit 0
  fi
  if ((rc == 124)); then
    warn_frame "Windows に Tailscale を入れられませんでした (600 秒待っても終わらない。UAC の確認が出たままかもしれません)" "${out}" \
      "Windows のデスクトップに UAC の確認が残っていれば、先に押すか閉じてから打ち直してください (残ったまま打ち直すと、別のインストールが進行中 (1618) で落ちます)"
    exit 0
  fi
  warn_frame "Windows に Tailscale を入れられませんでした (終了コード ${rc})" "${out}"
  exit 0
fi
if ((rc == 124)); then
  headline="pwsh.exe が 120 秒たっても終わりませんでした (時間切れ。winget の応答か、WSL の interop が止まっているかもしれません):"
else
  headline="pwsh.exe で Windows の Tailscale を確かめられませんでした (終了コード ${rc}。WSL の interop が落ちているかもしれません):"
fi
# pwsh.exe の出力 (あれば) と、手で打つコマンドを続きの行にする
warn "${headline}" ${out:+"${out}"} "$(manual)"
exit 0
