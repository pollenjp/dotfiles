#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows の herdr-app と herdr-core が、公式の install.ps1 と同じ置き場所に入っているかを確かめる。
# 冪等。`setup.sh --update` でも毎回走る。app が入っていなければ Install-HerdrApp.ps1 で入れ、欠けているものが
# あれば ⚠ で囲んで知らせる (足しはしない)。版は見ない (app が自分で上げる)。
#
# order: 97
#
# ^ setup.sh が読む実行順。bootstrap-windows-files.sh (order: 90) が Install-HerdrApp.ps1 を置いた後に走らせる。
#   bootstrap-windows-herdr.sh と同じ 97 で、同じ値は辞書順なのでこちらが先 (どちらも相手を使わない)。
#   衝突で exit 1 しうる bootstrap-windows-google-ime.sh (98) より前に置き、それに止められないようにする。
#   仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# herdr-app (herdr の desktop app) は winget に無く、公式の入れ方は install.ps1 を irm で落として流すだけ。
# dotfiles では win/herdr-app/Install-HerdrApp.ps1 が、公式と同じ置き場所・手順を自分で踏む (win/README.md の
# 「herdr-app」)。新しいマシンでは入れるところまでし、入っているマシンでは欠けたもの (スタートメニューの
# Herdr.lnk・PATH の行・herdr-core) を見せる。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json (home-manager が置く) を読み、配らないマシンなら飛ばす。
#    <windowsHome>/.config/powershell/Install-HerdrApp.ps1 が無いときも飛ばす
# 2. pwsh.exe で Install-HerdrApp.ps1 -Check を流す (何も変えない。ネットワークも使わない)。
#    WSL の interop を通るので、落ちていたら手で打つコマンドを出して飛ばす (exit 0)
# 3. 終了コード 0 なら 1 行だけ出す。1 なら ⚠ で囲んだ注意と状態の表と揃えるコマンドを出す。3 (app が入って
#    いない) なら Install-HerdrApp.ps1 -IfMissing で入れる (入っていないなら app も動いていないので、何も
#    巻き込まない)。どれも exit 0 (setup を止めない)。⚠ の見出しと揃えるコマンドは、setup の最後の
#    「警告のまとめ」にも残す (summary_warn)
#
# --apply を付けて手で流すと、-Check を付けずに流して揃える (欠けているものだけを足す)。
# -Uninstall (外す) は打たない。外すのは、人が PowerShell で Install-HerdrApp -Uninstall を打つときだけ。

set -eu -o pipefail

usage() {
  cat <<'EOS'
Windows の herdr-app と herdr-core が、公式の install.ps1 と同じ置き場所に入っているかを確かめる。

使い方:
  bootstrap-windows-herdr-app.sh            確かめる (app が入っていなければ入れる。欠けているものがあれば ⚠ で知らせる)
  bootstrap-windows-herdr-app.sh --apply    揃える (欠けているものだけを足す)

外すときは Windows の PowerShell で Install-HerdrApp -Uninstall を打つ (win/README.md の「herdr-app を外す」)。
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
  echo "  Install-HerdrApp -Check"
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
deployed="${windows_home}/.config/powershell/Install-HerdrApp.ps1"
if [[ -z ${windows_home} || ! -f ${deployed} ]]; then
  echo "Install-HerdrApp.ps1 がまだ配られていません (${deployed})。この手順は飛ばします。"
  exit 0
fi

if ! command -v pwsh.exe &>/dev/null; then
  warn "pwsh.exe が見つかりません (PowerShell 7 が無いか、WSL の PATH に Windows の PATH が入っていない)。" "$(manual)"
  exit 0
fi
if ! win_script=$(wslpath -w "${deployed}" 2>/dev/null) || [[ -z ${win_script} ]]; then
  warn "Install-HerdrApp.ps1 の場所を Windows のパスに直せませんでした: ${deployed}" "$(manual)"
  exit 0
fi

# pwsh.exe に渡すコマンド。$1 はスクリプトに渡す引数 (" -Check" など。空なら揃える)。
# 出力は UTF-8 にする (日本語と ⚠ が化けないよう)。パスは '' で囲む (中の ' は '' に)。
# 呼ぶ前に $LASTEXITCODE を 2 にしておく。スクリプトが exit まで届かずに終わる (構文の誤りなど) と、
# exit $LASTEXITCODE が中で打った外部コマンドの値 (curl.exe の 0 など) を返し、成功に見えてしまうため。
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
    "揃えるには次のどちらかを打つ (欠けているものだけを足す):"
    "  WSL:        ${script_dir}/bootstrap-windows-herdr-app.sh --apply"
    "  PowerShell: Install-HerdrApp"
  )
  {
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    printf '%s⚠️  %s%s\n' "${c_warn}" "$1" "${c_reset}"
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    # PowerShell の締めの 1 行 (⚠️ … → Install-HerdrApp …) は、下の揃えるコマンドと重なるので落とす
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
  # 手で流す前提なので、進み具合をそのまま見せる (ダウンロードを待つので timeout は付けない)
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

# WSL の interop を通る。落ちていると Exec format error などで失敗する。-Check はネットワークを使わないが、
# app と core に --version を聞く (それぞれ 10 秒で打ち切る) ので、少し長めに待つ。
# 出力を入れる変数は out にしない (nix の build の中のテストでは out が export されている)
rc=0
captured=$(timeout 60 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -Check")" </dev/null 2>&1) || rc=$?
captured=$(printf '%s\n' "${captured}" | clean)

# 揃っていない・入っていないときの出力には、状態の表の見出し (herdr-app (…) が必ず入る。
# 終了コードが 1 や 3 でも見出しが無ければ、スクリプトが動いていない (差とは扱わない)。
header=0
if grep -q '^herdr-app (' <<<"${captured}"; then
  header=1
fi

if ((rc == 0)); then
  echo "Windows の herdr-app と herdr-core は入っています (版は app が自分で上げる)。"
  # 公式と違う置き場所の core などの ※ の行は、揃っていても見せる (ずれではないので枠には入れない)
  grep '^※' <<<"${captured}" | sed 's/^/  /' || true
  exit 0
fi
if ((rc == 1 && header)); then
  warn_frame "Windows の herdr-app に欠けているものがあります" "${captured}"
  exit 0
fi
if ((rc == 3 && header)); then
  echo "Windows に herdr-app が入っていないので、公式と同じ置き場所・手順で入れます (Install-HerdrApp.ps1 -IfMissing。600 秒まで待ちます)。"
  rc=0
  captured=$(timeout 600 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -IfMissing")" </dev/null 2>&1) || rc=$?
  captured=$(printf '%s\n' "${captured}" | clean)
  if ((rc == 0)); then
    printf '%s\n' "${captured}" | sed 's/^/  /'
    echo "Windows に herdr-app を入れました。スタートメニューの Herdr から開けます。"
    exit 0
  fi
  warn_frame "Windows に herdr-app を入れられませんでした (終了コード ${rc})" "${captured}"
  exit 0
fi
# pwsh.exe の出力 (あれば) と、手で打つコマンドを続きの行にする
warn "pwsh.exe で Windows の herdr-app を確かめられませんでした (終了コード ${rc}。WSL の interop が落ちているかもしれません):" \
  ${captured:+"${captured}"} "$(manual)"
exit 0
