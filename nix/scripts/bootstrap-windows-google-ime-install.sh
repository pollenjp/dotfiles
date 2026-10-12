#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows の Google 日本語入力 (winget の Google.JapaneseIME) が、dotfiles で固定した版に揃っているかを確かめる。
# 冪等。`setup.sh --update` でも毎回走る。入っていなければ winget で入れ (Windows に UAC の確認が出る)、
# 入っていて揃っていなければ ⚠ で囲んで知らせる (上げはしない)。
#
# order: 95
#
# ^ setup.sh が読む実行順。bootstrap-windows-files.sh (order: 90) が Install-GoogleJapaneseInput.ps1 を
#   置いた後、設定と辞書を置く bootstrap-windows-google-ime.sh (order: 98) より前に走らせる。
#   bootstrap-windows-powershell-profile.sh も 95 で、同じ値は辞書順なのでこちらが先に走る
#   (どちらも相手を使わない)。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# Windows の Google 日本語入力は winget の Google.JapaneseIME で入れ、版は
# win/google-japanese-input/Install-GoogleJapaneseInput.ps1 の -Version の既定値で固定する
# (win/README.md の「Google 日本語入力を入れる」、docs/adr/016_win_apps_winget_*)。
# 設定 (bootstrap-windows-google-ime.sh が置く) を読み書きできると確かめた版に留めるため、
# 自分で上がったときも気付けるよう、setup のたびに差を確かめて見せる。新しいマシンでは入れるところまでする。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json (home-manager が置く) を読み、配らない
#    マシンなら飛ばす。<windowsHome>/.config/powershell/Install-GoogleJapaneseInput.ps1 が無いときも飛ばす
# 2. pwsh.exe で Install-GoogleJapaneseInput.ps1 -Check を流す (何も変えない)。
#    WSL の interop を通るので、落ちていたら手で打つコマンドを出して飛ばす (exit 0)
# 3. 終了コード 0 なら 1 行だけ出す。1 なら ⚠ で囲んだ注意と状態の表と揃えるコマンドを出す
#    (入っている版の方が新しい・固定した版が winget に無い・入っている版が読めないときは、打っても
#    直らないので、揃えるコマンドの代わりに repo の版の上げ方・直し方・確かめ方を出す)。
#    3 (入っていない) なら Install-GoogleJapaneseInput.ps1 -IfMissing で入れる。machine スコープの MSI
#    なので Windows に UAC の確認が出る (その場にいて押せるはずの、新しいマシンで起きる)。どれも exit 0
#
# 上げる (入れ替える) のは setup からはしない。日本語入力は全部のアプリに読み込まれていて、入れ替えると
# アプリや Windows の再起動が要ることがあるため。--apply を付けて手で流すと、-Check を付けずに流して揃える
# (bootstrap-windows-openssh.sh と同じ。差があれば UAC の確認が出る)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
Windows の Google 日本語入力 (winget の Google.JapaneseIME) が、dotfiles で固定した版に揃っているかを確かめる。

使い方:
  bootstrap-windows-google-ime-install.sh            確かめる (入っていなければ入れる。差があれば ⚠ で知らせる)
  bootstrap-windows-google-ime-install.sh --apply    揃える (上げるときは Windows に UAC の確認が出る)
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
  echo "     Install-GoogleJapaneseInput -Check" >&2
}

# jq が無くても setup は止めない (この手順は知らない引数の 2 以外で 0 以外を返さない)
if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。この手順は飛ばします。" >&2
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
deployed="${windows_home}/.config/powershell/Install-GoogleJapaneseInput.ps1"
if [[ -z ${windows_home} || ! -f ${deployed} ]]; then
  echo "Install-GoogleJapaneseInput.ps1 がまだ配られていません (${deployed})。この手順は飛ばします。"
  exit 0
fi

if ! command -v pwsh.exe &>/dev/null; then
  echo "!! pwsh.exe が見つかりません (PowerShell 7 が無いか、WSL の PATH に Windows の PATH が入っていない)。" >&2
  manual
  exit 0
fi
if ! win_script=$(wslpath -w "${deployed}" 2>/dev/null) || [[ -z ${win_script} ]]; then
  echo "!! Install-GoogleJapaneseInput.ps1 の場所を Windows のパスに直せませんでした: ${deployed}" >&2
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
    # PowerShell の締めの 1 行 (⚠️ … → Install-GoogleJapaneseInput …) は、下の揃えるコマンドと重なるので落とす
    printf '%s\n' "$2" | grep -v '^⚠️ ' | sed 's/^/    /' || true
    if grep -qF '(下げない)' <<<"$2"; then
      # 入っている版の方が新しい: 揃えるコマンドを打っても下げないので、repo の版の上げ方だけを出す
      printf '%s⚠️  入っている版の方が新しいので、下げはしません。上の ※ のとおり、repo の版 (Install-GoogleJapaneseInput.ps1 の -Version) を上げてください%s\n' "${c_warn}" "${c_reset}"
    elif grep -qF 'winget show --versions に無い' <<<"$2"; then
      # 固定した版が winget に無い: 揃えるコマンドを打っても入れられないので、repo の版の直し方だけを出す
      printf '%s⚠️  固定した版が winget に無いので、入れることも上げることもできません。repo の版 (Install-GoogleJapaneseInput.ps1 の -Version) を winget show --id Google.JapaneseIME --versions にある版へ変えてください%s\n' "${c_warn}" "${c_reset}"
    elif grep -qF '比べられない' <<<"$2"; then
      # 入っている版が読めない: 揃えるコマンドは何もしないので、確かめ方だけを出す
      printf '%s⚠️  入っている版が読めないので、揃えられません。上の ※ のとおり、PowerShell で winget list --id Google.JapaneseIME を打って入っている版を確かめてください%s\n' "${c_warn}" "${c_reset}"
    else
      printf '%s⚠️  揃えるには次のどちらかを打つ (入れる・上げるときは Windows に UAC の確認が出ます。上げる前に、日本語入力を使っているアプリをできるだけ閉じる):%s\n' "${c_warn}" "${c_reset}"
      printf '%s⚠️    WSL:        %s/bootstrap-windows-google-ime-install.sh --apply%s\n' "${c_warn}" "${script_dir}" "${c_reset}"
      printf '%s⚠️    PowerShell: Install-GoogleJapaneseInput%s\n' "${c_warn}" "${c_reset}"
    fi
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
  } >&2
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
if grep -qF 'Google.JapaneseIME' <<<"${out}"; then
  header=1
fi

if ((rc == 0)); then
  echo "Windows の Google 日本語入力は、dotfiles で固定した版に揃っています。"
  # winget に新しい版がある、などの ※ の行は、揃っていても見せる (ずれではないので枠には入れない)
  grep '^※' <<<"${out}" | sed 's/^/  /' || true
  exit 0
fi
if ((rc == 1 && header)); then
  warn_frame "Windows の Google 日本語入力が、dotfiles で固定した版と揃っていません" "${out}"
  exit 0
fi
if ((rc == 3 && header)); then
  echo "Windows に Google 日本語入力が入っていないので、winget で固定した版を入れます (Install-GoogleJapaneseInput.ps1 -IfMissing)。"
  echo "Windows のデスクトップに UAC の確認が出たら「はい」を押してください (600 秒まで待ちます)。"
  # MSI のダウンロードと、UAC を押すのを待つので長めに待つ
  rc=0
  out=$(timeout 600 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -IfMissing")" </dev/null 2>&1) || rc=$?
  out=$(printf '%s\n' "${out}" | clean)
  if ((rc == 0)); then
    printf '%s\n' "${out}" | sed 's/^/  /'
    echo "Windows に Google 日本語入力を入れました。"
    echo "Google 日本語入力で一度何か打ってから、setup --update を流し直してください (bootstrap-windows-google-ime.sh が設定と辞書を置きます)。"
    exit 0
  fi
  if ((rc == 124)); then
    warn_frame "Windows に Google 日本語入力を入れられませんでした (600 秒待っても終わらない。UAC の確認が出たままかもしれません)" "${out}"
    exit 0
  fi
  warn_frame "Windows に Google 日本語入力を入れられませんでした (終了コード ${rc})" "${out}"
  exit 0
fi
echo "!! pwsh.exe で Windows の Google 日本語入力を確かめられませんでした (終了コード ${rc}。WSL の interop が落ちているかもしれません):" >&2
if [[ -n ${out} ]]; then
  printf '%s\n' "${out}" | sed 's/^/   /' >&2
fi
manual
exit 0
