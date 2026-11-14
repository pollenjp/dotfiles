#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows の Claude Code (winget の Anthropic.ClaudeCode) を、dotfiles で固定した版に揃える。
# 冪等。`setup.sh --update` でも毎回走る。dotfiles.wsl.windowsFiles.claudeCode.enable = true (既定) のマシンが対象。
# 入っていなければ winget で入れ、版か pin がずれていれば固定した版に揃える (Windows の Claude Code が動いていれば揃えずに ⚠ で知らせる)。
# PATH のずれ (native の installer などのほかの claude.exe が先に引かれる) は揃える手順では直らないので、⚠ で囲んで直し方を知らせる。
#
# order: 97
#
# ^ setup.sh が読む実行順。bootstrap-windows-files.sh (order: 90) が Install-ClaudeCode.ps1 を置いた後に走らせる。
#   衝突で exit 1 しうる bootstrap-windows-google-ime.sh (98) より前に置く。bootstrap-windows-herdr.sh などと同じ 97 で、
#   同じ値は辞書順 (どれも相手を使わない)。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# Windows の Claude Code は winget の Anthropic.ClaudeCode で入れ、版は win/claude-code/Install-ClaudeCode.ps1 の -Version の
# 既定値で固定する (win/README.md の「Claude Code」)。winget で入れた Claude Code は自分では上がらないが、手で winget upgrade
# すると気付かないままずれるので、setup のたびに確かめて揃える。WSL の claude (mise が入れる) とは別のもの。
# herdr と違って常駐も UAC も無いので、ずれは知らせるだけにせず揃える。新しいマシンでは入れるところまでする。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json (home-manager が置く) を読み、配らないマシン・Claude Code を入れないマシン
#    (claudeCode が false) なら飛ばす。欄の無い前の世代は option の既定どおり入れる (jq の // は false も置き換えるので has で
#    読む)。<windowsHome>/.config/powershell/Install-ClaudeCode.ps1 が無いときも飛ばす
# 2. pwsh.exe で Install-ClaudeCode.ps1 -Check を流す (何も変えない)。WSL の interop を通るので、落ちていたら手で打つ
#    コマンドを出して飛ばす (exit 0)
# 3. 終了コード 0 なら 1 行だけ出す。3 (入っていない) なら Install-ClaudeCode.ps1 -IfMissing で入れる。1 で -Check の締めの行
#    (Install-ClaudeCode.ps1 の Format-ClaudeCodeVerdict) が「→ Install-ClaudeCode で揃える」なら、引数なしで流して揃える (入れ替えが要るのに
#    Windows の Claude Code が動いていれば、ps1 が何も変えずに止まる)。締めの行が「→ ※ の手順で直す」だけ (PATH のずれ) なら、揃えずに
#    ⚠ で囲んで知らせる。揃わなければ ⚠ で囲んだ注意と出力と直し方を出す。どれも exit 0 (setup を止めない)。
#    ⚠ の見出しと直し方は、setup の最後の「警告のまとめ」にも残す (summary_warn)
#
# --apply を付けて手で流すと、-Check を付けずに流して揃える。

set -eu -o pipefail

usage() {
  cat <<'EOS'
Windows の Claude Code (winget の Anthropic.ClaudeCode) を、dotfiles で固定した版に揃える。
dotfiles.wsl.windowsFiles.claudeCode.enable = true (既定) のマシンが対象。

使い方:
  bootstrap-windows-claude-code.sh            確かめて、入っていなければ入れ、ずれていれば揃える (揃わなければ ⚠ で知らせる)
  bootstrap-windows-claude-code.sh --apply    揃える (確かめずに流す)
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
  echo "  Install-ClaudeCode -Check"
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
# 欄が無い (option を足す前の世代の windows-files.json) ときは、option の既定どおり入れる。
# jq の // は false も右の値に置き換えるので使わない
if [[ $(jq -r 'if has("claudeCode") then .claudeCode else true end' "${state_file}") != true ]]; then
  echo "このマシンには Claude Code を入れません (dotfiles.wsl.windowsFiles.claudeCode.enable = false)。入っているものは消しません。"
  exit 0
fi
windows_home=$(jq -r '.windowsHome // ""' "${state_file}")
deployed="${windows_home}/.config/powershell/Install-ClaudeCode.ps1"
if [[ -z ${windows_home} || ! -f ${deployed} ]]; then
  echo "Install-ClaudeCode.ps1 がまだ配られていません (${deployed})。この手順は飛ばします。"
  exit 0
fi

if ! command -v pwsh.exe &>/dev/null; then
  warn "pwsh.exe が見つかりません (PowerShell 7 が無いか、WSL の PATH に Windows の PATH が入っていない)。" "$(manual)"
  exit 0
fi
if ! win_script=$(wslpath -w "${deployed}" 2>/dev/null) || [[ -z ${win_script} ]]; then
  warn "Install-ClaudeCode.ps1 の場所を Windows のパスに直せませんでした: ${deployed}" "$(manual)"
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

# 直し方。版・pin の差を揃えるコマンド
fix_sync=(
  "揃えるには次のどちらかを打つ (入れ替えるときは、Windows で開いている Claude Code の会話を先に閉じる):"
  "  WSL:        ${script_dir}/bootstrap-windows-claude-code.sh --apply"
  "  PowerShell: Install-ClaudeCode"
)
# 直し方。PATH のずれ (揃える手順では直らない)
fix_path=(
  "PATH のずれは揃える手順では直らない。上の ※ の行の手順で直す (win/README.md の「Claude Code」)"
)

# ⚠ で囲んだ注意を出す。$1: 見出し、$2: 枠に入れる出力 (状態の表など。空なら何も入れない)、
# 残り: 直し方の行 (1 つが 1 行)
rule="⚠️ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ⚠️"
warn_frame() {
  local title=$1 body=$2 line
  shift 2
  {
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    printf '%s⚠️  %s%s\n' "${c_warn}" "${title}" "${c_reset}"
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    # PowerShell の締めの行 (⚠️ … → Install-ClaudeCode …) は、下の直し方と重なるので落とす
    if [[ -n ${body} ]]; then
      printf '%s\n' "${body}" | grep -v '^⚠️ ' | sed 's/^/    /' || true
    fi
    for line in "$@"; do
      printf '%s⚠️  %s%s\n' "${c_warn}" "${line}" "${c_reset}"
    done
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
  } >&2
  # setup の最後のまとめには、見出しと直し方だけを残す (状態の表は、その場の枠に出ている)
  summary_warn "${title}" "$@"
}

# Install-ClaudeCode.ps1 の締めの行 (Format-ClaudeCodeVerdict) から、直すことを読む。$1: pwsh.exe の出力
#   needs_install: 入っていない (Install-ClaudeCode で入れる)
#   needs_sync:    版か pin の差がある (Install-ClaudeCode で揃える)
#   needs_path:    PATH のずれがある (揃える手順では直らない)
read_verdict() {
  needs_install=0
  needs_sync=0
  needs_path=0
  if grep -qF '→ Install-ClaudeCode で入れる' <<<"$1"; then
    needs_install=1
  fi
  if grep -qF '→ Install-ClaudeCode で揃える' <<<"$1"; then
    needs_sync=1
  fi
  if grep -qF '→ ※ の手順で直す' <<<"$1"; then
    needs_path=1
  fi
}

# 入れた・揃えたあとの終わり方。$1: したこと (入れ / 揃え)、$2: 終了コード、$3: pwsh.exe の出力
report_after() {
  local did=$1 code=$2 body=$3
  if ((code == 0)); then
    printf '%s\n' "${body}" | sed 's/^/  /'
    echo "Windows の Claude Code を${did}ました (固定した版と pin が揃っています)。"
    return 0
  fi
  read_verdict "${body}"
  if ((code == 1 && needs_path && ! needs_sync && ! needs_install)); then
    warn_frame "Windows の Claude Code の版と pin は揃いましたが、PATH で引かれる claude が winget のものではありません" "${body}" "${fix_path[@]}"
    return 0
  fi
  # 動いている・固定した版が winget に無い・取得できない、など。何が揃わなかったかは枠の中の出力が言う
  if ((needs_path)); then
    warn_frame "Windows の Claude Code を${did}られませんでした (終了コード ${code})" "${body}" "${fix_sync[@]}" "${fix_path[@]}"
  else
    warn_frame "Windows の Claude Code を${did}られませんでした (終了コード ${code})" "${body}" "${fix_sync[@]}"
  fi
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
# pwsh.exe の出力は captured に取る (out は nix の build や devShell が export する名前で、大きな値を入れると
# 子のコマンドの環境に載る。pjp-shell-traps の「nix develop が export する名前」)
# 入れる・揃えるときに待つ秒数。claude.exe は 1 つで 340 MB ほどあり、入れ替えでは先に winget download で取得とハッシュを
# 確かめてから、install でもう一度落とす (herdr の 30 MB ほどの zip より長く待つ)
apply_timeout=1800

rc=0
captured=$(timeout 120 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -Check")" </dev/null 2>&1) || rc=$?
captured=$(printf '%s\n' "${captured}" | clean)

# 差がある・入っていないときの出力には、状態の表の見出し (パッケージ名) が必ず入る。
# 終了コードが 1 や 3 でも見出しが無ければ、スクリプトが動いていない (差とは扱わない)。
header=0
if grep -qF 'Claude Code (winget の Anthropic.ClaudeCode' <<<"${captured}"; then
  header=1
fi

if ((rc == 0)); then
  echo "Windows の Claude Code は、dotfiles で固定した版に揃っています。"
  # winget に新しい版がある、などの ※ の行は、揃っていても見せる (ずれではないので枠には入れない)
  grep '^※' <<<"${captured}" | sed 's/^/  /' || true
  exit 0
fi
if ((rc == 3 && header)); then
  echo "Windows に Claude Code (winget の Anthropic.ClaudeCode) が入っていないので、winget で固定した版を入れます (Install-ClaudeCode.ps1 -IfMissing。${apply_timeout} 秒まで待ちます)。"
  rc=0
  captured=$(timeout "${apply_timeout}" pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -IfMissing")" </dev/null 2>&1) || rc=$?
  captured=$(printf '%s\n' "${captured}" | clean)
  report_after 入れ "${rc}" "${captured}"
  exit 0
fi
if ((rc == 1 && header)); then
  read_verdict "${captured}"
  if ((needs_sync)); then
    echo "Windows の Claude Code が固定した版と揃っていないので、揃えます (Install-ClaudeCode.ps1。${apply_timeout} 秒まで待ちます)。"
    rc=0
    captured=$(timeout "${apply_timeout}" pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command "")" </dev/null 2>&1) || rc=$?
    captured=$(printf '%s\n' "${captured}" | clean)
    report_after 揃え "${rc}" "${captured}"
    exit 0
  fi
  # 版と pin は揃っていて、残っているのは PATH のずれだけ (揃える手順では直らない)
  warn_frame "Windows の Claude Code の PATH で引かれる claude が winget のものではありません" "${captured}" "${fix_path[@]}"
  exit 0
fi
# pwsh.exe の出力 (あれば) と、手で打つコマンドを続きの行にする
warn "pwsh.exe で Windows の Claude Code を確かめられませんでした (終了コード ${rc}。WSL の interop が落ちているかもしれません):" \
  ${captured:+"${captured}"} "$(manual)"
exit 0
