#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows の type-clipboard (自作のアプリ) が、dotfiles で固定した版に揃っているかを確かめる。
# 冪等。`setup.sh --update` でも毎回走る。dotfiles.wsl.windowsFiles.typeClipboard.enable = true の
# マシンだけが対象 (既定は false)。入っていなければ GitHub の Release から入れ、入っていて揃っていなければ
# ⚠ で囲んで知らせる (入れ替えはしない)。
#
# order: 97
#
# ^ setup.sh が読む実行順。bootstrap-windows-files.sh (order: 90) が Install-TypeClipboard.ps1 を
#   置いた後に走らせる。衝突で exit 1 しうる bootstrap-windows-google-ime.sh (98) より前に置く。
#   bootstrap-windows-herdr.sh と同じ 97 で、同じ値は辞書順なのでこちらが後 (どちらも相手を使わない)。
#   仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# type-clipboard は、クリップボードの文字を選んだ窓へキー入力として打ち込む自作の Windows のアプリ
# (pollenjp/type-clipboard。単一の exe)。winget には無いので、win/type-clipboard/Install-TypeClipboard.ps1 が
# GitHub の Release から固定した版の exe を落とし、SHA-256 を確かめて置く。版と SHA-256 はその ps1 の表と
# -Version の既定値で固定する (win/README.md の「type-clipboard」)。setup のたびに差を確かめて見せ、
# 新しいマシンでは入れるところまでする。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json (home-manager が置く) を読み、配らないマシン・
#    type-clipboard を入れないマシン (typeClipboard が true でない。欄の無い前の世代も) なら飛ばす。
#    <windowsHome>/.config/powershell/Install-TypeClipboard.ps1 が無いときも飛ばす
# 2. pwsh.exe で Install-TypeClipboard.ps1 -Check を流す (何も変えない。ネットワークも使わない)。
#    WSL の interop を通るので、落ちていたら手で打つコマンドを出して飛ばす (exit 0)
# 3. 終了コード 0 なら 1 行だけ出す。1 なら ⚠ で囲んだ注意と状態の表と揃えるコマンドを出す。
#    3 (入っていない) なら Install-TypeClipboard.ps1 -IfMissing で入れる (入っていないなら動いても
#    いないので、何も巻き込まない)。どれも exit 0 (setup を止めない)。⚠ の見出しと揃えるコマンドは、
#    setup の最後の「警告のまとめ」にも残す (summary_warn)
#
# --apply を付けて手で流すと、-Check を付けずに流して揃える。入れ替えが要るときに type-clipboard が
# 動いていれば、スクリプトは何も変えずに止まる (止めはしない。先に type-clipboard の窓を閉じる)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
Windows の type-clipboard (自作のアプリ) が、dotfiles で固定した版に揃っているかを確かめる。
dotfiles.wsl.windowsFiles.typeClipboard.enable = true のマシンだけが対象。

使い方:
  bootstrap-windows-type-clipboard.sh            確かめる (入っていなければ入れる。差があれば ⚠ で知らせる)
  bootstrap-windows-type-clipboard.sh --apply    揃える (入れ替えが要るなら、先に type-clipboard の窓を閉じる)
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
  echo "  Install-TypeClipboard -Check"
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
# 欄が無い (option を足す前の世代の windows-files.json) ときも、入れないマシンとして扱う
if [[ $(jq -r '.typeClipboard // false' "${state_file}") != true ]]; then
  echo "このマシンには type-clipboard を入れません (dotfiles.wsl.windowsFiles.typeClipboard.enable = false)。"
  exit 0
fi
windows_home=$(jq -r '.windowsHome // ""' "${state_file}")
deployed="${windows_home}/.config/powershell/Install-TypeClipboard.ps1"
if [[ -z ${windows_home} || ! -f ${deployed} ]]; then
  echo "Install-TypeClipboard.ps1 がまだ配られていません (${deployed})。この手順は飛ばします。"
  exit 0
fi

if ! command -v pwsh.exe &>/dev/null; then
  warn "pwsh.exe が見つかりません (PowerShell 7 が無いか、WSL の PATH に Windows の PATH が入っていない)。" "$(manual)"
  exit 0
fi
if ! win_script=$(wslpath -w "${deployed}" 2>/dev/null) || [[ -z ${win_script} ]]; then
  warn "Install-TypeClipboard.ps1 の場所を Windows のパスに直せませんでした: ${deployed}" "$(manual)"
  exit 0
fi

# pwsh.exe に渡すコマンド。$1 はスクリプトに渡す引数 (" -Check" など。空なら揃える)。
# 出力は UTF-8 にする (日本語と ⚠ が化けないよう)。パスは '' で囲む (中の ' は '' に)。
# 呼ぶ前に $LASTEXITCODE を 2 にしておく。スクリプトが exit まで届かずに終わる (構文の誤りなど) と、
# exit $LASTEXITCODE が中で打った外部コマンドの値を返し、成功に見えてしまうため。
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
  local line fix=(
    "揃えるには次のどちらかを打つ (入れ替えるときは、先に type-clipboard の窓を閉じる):"
    "  WSL:        ${script_dir}/bootstrap-windows-type-clipboard.sh --apply"
    "  PowerShell: Install-TypeClipboard"
  )
  {
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    printf '%s⚠️  %s%s\n' "${c_warn}" "$1" "${c_reset}"
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    # PowerShell の締めの 1 行 (⚠️ … → Install-TypeClipboard …) は、下の揃えるコマンドと重なるので落とす
    printf '%s\n' "$2" | grep -v '^⚠️ ' | sed 's/^/    /' || true
    for line in "${fix[@]}"; do
      printf '%s⚠️  %s%s\n' "${c_warn}" "${line}" "${c_reset}"
    done
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
  } >&2
  # setup の最後のまとめには、見出しと揃えるコマンドだけを残す (状態の表は、その場の枠に出ている)
  summary_warn "$1" "${fix[@]}"
}

if ((apply)); then
  # 手で流す前提なので、進み具合をそのまま見せる (exe を落とすのを待つので timeout は付けない)
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
# -Check はネットワークを使わないが、pwsh.exe の起動を待つので少し長めに待つ。
rc=0
out=$(timeout 60 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -Check")" </dev/null 2>&1) || rc=$?
out=$(printf '%s\n' "${out}" | clean)

# 差がある・入っていないときの出力には、状態の表の見出し (取り先) が必ず入る。
# 終了コードが 1 や 3 でも見出しが無ければ、スクリプトが動いていない (差とは扱わない)。
header=0
if grep -qF 'type-clipboard (GitHub の Release' <<<"${out}"; then
  header=1
fi

if ((rc == 0)); then
  echo "Windows の type-clipboard は、dotfiles で固定した版に揃っています。"
  exit 0
fi
if ((rc == 1 && header)); then
  warn_frame "Windows の type-clipboard が、dotfiles で固定した版と揃っていません" "${out}"
  exit 0
fi
if ((rc == 3 && header)); then
  echo "Windows に type-clipboard が入っていないので、GitHub の Release から固定した版を入れます (Install-TypeClipboard.ps1 -IfMissing)。"
  # 落とすのは 250 KB ほどの exe 1 つだが、回線が遅いときに備えて長めに待つ (中の Invoke-WebRequest は 120 秒で切る)
  rc=0
  out=$(timeout 300 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -IfMissing")" </dev/null 2>&1) || rc=$?
  out=$(printf '%s\n' "${out}" | clean)
  if ((rc == 0)); then
    printf '%s\n' "${out}" | sed 's/^/  /'
    echo "Windows に type-clipboard を入れました (スタートメニューの type-clipboard から起こす)。"
    exit 0
  fi
  warn_frame "Windows に type-clipboard を入れられませんでした (終了コード ${rc})" "${out}"
  exit 0
fi
# pwsh.exe の出力 (あれば) と、手で打つコマンドを続きの行にする
warn "pwsh.exe で Windows の type-clipboard を確かめられませんでした (終了コード ${rc}。WSL の interop が落ちているかもしれません):" \
  ${out:+"${out}"} "$(manual)"
exit 0
