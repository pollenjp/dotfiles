#!/usr/bin/env bash
# shellcheck shell=bash
#
# win/ から配った PowerToys の Keyboard Manager の割り当て (default.json) を、Keyboard Manager に読み直させる。
# 冪等。`setup.sh --update` でも毎回走る。PowerToys が入っていなければ、先に winget で入れる。
#
# order: 91
#
# ^ setup.sh が読む実行順。bootstrap-windows-files.sh (order: 90) が default.json と
#   Install-PowerToys.ps1 を置いた後に走らせる。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# Keyboard Manager のエンジンは、起動したときと、名前付きイベント
# PowerToys_KeyboardManager_Event_Settings を受けたときにしか default.json を読まない
# (docs/adr/015_win_google_ime_powertoys_*)。win/ の割り当てを配っても、そのままでは効かない。
# 新しいマシンでは PowerToys そのものが入っていないので、読み直させる前に入れる (docs/adr/017_win_apps_winget_*)。
# エンジンが読むのは、同じディレクトリの settings.json が指す有効なプロファイルの JSON で、settings.json が
# 無ければ何も読まない。settings.json を作るのは PowerToys の設定画面だけで、作っても読み直させはしないので、
# 入れたばかりで設定画面を開いていないマシンでは、イベントを送っても default.json は読まれない
# (docs/adr/017_win_apps_winget_* の §1 の 7)。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json を読み、配らないマシンなら飛ばす
# 2. pwsh.exe で <windowsHome>/.config/powershell/Install-PowerToys.ps1 -Check を流し、3 (入っていない) なら
#    -IfMissing で入れる (user スコープ。管理者は要らない)。版は固定しないので、入っていれば何もしない。
#    スクリプトが無い・interop が使えない・入れられないときは、知らせて 3 へ進む
# 3. <windowsHome>/AppData/Local/Microsoft/PowerToys/Keyboard Manager/default.json が無ければ飛ばす
# 4. 同じディレクトリの settings.json の有効なプロファイル (properties.activeConfiguration.value) が
#    default でなければ、記録もイベントも触らずに案内して飛ばす (無い・読めないときは設定画面を一度
#    開いてから流し直すよう、default 以外のときは default に戻すよう出す)。記録すると、次の回から
#    「読み直し済み」で送らなくなるため
# 5. default.json の sha256 が、前回読み直させたときの記録
#    (~/.local/state/dotfiles/powertoys-keyboard-manager.reloaded) と同じなら何もしない (--force なら比べない)
# 6. powershell.exe でイベントを送る。送れたら記録する。イベントが無い (PowerToys が動いていない) ときも
#    記録する (起動したときに読むため)。interop が使えなければ手で読み直す方法を出し、記録しない
#
# どの場合も exit 0 (後ろの手順を止めない)。知らない引数だけ exit 2。知らせたこと (⚠ の枠は見出しと
# 入れるコマンド) は、setup の最後の「警告のまとめ」にも残す (warn / summary_warn)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
win/ から配った PowerToys の Keyboard Manager の割り当て (default.json) を、Keyboard Manager に読み直させる。
PowerToys が入っていなければ、先に winget で入れる。

使い方:
  bootstrap-windows-powertoys.sh          前回から変わっていれば読み直させる
  bootstrap-windows-powertoys.sh --force  変わっていなくても読み直させる
EOS
}

force=0
for arg in "$@"; do
  case ${arg} in
    --force) force=1 ;;
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
record_file="${HOME}/.local/state/dotfiles/powertoys-keyboard-manager.reloaded"
event=PowerToys_KeyboardManager_Event_Settings

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

# 読み直させられないときに、手で読み直す方法 (warn の続きの行にする)
manual() {
  echo "PowerToys の設定 → Keyboard Manager を一度オフにしてオンに戻すと、読み直します。"
}

# PowerToys が入っているかを自動で確かめられないときに、手で確かめて入れるコマンド (warn の続きの行にする)
install_manual() {
  echo "Windows の PowerShell で次を打つと、確かめて、入っていなければ入れられます:"
  echo "  Install-PowerToys"
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
    "入れるには次のどちらかを打つ (管理者は要りません):"
    "  WSL:        ${script_dir}/bootstrap-windows-powertoys.sh (流し直すと、もう一度入れにいく)"
    "  PowerShell: Install-PowerToys"
  )
  {
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    printf '%s⚠️  %s%s\n' "${c_warn}" "$1" "${c_reset}"
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    # PowerShell の締めの 1 行 (⚠️ … → Install-PowerToys …) は、下の入れるコマンドと重なるので落とす
    printf '%s\n' "$2" | grep -v '^⚠️ ' | sed 's/^/    /' || true
    for line in "${fix[@]}"; do
      printf '%s⚠️  %s%s\n' "${c_warn}" "${line}" "${c_reset}"
    done
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
  } >&2
  # setup の最後のまとめには、見出しと入れるコマンドだけを残す (winget の出力は、その場の枠に出ている)
  summary_warn "$1" "${fix[@]}"
}

# pwsh.exe に渡すコマンド (95・97 の pwsh_command と同じ形)。$1 はスクリプトに渡す引数 (" -Check" など)。
# 呼ぶ前に $LASTEXITCODE を 2 にしておく。スクリプトが exit まで届かずに終わったときに、中で打った
# 外部コマンドの 0 を返して成功に見せないため。${quoted} は呼ぶ側 (install_powertoys) の local を読む
pwsh_command() {
  echo "[Console]::OutputEncoding = [Text.Encoding]::UTF8; \$global:LASTEXITCODE = 2; & '${quoted}'$1; exit \$LASTEXITCODE"
}

# PowerToys が入っていなければ、Install-PowerToys.ps1 -IfMissing で入れる (docs/adr/017_win_apps_winget_*)。
# 入っているかは -Check (PowerToys.exe があるか) で見る。何があっても 0 を返し、読み直しへ進む
install_powertoys() {
  local deployed="${windows_home}/.config/powershell/Install-PowerToys.ps1"
  local win_script quoted rc out header=0
  if [[ -z ${windows_home} || ! -f ${deployed} ]]; then
    echo "Install-PowerToys.ps1 がまだ配られていません (${deployed})。PowerToys が入っているかは確かめずに進みます。"
    return 0
  fi
  if ! command -v pwsh.exe &>/dev/null; then
    warn "pwsh.exe が見つかりません (PowerShell 7 が無いか、WSL の PATH に Windows の PATH が入っていない)。PowerToys が入っているかを確かめられません。" \
      "$(install_manual)"
    return 0
  fi
  if ! win_script=$(wslpath -w "${deployed}" 2>/dev/null) || [[ -z ${win_script} ]]; then
    warn "Install-PowerToys.ps1 の場所を Windows のパスに直せませんでした: ${deployed}" "$(install_manual)"
    return 0
  fi
  quoted=${win_script//\'/\'\'}
  rc=0
  out=$(timeout 60 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -Check")" </dev/null 2>&1) || rc=$?
  out=$(printf '%s\n' "${out}" | clean)
  # 入っていないときの出力には、状態の表の見出し (パッケージ名) が必ず入る。
  # 3 でも見出しが無ければ、スクリプトが動いていない (入っていないとは扱わない)
  if grep -qF 'Microsoft.PowerToys' <<<"${out}"; then
    header=1
  fi
  if ((rc == 0)); then
    echo "PowerToys は入っています。"
    return 0
  fi
  if ((rc == 3 && header)); then
    echo "Windows に PowerToys が入っていないので、winget で入れます (Install-PowerToys.ps1 -IfMissing。user スコープ。600 秒まで待ちます)。"
    # installer のダウンロードを待つので長めに待つ
    rc=0
    out=$(timeout 600 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -IfMissing")" </dev/null 2>&1) || rc=$?
    out=$(printf '%s\n' "${out}" | clean)
    if ((rc == 0)); then
      printf '%s\n' "${out}" | sed 's/^/  /'
      echo "Windows に PowerToys を入れました。動いていなければ、スタートメニューから PowerToys を起動してください。"
      return 0
    fi
    if ((rc == 124)); then
      warn_frame "Windows に PowerToys を入れられませんでした (600 秒待っても終わらない。Windows 側でまだ入れている途中かもしれません)" "${out}"
      return 0
    fi
    warn_frame "Windows に PowerToys を入れられませんでした (終了コード ${rc})" "${out}"
    return 0
  fi
  local headline
  if ((rc == 124)); then
    headline="pwsh.exe が 60 秒たっても終わりませんでした (時間切れ。WSL の interop が止まっているかもしれません):"
  else
    headline="pwsh.exe で PowerToys が入っているかを確かめられませんでした (終了コード ${rc}。WSL の interop が落ちているかもしれません):"
  fi
  # pwsh.exe の出力 (あれば) と、手で打つコマンドを続きの行にする
  warn "${headline}" ${out:+"${out}"} "$(install_manual)"
  return 0
}

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
windows_home=$(jq -r '.windowsHome // ""' "${state_file}")

install_powertoys

km_dir="${windows_home}/AppData/Local/Microsoft/PowerToys/Keyboard Manager"
default_json="${km_dir}/default.json"
if [[ -z ${windows_home} || ! -f ${default_json} ]]; then
  echo "Keyboard Manager の default.json がまだありません (${default_json})。この手順は飛ばします。"
  exit 0
fi

# エンジンは settings.json の有効なプロファイルの名前を読み、その名前の JSON を読む (settings.json が無ければ
# 何も読まない)。default でなければ、送っても配った default.json は読まれないので、記録もイベントも触らずに
# 案内する (記録すると、次の回から「読み直し済み」で送らなくなる)
settings_json="${km_dir}/settings.json"
active=$(jq -r '.properties.activeConfiguration.value // empty' "${settings_json}" 2>/dev/null) || active=""
if [[ -z ${active} ]]; then
  warn "Keyboard Manager の設定 (settings.json) がまだ無いので、配った default.json は読まれません (${settings_json} が無いか、読めない)。" \
    "PowerToys の設定画面を一度開いてから、setup --update (か ${script_dir}/bootstrap-windows-powertoys.sh) を流し直してください。"
  exit 0
fi
if [[ ${active} != default ]]; then
  warn "Keyboard Manager の有効なプロファイルが default ではありません (${active})。配った default.json は読まれません。PowerToys の設定で、プロファイルを default に戻してください (${settings_json} の activeConfiguration)。"
  exit 0
fi

sum=$(sha256sum <"${default_json}" | cut -d' ' -f1)
if ((! force)) && [[ -r ${record_file} && $(head -n 1 "${record_file}") == "${sum}" ]]; then
  echo "Keyboard Manager は、今の default.json を読み直し済みです。"
  exit 0
fi

# PowerShell に渡すコマンド。イベントがあれば Set() して set、無ければ absent を出す
ps="\$h = \$null; if ([System.Threading.EventWaitHandle]::TryOpenExisting('${event}', [ref]\$h)) { [void]\$h.Set(); \$h.Dispose(); 'set' } else { 'absent' }"

rc=0
out=$(timeout 60 powershell.exe -NoProfile -NonInteractive -Command "${ps}" </dev/null 2>&1) || rc=$?
out=$(printf '%s\n' "${out}" | tr -d '\r')

remember() {
  mkdir -p "$(dirname -- "${record_file}")"
  printf '%s\n' "${sum}" >"${record_file}"
}

if ((rc == 0)) && [[ ${out} == set ]]; then
  remember
  echo "Keyboard Manager に default.json を読み直させました。"
  exit 0
fi
if ((rc == 0)) && [[ ${out} == absent ]]; then
  remember
  echo "PowerToys (Keyboard Manager) が動いていません。起動したときに今の default.json を読みます。"
  exit 0
fi
# powershell.exe の出力 (あれば) と、手で読み直す方法を続きの行にする
warn "powershell.exe で Keyboard Manager に読み直させられませんでした (終了コード ${rc}。WSL の interop が落ちているかもしれません):" \
  ${out:+"${out}"} "$(manual)"
exit 0
