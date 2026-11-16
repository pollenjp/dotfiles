#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows の op-reason (自作の OSS。WSL の op の Windows の部品) を、dotfiles で固定した版に揃える。
# 冪等。`setup.sh --update` でも毎回走る。WSL の op の wrapper (op-reason) を入れるマシン
# (~/.local/state/dotfiles/claude-op-reason.json の enable が true) のうち、win/ を配るマシンだけが対象。
# 入っていなければ GitHub の Release から入れ、版がずれていれば入れ替える。
#
# order: 97
# tool: onePassword (dotfiles.onePassword.enable)
#
# ^ setup.sh が読む実行順と、設定グループで飛ばす道具。bootstrap-windows-files.sh (order: 90) が Install-OpReason.ps1 を
#   置いた後に走らせる。衝突で exit 1 しうる bootstrap-windows-google-ime.sh (98) より前に置く。bootstrap-windows-herdr.sh などと
#   同じ 97 で、同じ値は辞書順 (どれも相手を使わない)。1Password を入れないホスト (tools.onePassword が false) では
#   setup が流さない。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# WSL の op (home/modules/op-reason.nix が入れる op-reason の Release の Linux の実行ファイル) は、呼び出しごとに Windows の
# op-reason.exe (動かないときは隣の launcher.ps1) を起こして承認の窓を出す。その Windows の部品 (op-reason-windows.zip) を、
# win/op-reason/Install-OpReason.ps1 が GitHub の Release から固定した版で落とし、SHA-256 を確かめて
# %LOCALAPPDATA%\Programs\op-reason に置く (WSL の op は OPREASON_EXE でここを指す)。版と SHA-256 はその ps1 の表と
# -Version の既定値で固定する (win/README.md の「op-reason」)。
#
# WSL の実行ファイルは switch で上がり、Windows の部品が同じ版でないと呼び出しの取り決めが合わずに断られる。そこで
# type-clipboard と違い、版がずれていれば setup のたびに入れ替えまでする。op-reason.exe は op の呼び出しの間しか動かないので、
# 動いていなければ入れ替えても何も巻き込まない (動いていれば Install-OpReason.ps1 が何も変えずに止まる)。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json (home-manager が置く) を読み、配らないマシンなら飛ばす (WSL の op を入れる
#    マシンなら、Windows に手で入れるよう 1 行添える)。~/.local/state/dotfiles/claude-op-reason.json の enable が true でない
#    (WSL の op の wrapper を入れない) マシンも飛ばす。<windowsHome>/.config/powershell/Install-OpReason.ps1 が無いときも飛ばす
# 2. pwsh.exe で Install-OpReason.ps1 -Check を流す (何も変えない。ネットワークも使わない)。
#    WSL の interop を通るので、落ちていたら手で打つコマンドを出して飛ばす (exit 0)
# 3. 終了コード 0 なら 1 行だけ出す。1 (差がある) か 3 (入っていない) なら、引数なしで流して揃える。揃わなければ ⚠ で
#    囲んだ注意と出力と揃えるコマンドを出す。どれも exit 0 (setup を止めない)。⚠ の見出しと揃えるコマンドは、setup の
#    最後の「警告のまとめ」にも残す (summary_warn)
#
# --apply を付けて手で流すと、-Check を付けずに流して揃える (失敗なら exit 1)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
Windows の op-reason (WSL の op の Windows の部品) を、dotfiles で固定した版に揃える。
WSL の op の wrapper を入れ、win/ を配るマシンだけが対象。

使い方:
  bootstrap-windows-op-reason.sh            確かめ、入っていなければ入れ、版がずれていれば入れ替える
  bootstrap-windows-op-reason.sh --apply    確かめずに揃える (op-reason.exe が動いていれば、op の呼び出しが終わってから)
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
op_state_file="${HOME}/.local/state/dotfiles/claude-op-reason.json"

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
  echo "  Install-OpReason -Check"
}

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi

# WSL の op の wrapper (op-reason) を入れるマシンか (home/modules/op-reason.nix が書く。無い・壊れているなら入れないマシン)
op_reason=false
if [[ -r ${op_state_file} ]]; then
  op_reason=$(jq -r '.enable // false' "${op_state_file}" 2>/dev/null) || op_reason=false
fi

if [[ ! -r ${state_file} ]]; then
  echo "配り先の設定がありません (${state_file})。この手順は飛ばします。"
  exit 0
fi
if [[ $(jq -r '.enable' "${state_file}") != true ]]; then
  echo "このマシンは Windows 側へ配りません (dotfiles.wsl.windowsFiles.enable = false)。"
  if [[ ${op_reason} == true ]]; then
    echo "Windows 側へ配らないので op-reason の zip は入れません。WSL の op を使うなら、Windows に手で入れます (nix/README.md の「WSL の op を理由つきで呼ぶ」)。"
  fi
  exit 0
fi
if [[ ${op_reason} != true ]]; then
  echo "このマシンには WSL の op の wrapper (op-reason) を入れません (dotfiles.wsl.enable と dotfiles.onePassword.enable が両方 true のマシンだけ)。"
  exit 0
fi
windows_home=$(jq -r '.windowsHome // ""' "${state_file}")
deployed="${windows_home}/.config/powershell/Install-OpReason.ps1"
if [[ -z ${windows_home} || ! -f ${deployed} ]]; then
  echo "Install-OpReason.ps1 がまだ配られていません (${deployed})。この手順は飛ばします。"
  exit 0
fi

if ! command -v pwsh.exe &>/dev/null; then
  warn "pwsh.exe が見つかりません (PowerShell 7 が無いか、WSL の PATH に Windows の PATH が入っていない)。" "$(manual)"
  exit 0
fi
if ! win_script=$(wslpath -w "${deployed}" 2>/dev/null) || [[ -z ${win_script} ]]; then
  warn "Install-OpReason.ps1 の場所を Windows のパスに直せませんでした: ${deployed}" "$(manual)"
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
    "揃えるには次のどちらかを打つ (op-reason.exe が動いているときは、op の呼び出しが終わってから):"
    "  WSL:        ${script_dir}/bootstrap-windows-op-reason.sh --apply"
    "  PowerShell: Install-OpReason"
  )
  {
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    printf '%s⚠️  %s%s\n' "${c_warn}" "$1" "${c_reset}"
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    # PowerShell の締めの 1 行 (⚠️ … → Install-OpReason …) は、下の揃えるコマンドと重なるので落とす
    printf '%s\n' "$2" | grep -v '^⚠️ ' | sed 's/^/    /' || true
    for line in "${fix[@]}"; do
      printf '%s⚠️  %s%s\n' "${c_warn}" "${line}" "${c_reset}"
    done
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
  } >&2
  # setup の最後のまとめには、見出しと揃えるコマンドだけを残す (出力は、その場の枠に出ている)
  summary_warn "$1" "${fix[@]}"
}

if ((apply)); then
  # 手で流す前提なので、進み具合をそのまま見せる (zip を落とすのを待つので timeout は付けない)
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
captured=$(timeout 60 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -Check")" </dev/null 2>&1) || rc=$?
captured=$(printf '%s\n' "${captured}" | clean)

# 差がある・入っていないときの出力には、状態の表の見出し (取り先) が必ず入る。
# 終了コードが 1 や 3 でも見出しが無ければ、スクリプトが動いていない (差とは扱わない)。
header=0
if grep -qF 'op-reason (GitHub の Release' <<<"${captured}"; then
  header=1
fi

if ((rc == 0)); then
  echo "Windows の op-reason は、dotfiles で固定した版に揃っています。"
  exit 0
fi
if ((header)) && ((rc == 1 || rc == 3)); then
  if ((rc == 3)); then
    echo "Windows に op-reason が入っていないので、GitHub の Release から固定した版を入れます (Install-OpReason.ps1)。"
    done_msg="Windows に op-reason を入れました (%LOCALAPPDATA%\\Programs\\op-reason。WSL の op が OPREASON_EXE で使う)。"
    fail_msg="Windows に op-reason を入れられませんでした"
  else
    echo "Windows の op-reason が dotfiles で固定した版と揃っていないので、入れ替えます (Install-OpReason.ps1)。"
    done_msg="Windows の op-reason を、dotfiles で固定した版に揃えました。"
    fail_msg="Windows の op-reason を、dotfiles で固定した版に揃えられませんでした"
  fi
  # 落とすのは 500 KB ほどの zip 1 つだが、回線が遅いときに備えて長めに待つ (中の Invoke-WebRequest は 120 秒で切る)
  rc=0
  captured=$(timeout 300 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command "")" </dev/null 2>&1) || rc=$?
  captured=$(printf '%s\n' "${captured}" | clean)
  if ((rc == 0)); then
    printf '%s\n' "${captured}" | sed 's/^/  /'
    echo "${done_msg}"
    exit 0
  fi
  warn_frame "${fail_msg} (終了コード ${rc})" "${captured}"
  exit 0
fi
# pwsh.exe の出力 (あれば) と、手で打つコマンドを続きの行にする
warn "pwsh.exe で Windows の op-reason を確かめられませんでした (終了コード ${rc}。WSL の interop が落ちているかもしれません):" \
  ${captured:+"${captured}"} "$(manual)"
exit 0
