#!/usr/bin/env bash
# shellcheck shell=bash
#
# win/ から配った PowerToys の Keyboard Manager の割り当て (default.json) を効かせる。Keyboard Manager と自動起動を
# オンにし、Keyboard Manager に default.json を読み直させる。
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
# (dotfiles-private の docs/adr/015_win_google_ime_powertoys_*)。win/ の割り当てを配っても、そのままでは効かない。
# 新しいマシンでは PowerToys そのものが入っていないので、読み直させる前に入れる (dotfiles-private の docs/adr/017_win_apps_winget_*)。
# エンジンが読むのは、同じディレクトリの settings.json が指す有効なプロファイルの JSON で、settings.json が
# 無ければ何も読まない。settings.json を作るのは PowerToys の設定画面だけで、作っても読み直させはしないので、
# 入れたばかりで設定画面を開いていないマシンでは、イベントを送っても default.json は読まれない
# (dotfiles-private の docs/adr/017_win_apps_winget_* の §1 の 7)。
# Keyboard Manager は PowerToys の既定でオフで、オフだとエンジンが起動しないので、割り当てを配っても読み直させても
# 効かない。自動起動も、入れたばかりのマシンではオフで、サインインしても PowerToys が動かない。どちらも
# ここでオンにする (dotfiles-private の docs/adr/041_*)。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json を読み、配らないマシンなら飛ばす
# 2. pwsh.exe で <windowsHome>/.config/powershell/Install-PowerToys.ps1 -Check を流し、3 (入っていない) なら
#    -IfMissing で入れる (user スコープ。管理者は要らない)。版は固定しないので、入っていれば何もしない。
#    スクリプトが無い・interop が使えない・入れられないときは、知らせて 3 へ進む
# 3. <windowsHome>/AppData/Local/Microsoft/PowerToys/Keyboard Manager/default.json が無ければ飛ばす
# 4. 全体の設定 <windowsHome>/AppData/Local/Microsoft/PowerToys/settings.json の enabled["Keyboard Manager"] と
#    startup を見る。両方 true なら何もしない (setup のたびに起動し直さない)。どちらかが true でなければ、
#    PowerToys を止める → 両方を true にする (ほかの項目は変えない。ファイルが無ければ 2 つだけで作る) →
#    起動する → 確かめる。runner はこのファイルを起動したときに読み、動いている間に書いても効かないので、
#    この順にする。できないとき (run_elevated が true・止められない・書けない・起動できない) は知らせて、
#    設定画面で 2 つをオンにする手順を出す。Keyboard Manager がオフのままなら、記録もイベントも触らずに終わる。
#    記録すると、オンにした後の回で「読み直し済み」で送らなくなるため。書いた後に起動や確認でつまずいたら印
#    (~/.local/state/dotfiles/powertoys-enable.pending) を残し、次の回は両方 true でも起動と確認をやり直す
# 5. 同じディレクトリ (Keyboard Manager の下) の settings.json の有効なプロファイル
#    (properties.activeConfiguration.value) が default でなければ、記録もイベントも触らずに案内して飛ばす
#    (無い・読めないときは設定画面を一度開いてから流し直すよう、default 以外のときは default に戻すよう出す)。
#    入れた直後と起動した直後は、設定画面 (最初の起動で開く) が作るのを 30 秒まで待ってから見る。待つときは
#    記録を消す (エンジンはこのファイルが無い間に起動すると何も読まないので、できた後に必ず送る)
# 6. default.json の sha256 が、前回読み直させたときの記録
#    (~/.local/state/dotfiles/powertoys-keyboard-manager.reloaded) と同じなら何もしない (--force なら比べない)
# 7. powershell.exe でイベントを送る。送れたら記録する。イベントが無い (PowerToys が動いていない) ときも
#    記録する (起動したときに読むため)。interop が使えなければ手で読み直す方法を出し、記録しない
#
# どの場合も exit 0 (後ろの手順を止めない)。知らない引数だけ exit 2。知らせたこと (⚠ の枠は見出しと
# 入れるコマンド) は、setup の最後の「警告のまとめ」にも残す (warn / summary_warn)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
win/ から配った PowerToys の Keyboard Manager の割り当て (default.json) を効かせる。
PowerToys が入っていなければ、先に winget で入れる。Keyboard Manager か自動起動がオフなら、オンにして
PowerToys を起動し直す (数秒止まる)。そのうえで Keyboard Manager に default.json を読み直させる。

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
# 全体の設定に書いた後、起動と確認がまだ済んでいない印。あれば、次の回は両方 true でも起動と確認をやり直す
pending_file="${HOME}/.local/state/dotfiles/powertoys-enable.pending"
event=PowerToys_KeyboardManager_Event_Settings
# 入れた (-IfMissing が通った)・起動し直したか。設定画面が Keyboard Manager の settings.json を作るのを待つかを決める
installed_now=0
restarted=0
# Keyboard Manager がオンで、読み直しへ進んでよいか (ensure_enabled が決める)
km_usable=1

# run_ps で流す PowerShell のコマンド。出力は決まった語だけにする (パスなどを受け取らない。powershell.exe の出力は
# Windows のコードページで来るので日本語が化ける)

# 共通の関数と、PowerToys.exe を探すところ (Install-PowerToys.ps1 と同じ順: user スコープ、machine スコープ)。無ければ no-exe で
# 終わる。プロセスは今のセッションのものだけを見る (ほかのユーザーの PowerToys を数えない・止めようとしない)
ps_common=$(
  cat <<'EOS'
$session = (Get-Process -Id $PID).SessionId
function Get-Mine($name) { Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session } }
function Wait-Gone($name, $seconds) {
  $end = (Get-Date).AddSeconds($seconds)
  while ((Get-Mine $name) -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 200 }
}
$exe = @((Join-Path $env:LOCALAPPDATA 'PowerToys\PowerToys.exe'), (Join-Path $env:ProgramFiles 'PowerToys\PowerToys.exe')) |
  Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $exe) { 'no-exe'; exit 0 }
EOS
)
# PowerToys を止める。runner のトレイのウィンドウ (PToyTrayIconWindow) に WM_CLOSE を送ると、トレイの「終了」と同じく、
# トレイアイコンを消し、設定画面とモジュールを閉じてから終わる。送れない・終わらなければ強制で止める。管理者で動いて
# いると、どちらも効かず still-running になる。/F なしの taskkill は使わない (先頭のウィンドウにしか送らないので、
# runner が持つ Mouse Highlighter などの隠れたウィンドウだけが閉じ、SUCCESS と返って runner は残る)。
# エンジンなどのモジュールも 5 秒まで終わるのを待つ (残っていると、新しい runner が起こしたものが二重起動の印を見て終わるため。
# Hosts のエディタなど runner と別に開いたものは残りうるので、残っていても進む)。エンジンだけは、残っていれば強制で止める
# (古いエンジンのイベントを見て、新しいエンジンが動いたと取り違えないため)
ps_stop="${ps_common}
$(
  cat <<'EOS'
if (-not (Get-Mine 'PowerToys')) { 'not-running'; exit 0 }
Add-Type -Namespace Dotfiles -Name User32 -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wparam, IntPtr lparam);
'@
$w = [Dotfiles.User32]::FindWindow('PToyTrayIconWindow', [NullString]::Value)
if ($w -ne [IntPtr]::Zero -and [Dotfiles.User32]::PostMessage($w, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) { Wait-Gone 'PowerToys' 20 }
if (Get-Mine 'PowerToys') {
  Get-Mine 'PowerToys' | Stop-Process -Force -ErrorAction SilentlyContinue
  Wait-Gone 'PowerToys' 10
}
if (Get-Mine 'PowerToys') { 'still-running'; exit 0 }
Wait-Gone 'PowerToys.*' 5
Get-Mine 'PowerToys.KeyboardManagerEngine' | Stop-Process -Force -ErrorAction SilentlyContinue
Wait-Gone 'PowerToys.KeyboardManagerEngine' 3
'stopped'
EOS
)"
# PowerToys を起動する。動いていれば何もしない (2 つ目の PowerToys.exe は設定画面を開いて終わるため)。Start-Process は
# ShellExecute なので、stdout を引き継がず ($(...) や timeout が返らなくならない)、script の後も残る
ps_start="${ps_common}
$(
  cat <<'EOS'
if (Get-Mine 'PowerToys') { 'running'; exit 0 }
Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe)
'started'
EOS
)"
# 起動した Keyboard Manager のエンジンがイベントを作るのを待つ (エンジンは default.json を読んでからイベントを作る)。
# $name は呼ぶ側で入れる。runner はエンジンを起こす前に自動起動のタスクを作るので、ここでタスクも見る
ps_wait_km=$(
  cat <<'EOS'
$end = (Get-Date).AddSeconds(30)
$state = 'absent'
while ($true) {
  $h = $null
  if ([System.Threading.EventWaitHandle]::TryOpenExisting($name, [ref]$h)) { $h.Dispose(); $state = 'ready'; break }
  if ((Get-Date) -ge $end) { break }
  Start-Sleep -Milliseconds 500
}
$task = if (Get-ScheduledTask -TaskPath '\PowerToys\' -ErrorAction SilentlyContinue) { 'task' } else { 'no-task' }
$state + ' ' + $task
EOS
)

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

# Keyboard Manager と自動起動を手でオンにする手順 (warn の続きの行にする)。文言は日本語の設定画面に合わせている
enable_manual() {
  echo "PowerToys の設定画面で 2 つをオンにしてください: 「入出力」→「Keyboard Manager」、「全般」→「起動時に実行」(Run at startup)。"
  echo "オンにしたら、setup --update (か ${script_dir}/bootstrap-windows-powertoys.sh) を流し直してください。配った割り当てを読み直させます。"
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

# PowerToys が入っていなければ、Install-PowerToys.ps1 -IfMissing で入れる (dotfiles-private の docs/adr/017_win_apps_winget_*)。
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
      echo "Windows に PowerToys を入れました。"
      installed_now=1
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

# powershell.exe でコマンドを流す。$1: 上限の秒数、$2: コマンド。出力 (CR は落とす) を ps_out に、終了コードを ps_rc に入れる
run_ps() {
  ps_rc=0
  ps_out=$(timeout "$1" powershell.exe -NoProfile -NonInteractive -Command "\$ProgressPreference = 'SilentlyContinue'; $2" </dev/null 2>&1) || ps_rc=$?
  ps_out=$(printf '%s\n' "${ps_out}" | tr -d '\r')
}

# 全体の設定の 3 つを km_enabled・startup_enabled・run_elevated に入れる (true か false)。ファイルが無ければ全部 false。
# 読めない (JSON でない・空のファイル) ときは全部 false にして 1 を返す
read_global() {
  local state
  km_enabled=false
  startup_enabled=false
  run_elevated=false
  [[ -e ${global_json} ]] || return 0
  state=$(jq -r '[.enabled["Keyboard Manager"] == true, .startup == true, .run_elevated == true] | map(tostring) | join(" ")' "${global_json}" 2>/dev/null) || return 1
  [[ -n ${state} ]] || return 1
  read -r km_enabled startup_enabled run_elevated <<<"${state}"
}

# read_global を 5 回まで打つ。設定画面が同じファイルを書いている途中に当たっても読めるように
read_global_retry() {
  local i
  for ((i = 0; i < 5; i++)); do
    if read_global; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# 全体の設定の 2 つを true にする。ほかの項目はそのまま (runner が書く形に合わせて、1 行で末尾に改行なし)。読みかけを
# 見せないよう、隣に書いてから置き換える。ファイルが無ければ 2 つだけで作る (runner は無い項目を既定値で読み、
# 設定画面が起動したときに全部書く)
write_global() {
  local tmp="${global_json}.dotfiles-tmp" filter='.startup = true | .enabled["Keyboard Manager"] = true'
  if [[ -e ${global_json} ]]; then
    jq -cj "${filter}" "${global_json}" >"${tmp}" 2>/dev/null && mv -f -- "${tmp}" "${global_json}" 2>/dev/null && return 0
  else
    jq -ncj "{} | ${filter}" >"${tmp}" 2>/dev/null && mv -f -- "${tmp}" "${global_json}" 2>/dev/null && return 0
  fi
  rm -f -- "${tmp}" 2>/dev/null || true
  return 1
}

# km_enabled・startup_enabled のうちオフのものの名前。文の頭か「、」の後ろに置く (Keyboard Manager だけなら、続く助詞との間に空白を入れる)
off_names() {
  if [[ ${km_enabled} != true && ${startup_enabled} != true ]]; then
    echo "Keyboard Manager と自動起動"
  elif [[ ${km_enabled} != true ]]; then
    echo "Keyboard Manager "
  else
    echo "自動起動"
  fi
}

# オンにできなかったときに知らせる (引数は warn と同じ)。Keyboard Manager がオフのままなら読み直しへ進まない。
# 進むと、読まれないのに「読み直し済み」「起動したときに読みます」と出し、記録してしまう
give_up() {
  warn "$@"
  [[ ${km_before} == true ]] || km_usable=0
}

# Keyboard Manager と自動起動がオンかを見て、オフならオンにして PowerToys を起動し直す。何があっても 0 を返す。
# runner は全体の設定を起動したときに読み、動いている間に書いても効かないので、止める → 書く → 起動する、の順にする。
# 止めた後は、どの枝でも起動する (止めたままにしない。動いていれば起動のコマンドは何もしない)
ensure_enabled() {
  local offs stop_rc stop_out
  km_before=false
  if ! read_global_retry; then
    give_up "PowerToys の全体の設定を読めないので、Keyboard Manager と自動起動がオンかを確かめられません (${global_json})。" "$(enable_manual)"
    return 0
  fi
  if [[ ${km_enabled} == true && ${startup_enabled} == true ]]; then
    # 前の回が書いた後に起動や確認でつまずいていれば、確かめ直す。確かめるまでは、読み直しへ進まない (km_before は false のまま)
    if [[ -e ${pending_file} && ${run_elevated} != true ]]; then
      echo "前の回は PowerToys の起動を確かめられなかったので、確かめ直します。"
      start_and_confirm "Keyboard Manager と自動起動" "Keyboard Manager と自動起動がオンで、PowerToys が動いていることを確かめました。"
    fi
    return 0
  fi
  km_before=${km_enabled}
  offs=$(off_names)
  if [[ ${run_elevated} == true ]]; then
    give_up "PowerToys が管理者として実行する設定 (run_elevated) なので、${offs}をオンにしません (起動すると UAC の確認が出るため)。" "$(enable_manual)"
    return 0
  fi

  echo "${offs}がオフです。オンにして、PowerToys を起動し直します (数秒止まります。設定画面を開いていれば閉じます)。"
  run_ps 60 "${ps_stop}"
  stop_rc=${ps_rc}
  stop_out=${ps_out}
  case "${stop_rc}:${stop_out}" in
    0:stopped | 0:not-running) ;;
    0:no-exe)
      give_up "PowerToys が見つからないので、${offs}をオンにできませんでした。" "$(install_manual)"
      return 0
      ;;
    0:still-running)
      run_ps 60 "${ps_start}"
      give_up "PowerToys を止められないので、${offs}をオンにできませんでした (管理者として動いているかもしれません)。" "$(enable_manual)"
      return 0
      ;;
    *)
      # 止める途中で時間切れになったかもしれない
      run_ps 60 "${ps_start}"
      give_up "powershell.exe で PowerToys を止められないので、${offs}をオンにできませんでした (終了コード ${stop_rc}。WSL の interop が落ちているかもしれません):" \
        ${stop_out:+"${stop_out}"} "$(enable_manual)"
      return 0
      ;;
  esac

  touch -- "${pending_file}" 2>/dev/null || true
  if ! write_global; then
    rm -f -- "${pending_file}" 2>/dev/null || true
    run_ps 60 "${ps_start}"
    give_up "全体の設定に書けないので、${offs}をオンにできませんでした (${global_json})。" "$(enable_manual)"
    return 0
  fi
  start_and_confirm "${offs}" "${offs}をオンにして、PowerToys を起動しました。"
}

# PowerToys を起動して確かめる。$1: オンにするものの名前 (つまずいたときの文に使う)、$2: 確かめられたときの文。確かめられたら印を消す。
# つまずいたら印を残すので、次の回がやり直す (全体の設定はもう両方 true なので、印が無いと素通りする)
start_and_confirm() {
  local offs=$1 done_message=$2 wait_out
  run_ps 60 "${ps_start}"
  case "${ps_rc}:${ps_out}" in
    0:started | 0:running) ;;
    *)
      give_up "PowerToys を起動できませんでした (終了コード ${ps_rc})。設定には書いたので、スタートメニューから起動すると、${offs}がオンになります:" \
        ${ps_out:+"${ps_out}"}
      return 0
      ;;
  esac
  restarted=1

  run_ps 60 "\$name = '${event}'; ${ps_wait_km}"
  case "${ps_rc}:${ps_out}" in
    "0:ready task" | "0:ready no-task") ;;
    "0:absent "*)
      give_up "PowerToys を起動しましたが、Keyboard Manager のエンジンが 30 秒たっても動いていません。" "$(enable_manual)"
      return 0
      ;;
    *)
      give_up "PowerToys を起動しましたが、Keyboard Manager のエンジンが動いたかを確かめられませんでした (終了コード ${ps_rc}。WSL の interop が落ちているかもしれません):" \
        ${ps_out:+"${ps_out}"} "$(enable_manual)"
      return 0
      ;;
  esac
  wait_out=${ps_out}

  # 読み直して確かめる。読めなければ km_enabled・startup_enabled は false のまま
  read_global_retry || true
  if [[ ${km_enabled} != true || ${startup_enabled} != true ]]; then
    km_before=${km_enabled}
    give_up "PowerToys を起動しましたが、$(off_names)が全体の設定でオンになっていません (${global_json})。" "$(enable_manual)"
    return 0
  fi
  if [[ ${wait_out} == "ready no-task" ]]; then
    km_before=true
    warn "PowerToys を起動しましたが、自動起動のタスクがありません (タスク スケジューラの \\PowerToys)。サインインしても PowerToys が動かないかもしれません。" "$(enable_manual)"
    return 0
  fi
  rm -f -- "${pending_file}" 2>/dev/null || true
  echo "${done_message}"
}

# Keyboard Manager の settings.json の有効なプロファイルの名前。無い・読めない・書きかけなら空
km_active() {
  jq -r '.properties.activeConfiguration.value // empty' "${settings_json}" 2>/dev/null || true
}

# Keyboard Manager の settings.json を作るのは設定画面で、最初の起動で開く。PowerToys を入れた直後・起動した直後なら、
# できるのを少し待つ (止めると開きかけの設定画面も閉じ、次の起動では開かないので、入れた直後は止める前にも待つ)。
# エンジンはこのファイルが無い間に起動すると何も読まず、できても読み直さないので、記録を消して、できた後に必ず送る
wait_km_settings() {
  local i
  [[ -z $(km_active) ]] || return 0
  rm -f -- "${record_file}" 2>/dev/null || true
  echo "PowerToys の最初の起動が Keyboard Manager の settings.json を作るのを待ちます (30 秒まで)。"
  for ((i = 0; i < 30; i++)); do
    sleep 1
    [[ -z $(km_active) ]] || return 0
  done
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

settings_json="${km_dir}/settings.json"
global_json="${windows_home}/AppData/Local/Microsoft/PowerToys/settings.json"

if ((installed_now)); then
  wait_km_settings
fi
ensure_enabled
if ((! km_usable)); then
  exit 0
fi
if ((restarted)); then
  wait_km_settings
fi

# エンジンは settings.json の有効なプロファイルの名前を読み、その名前の JSON を読む (settings.json が無ければ
# 何も読まない)。default でなければ、送っても配った default.json は読まれないので、記録もイベントも触らずに
# 案内する (記録すると、次の回から「読み直し済み」で送らなくなる)
active=$(km_active)
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

run_ps 60 "${ps}"

remember() {
  mkdir -p "$(dirname -- "${record_file}")"
  printf '%s\n' "${sum}" >"${record_file}"
}

if ((ps_rc == 0)) && [[ ${ps_out} == set ]]; then
  remember
  echo "Keyboard Manager に default.json を読み直させました。"
  exit 0
fi
if ((ps_rc == 0)) && [[ ${ps_out} == absent ]]; then
  remember
  echo "PowerToys (Keyboard Manager) が動いていません。起動したときに今の default.json を読みます。"
  exit 0
fi
# powershell.exe の出力 (あれば) と、手で読み直す方法を続きの行にする
warn "powershell.exe で Keyboard Manager に読み直させられませんでした (終了コード ${ps_rc}。WSL の interop が落ちているかもしれません):" \
  ${ps_out:+"${ps_out}"} "$(manual)"
exit 0
