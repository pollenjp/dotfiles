#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows の OpenSSH (winget の Microsoft.OpenSSH.Preview) が、dotfiles で固定した版に揃っているかを確かめる。
# 冪等。`setup.sh --update` でも毎回走り、揃っていなければ ⚠ で囲んで知らせる (揃えはしない)。
#
# order: 96
#
# ^ setup.sh が読む実行順。bootstrap-windows-files.sh (order: 90) が Install-OpenSSH.ps1 を
#   置いた後に走らせる。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# WSL の ssh は Windows の ssh.exe (C:\Program Files\OpenSSH) を呼んで 1Password の agent に
# つなぐ (ADR 004)。その OpenSSH の版は win/openssh/Install-OpenSSH.ps1 の -Version の既定値で
# 固定し、PowerShell の Install-OpenSSH で揃える (win/README.md の「OpenSSH」)。
# ただ、winget upgrade --all で上がったり、MSI の更新で ssh-agent サービスが自動・実行中に
# 戻ったり (1Password と pipe を取り合う) すると、気付かないままずれる。そこで setup のたびに
# 差を確かめて見せる。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json (home-manager が置く) を読み、配らない
#    マシンなら飛ばす。<windowsHome>/.config/powershell/Install-OpenSSH.ps1 が無いときも飛ばす
# 2. pwsh.exe で Install-OpenSSH.ps1 -Check を流す (管理者は要らない。何も変えない)。
#    WSL の interop を通るので、落ちていたら手で打つコマンドを出して飛ばす (exit 0)
# 3. 終了コード 0 なら 1 行だけ出す。1 なら ⚠ で囲んだ注意と状態の表と揃えるコマンドを出す。
#    どちらも exit 0 (setup を止めない。揃えるのは人が決める)。⚠ の見出しと揃えるコマンドは、
#    setup の最後の「警告のまとめ」にも残す (summary_warn)
#
# --apply を付けて手で流すと、-Check を付けずに流して揃える。差があれば Windows のデスクトップに
# UAC が 1 回出る。setup から --apply では流さない (UAC を押すまで止まり、動いている ssh も巻き込むため)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
Windows の OpenSSH (winget の Microsoft.OpenSSH.Preview) が、dotfiles で固定した版に揃っているかを確かめる。

使い方:
  bootstrap-windows-openssh.sh            揃っているかを確かめる (何も変えない。差があれば ⚠ で知らせる)
  bootstrap-windows-openssh.sh --apply    揃える (差があれば Windows に UAC が 1 回出る)
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
  echo "  Install-OpenSSH -Check"
}

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi

if [[ ! -r ${state_file} ]]; then
  echo "配り先の設定がありません (${state_file})。この手順は飛ばします。"
  exit 0
fi
if [[ $(jq -r '.enable' "${state_file}") != true ]]; then
  echo "このマシンは Windows 側へ配りません (dotfiles.wsl.windowsFiles.enable = false)。"
  exit 0
fi
windows_home=$(jq -r '.windowsHome // ""' "${state_file}")
deployed="${windows_home}/.config/powershell/Install-OpenSSH.ps1"
if [[ -z ${windows_home} || ! -f ${deployed} ]]; then
  echo "Install-OpenSSH.ps1 がまだ配られていません (${deployed})。この手順は飛ばします。"
  exit 0
fi

if ! command -v pwsh.exe &>/dev/null; then
  warn "pwsh.exe が見つかりません (PowerShell 7 が無いか、WSL の PATH に Windows の PATH が入っていない)。" "$(manual)"
  exit 0
fi
if ! win_script=$(wslpath -w "${deployed}" 2>/dev/null) || [[ -z ${win_script} ]]; then
  warn "Install-OpenSSH.ps1 の場所を Windows のパスに直せませんでした: ${deployed}" "$(manual)"
  exit 0
fi

# pwsh.exe に渡すコマンド。出力は UTF-8 にする (日本語と ⚠ が化けないよう)。
# パスは '' で囲む (中の ' は '' に)。-NoProfile: $PROFILE (dotfiles.ps1) は読まない。
# 呼ぶ前に $LASTEXITCODE を 2 にしておく。スクリプトが exit まで届かずに終わる (構文の誤りなど) と、
# exit $LASTEXITCODE が中で打った外部コマンドの値 (winget の 0 など) を返し、成功に見えてしまうため。
quoted=${win_script//\'/\'\'}
mode=" -Check"
if ((apply)); then
  mode=""
fi
# shellcheck disable=SC2016
command="[Console]::OutputEncoding = [Text.Encoding]::UTF8; \$global:LASTEXITCODE = 2; & '${quoted}'${mode}; exit \$LASTEXITCODE"

if ((apply)); then
  # 手で流す前提なので、進み具合をそのまま見せる (UAC を押すまで待つので timeout は付けない)
  echo "+ pwsh.exe -NoProfile -ExecutionPolicy Bypass -Command \"& '${win_script}'\""
  rc=0
  pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "${command}" </dev/null | tr -d '\r' || rc=$?
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
out=$(timeout 120 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "${command}" </dev/null 2>&1) || rc=$?
# CRLF と、PowerShell が付けうる色のエスケープを落とす (枠の色はこちらで付ける)
esc=$'\e'
out=$(printf '%s\n' "${out}" | tr -d '\r' | sed "s/${esc}\[[0-9;]*[A-Za-z]//g")

# 差があるときの出力には、状態の表の見出し (パッケージ名) が必ず入る。
# 終了コードが 1 でも見出しが無ければ、スクリプトが動いていない (差とは扱わない)。
if ((rc == 0)); then
  echo "Windows の OpenSSH は、dotfiles で固定した版に揃っています。"
  # winget に新しい版がある、などの ※ の行は、揃っていても見せる (ずれではないので枠には入れない)
  grep '^※' <<<"${out}" | sed 's/^/  /' || true
  exit 0
fi
if ((rc == 1)) && grep -qF 'Microsoft.OpenSSH.Preview' <<<"${out}"; then
  rule="⚠️ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ⚠️"
  title="Windows の OpenSSH が、dotfiles で固定した版と揃っていません"
  fix=(
    "揃えるには次のどちらかを打つ (差があれば Windows に UAC が 1 回出ます):"
    "  WSL:        ${script_dir}/bootstrap-windows-openssh.sh --apply"
    "  PowerShell: Install-OpenSSH"
  )
  {
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    printf '%s⚠️  %s%s\n' "${c_warn}" "${title}" "${c_reset}"
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    # PowerShell の締めの 1 行 (⚠️ … 揃っていない → Install-OpenSSH …) は、下の揃えるコマンドと重なるので落とす
    printf '%s\n' "${out}" | grep -v '^⚠️ 固定した版と揃っていない' | sed 's/^/    /'
    for line in "${fix[@]}"; do
      printf '%s⚠️  %s%s\n' "${c_warn}" "${line}" "${c_reset}"
    done
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
  } >&2
  # setup の最後のまとめには、見出しと揃えるコマンドだけを残す (状態の表は、その場の枠に出ている)
  summary_warn "${title}" "${fix[@]}"
  exit 0
fi
# pwsh.exe の出力 (あれば) と、手で打つコマンドを続きの行にする
warn "pwsh.exe で Windows の OpenSSH を確かめられませんでした (終了コード ${rc}。WSL の interop が落ちているかもしれません):" \
  ${out:+"${out}"} "$(manual)"
exit 0
