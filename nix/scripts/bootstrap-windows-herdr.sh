#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows の herdr (winget の Herdr.Herdr.Preview) が、dotfiles で固定した版に揃っているかを確かめる。
# 冪等。`setup.sh --update` でも毎回走る。入っていなければ winget で入れ、入っていて揃っていなければ
# ⚠ で囲んで知らせる (入れ替えはしない)。
#
# order: 97
#
# ^ setup.sh が読む実行順。bootstrap-windows-files.sh (order: 90) が Install-Herdr.ps1 を
#   置いた後に走らせる。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# Windows の herdr は winget の Herdr.Herdr.Preview で入れ、版は win/herdr/Install-Herdr.ps1 の
# -Version の既定値で固定する (win/README.md の「herdr を入れる」)。ただ、winget upgrade --all で
# 上がったり、herdr update (herdr 自身の更新) で別の herdr が PATH の先頭に入ったりすると、
# 気付かないままずれる。そこで setup のたびに差を確かめて見せる。新しいマシンでは入れるところまでする。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json (home-manager が置く) を読み、配らない
#    マシンなら飛ばす。<windowsHome>/.config/powershell/Install-Herdr.ps1 が無いときも飛ばす
# 2. pwsh.exe で Install-Herdr.ps1 -Check を流す (何も変えない)。
#    WSL の interop を通るので、落ちていたら手で打つコマンドを出して飛ばす (exit 0)
# 3. 終了コード 0 なら 1 行だけ出す。1 なら ⚠ で囲んだ注意と状態の表と揃えるコマンドを出す。
#    3 (入っていない) なら Install-Herdr.ps1 -IfMissing で入れる (入っていないなら herdr server も
#    動いていないので、何も巻き込まない)。どれも exit 0 (setup を止めない)
#
# --apply を付けて手で流すと、-Check を付けずに流して揃える。入れ替えが要るときに herdr が動いて
# いれば、スクリプトは何も変えずに止まる (herdr server は止めない。先に herdr の外で hsvstop)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
Windows の herdr (winget の Herdr.Herdr.Preview) が、dotfiles で固定した版に揃っているかを確かめる。

使い方:
  bootstrap-windows-herdr.sh            確かめる (入っていなければ入れる。差があれば ⚠ で知らせる)
  bootstrap-windows-herdr.sh --apply    揃える (入れ替えが要るなら、先に herdr の外の PowerShell で hsvstop)
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

# 自動で確かめられないときに、同じことを手で確かめるコマンドを出す
manual() {
  echo "   Windows の PowerShell で次を打つと、同じことを確かめられます:" >&2
  echo "     Install-Herdr -Check" >&2
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
deployed="${windows_home}/.config/powershell/Install-Herdr.ps1"
if [[ -z ${windows_home} || ! -f ${deployed} ]]; then
  echo "Install-Herdr.ps1 がまだ配られていません (${deployed})。この手順は飛ばします。"
  exit 0
fi

if ! command -v pwsh.exe &>/dev/null; then
  echo "!! pwsh.exe が見つかりません (PowerShell 7 が無いか、WSL の PATH に Windows の PATH が入っていない)。" >&2
  manual
  exit 0
fi
if ! win_script=$(wslpath -w "${deployed}" 2>/dev/null) || [[ -z ${win_script} ]]; then
  echo "!! Install-Herdr.ps1 の場所を Windows のパスに直せませんでした: ${deployed}" >&2
  manual
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

# ⚠ で囲んだ注意を出す。$1: 見出し、$2: 枠に入れる出力 (状態の表など)
rule="⚠️ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ⚠️"
warn_frame() {
  {
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    printf '%s⚠️  %s%s\n' "${c_warn}" "$1" "${c_reset}"
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    # PowerShell の締めの 1 行 (⚠️ … → Install-Herdr …) は、下の揃えるコマンドと重なるので落とす
    printf '%s\n' "$2" | grep -v '^⚠️ ' | sed 's/^/    /' || true
    printf '%s⚠️  揃えるには次のどちらかを打つ (入れ替えるときは、先に herdr の外の PowerShell で hsvstop):%s\n' "${c_warn}" "${c_reset}"
    printf '%s⚠️    WSL:        %s/bootstrap-windows-herdr.sh --apply%s\n' "${c_warn}" "${script_dir}" "${c_reset}"
    printf '%s⚠️    PowerShell: Install-Herdr%s\n' "${c_warn}" "${c_reset}"
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
  } >&2
}

if ((apply)); then
  # 手で流す前提なので、進み具合をそのまま見せる (winget のダウンロードを待つので timeout は付けない)
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
if grep -qF 'Herdr.Herdr.Preview' <<<"${out}"; then
  header=1
fi

if ((rc == 0)); then
  echo "Windows の herdr は、dotfiles で固定した版に揃っています。"
  # winget に新しい版がある、などの ※ の行は、揃っていても見せる (ずれではないので枠には入れない)
  grep '^※' <<<"${out}" | sed 's/^/  /' || true
  exit 0
fi
if ((rc == 1 && header)); then
  warn_frame "Windows の herdr が、dotfiles で固定した版と揃っていません" "${out}"
  exit 0
fi
if ((rc == 3 && header)); then
  echo "Windows に herdr が入っていないので、winget で固定した版を入れます (Install-Herdr.ps1 -IfMissing)。"
  # zip のダウンロードを待つので長めに待つ。VCRedist が無いマシンでは、winget が依存を入れる UAC が Windows に出る
  rc=0
  out=$(timeout 600 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -IfMissing")" </dev/null 2>&1) || rc=$?
  out=$(printf '%s\n' "${out}" | clean)
  if ((rc == 0)); then
    printf '%s\n' "${out}" | sed 's/^/  /'
    echo "Windows に herdr を入れました。"
    exit 0
  fi
  warn_frame "Windows に herdr を入れられませんでした (終了コード ${rc})" "${out}"
  exit 0
fi
echo "!! pwsh.exe で Windows の herdr を確かめられませんでした (終了コード ${rc}。WSL の interop が落ちているかもしれません):" >&2
if [[ -n ${out} ]]; then
  printf '%s\n' "${out}" | sed 's/^/   /' >&2
fi
manual
exit 0
