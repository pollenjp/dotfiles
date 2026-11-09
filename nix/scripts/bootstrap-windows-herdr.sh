#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows の herdr (winget の Herdr.Herdr) が、dotfiles で固定した版に揃っているかを確かめる。
# 冪等。`setup.sh --update` でも毎回走る。入っていなければ winget で入れ、入っていて揃っていなければ
# ⚠ で囲んで知らせる (入れ替えはしない)。前に入れていた Herdr.Herdr.Preview が残っていれば、外す手順を
# ⚠ で囲んで知らせる (外さない)。
#
# order: 97
#
# ^ setup.sh が読む実行順。bootstrap-windows-files.sh (order: 90) が Install-Herdr.ps1 を
#   置いた後に走らせる。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# Windows の herdr は winget の Herdr.Herdr で入れ、版は win/herdr/Install-Herdr.ps1 の
# -Version の既定値で固定する (win/README.md の「herdr を入れる」)。ただ、winget upgrade --all で
# 上がったり、herdr update (herdr 自身の更新) で別の herdr が PATH の先頭に入ったりすると、
# 気付かないままずれる。そこで setup のたびに差を確かめて見せる。新しいマシンでは入れるところまでする。
#
# 前は preview の Herdr.Herdr.Preview で入れていた。置き場所が別なので Herdr.Herdr を並べて入れられるが、
# Preview が残っている間は PATH で Preview の herdr が先に引かれうる。Preview を外すには動いている
# herdr server を止める (pane が消える) ので、setup は外さず、外すまで手順を知らせ続ける。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json (home-manager が置く) を読み、配らない
#    マシンなら飛ばす。<windowsHome>/.config/powershell/Install-Herdr.ps1 が無いときも飛ばす
# 2. pwsh.exe で Install-Herdr.ps1 -Check を流す (何も変えない)。
#    WSL の interop を通るので、落ちていたら手で打つコマンドを出して飛ばす (exit 0)
# 3. 終了コード 0 なら 1 行だけ出す。1 なら ⚠ で囲んだ注意と状態の表と直し方を出す。直し方は -Check の
#    締めの行 (Install-Herdr.ps1 の Format-HerdrVerdict) で決める: 版・pin・PATH の差なら揃えるコマンド、
#    Herdr.Herdr.Preview が残っていれば外す手順。
#    3 (入っていない) なら Install-Herdr.ps1 -IfMissing で入れる (Herdr.Herdr の置き場所の herdr は
#    動いていないので、何も巻き込まない)。Preview が残っていても並べて入れ、入ったら Preview を外す手順を出す。
#    どれも exit 0 (setup を止めない)。⚠ の見出しと直し方は、setup の最後の「警告のまとめ」にも残す (summary_warn)
#
# --apply を付けて手で流すと、-Check を付けずに流して揃える。入れ替えが要るときに herdr が動いて
# いれば、スクリプトは何も変えずに止まる (herdr server は止めない。先に herdr の外で hsvstop)。
# Herdr.Herdr.Preview は --apply でも外さない。

set -eu -o pipefail

usage() {
  cat <<'EOS'
Windows の herdr (winget の Herdr.Herdr) が、dotfiles で固定した版に揃っているかを確かめる。

使い方:
  bootstrap-windows-herdr.sh            確かめる (入っていなければ入れる。差があれば ⚠ で知らせる)
  bootstrap-windows-herdr.sh --apply    揃える (入れ替えが要るなら、先に herdr の外の PowerShell で hsvstop)

前に入れていた Herdr.Herdr.Preview が残っていれば、外す手順を ⚠ で知らせる (どちらも外さない)。
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
  echo "  Install-Herdr -Check"
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
  warn "pwsh.exe が見つかりません (PowerShell 7 が無いか、WSL の PATH に Windows の PATH が入っていない)。" "$(manual)"
  exit 0
fi
if ! win_script=$(wslpath -w "${deployed}" 2>/dev/null) || [[ -z ${win_script} ]]; then
  warn "Install-Herdr.ps1 の場所を Windows のパスに直せませんでした: ${deployed}" "$(manual)"
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

# 直し方。版・pin・PATH の差を揃えるコマンド
fix_sync=(
  "揃えるには次のどちらかを打つ (入れ替えるときは、先に herdr の外の PowerShell で hsvstop):"
  "  WSL:        ${script_dir}/bootstrap-windows-herdr.sh --apply"
  "  PowerShell: Install-Herdr"
)
# 直し方。前に入れていた Herdr.Herdr.Preview を外す手順 (Install-Herdr.ps1 の締めの行と同じ中身)
fix_preview=(
  "Herdr.Herdr.Preview を外すには (setup は外さない。herdr server を止めると pane が消えるので、時期を選んで打つ):"
  "  1. herdr の外の PowerShell (Windows Terminal など) で hsvstop を打ち、herdr --remote の窓も閉じる"
  "  2. PowerShell で winget pin remove --id Herdr.Herdr.Preview と winget uninstall --id Herdr.Herdr.Preview を打つ"
  "  3. 新しい PowerShell から herdr を起動し直す"
)
preview_title="Windows に前の herdr (Herdr.Herdr.Preview) が残っています"

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
    # PowerShell の締めの行 (⚠️ … → Install-Herdr …・Preview を外す手順) は、下の直し方と重なるので落とす
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

# Install-Herdr.ps1 の締めの行 (Format-HerdrVerdict) から、直すことを読む。$1: pwsh.exe の出力
#   needs_sync:    版・pin・PATH の差がある・入っていない (Install-Herdr で揃える・入れる)
#   needs_preview: Herdr.Herdr.Preview が残っている (人が外す)
read_verdict() {
  needs_sync=0
  needs_preview=0
  if grep -qE '^⚠️ .*→ Install-Herdr で(揃える|入れる)' <<<"$1"; then
    needs_sync=1
  fi
  if grep -qF '⚠️ Herdr.Herdr.Preview が残っている' <<<"$1"; then
    needs_preview=1
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
rc=0
captured=$(timeout 120 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -Check")" </dev/null 2>&1) || rc=$?
captured=$(printf '%s\n' "${captured}" | clean)

# 差がある・入っていないときの出力には、状態の表の見出し (パッケージ名) が必ず入る。
# 終了コードが 1 や 3 でも見出しが無ければ、スクリプトが動いていない (差とは扱わない)。
header=0
if grep -qF 'herdr (winget の Herdr.Herdr' <<<"${captured}"; then
  header=1
fi

if ((rc == 0)); then
  echo "Windows の herdr は、dotfiles で固定した版に揃っています。"
  # winget に新しい版がある、などの ※ の行は、揃っていても見せる (ずれではないので枠には入れない)
  grep '^※' <<<"${captured}" | sed 's/^/  /' || true
  exit 0
fi
if ((rc == 1 && header)); then
  read_verdict "${captured}"
  # 残っているのが Herdr.Herdr.Preview だけなら、見出しも直し方も Preview を外すことにする (Install-Herdr では直らない)
  if ((needs_preview && ! needs_sync)); then
    warn_frame "${preview_title}" "${captured}" "${fix_preview[@]}"
  elif ((needs_preview)); then
    warn_frame "Windows の herdr が、dotfiles で固定した版と揃っていません" "${captured}" "${fix_sync[@]}" "${fix_preview[@]}"
  else
    warn_frame "Windows の herdr が、dotfiles で固定した版と揃っていません" "${captured}" "${fix_sync[@]}"
  fi
  exit 0
fi
if ((rc == 3 && header)); then
  echo "Windows に herdr (winget の Herdr.Herdr) が入っていないので、winget で固定した版を入れます (Install-Herdr.ps1 -IfMissing)。"
  # zip のダウンロードを待つので長めに待つ。VCRedist が無いマシンでは、winget が依存を入れる UAC が Windows に出る
  rc=0
  captured=$(timeout 600 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -IfMissing")" </dev/null 2>&1) || rc=$?
  captured=$(printf '%s\n' "${captured}" | clean)
  read_verdict "${captured}"
  # Herdr.Herdr.Preview が残っていると -IfMissing は 1 を返す。締めの行が Preview のことだけなら、
  # Herdr.Herdr は入って揃っているので、入れた扱いにして Preview を外す手順を出す
  if ((rc == 0 || (rc == 1 && needs_preview && ! needs_sync))); then
    printf '%s\n' "${captured}" | grep -v '^⚠️ ' | sed 's/^/  /' || true
    echo "Windows に herdr を入れました。"
    if ((needs_preview)); then
      warn_frame "${preview_title}" "" "${fix_preview[@]}"
    fi
    exit 0
  fi
  # 入れられなかったときは、Preview を外す手順を出さない (外すと herdr が無くなる)
  warn_frame "Windows に herdr を入れられませんでした (終了コード ${rc})" "${captured}" "${fix_sync[@]}"
  exit 0
fi
# pwsh.exe の出力 (あれば) と、手で打つコマンドを続きの行にする
warn "pwsh.exe で Windows の herdr を確かめられませんでした (終了コード ${rc}。WSL の interop が落ちているかもしれません):" \
  ${captured:+"${captured}"} "$(manual)"
exit 0
