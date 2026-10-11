#!/usr/bin/env bash
# shellcheck shell=bash
#
# win/ から配った PowerToys の Keyboard Manager の割り当て (default.json) を、Keyboard Manager に読み直させる。
# 冪等。`setup.sh --update` でも毎回走る。
#
# order: 91
#
# ^ setup.sh が読む実行順。bootstrap-windows-files.sh (order: 90) が default.json を置いた後に
#   走らせる。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# Keyboard Manager のエンジンは、起動したときと、名前付きイベント
# PowerToys_KeyboardManager_Event_Settings を受けたときにしか default.json を読まない
# (docs/adr/015_win_google_ime_powertoys_*)。win/ の割り当てを配っても、そのままでは効かない。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json を読み、配らないマシンなら飛ばす。
#    <windowsHome>/AppData/Local/Microsoft/PowerToys/Keyboard Manager/default.json が無いときも飛ばす
# 2. default.json の sha256 が、前回読み直させたときの記録
#    (~/.local/state/dotfiles/powertoys-keyboard-manager.reloaded) と同じなら何もしない (--force なら比べない)
# 3. powershell.exe でイベントを送る。送れたら記録する。イベントが無い (PowerToys が動いていない) ときも
#    記録する (起動したときに読むため)。interop が使えなければ手で読み直す方法を出し、記録しない
#
# どの場合も exit 0 (後ろの手順を止めない)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
win/ から配った PowerToys の Keyboard Manager の割り当て (default.json) を、Keyboard Manager に読み直させる。

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

state_file="${HOME}/.local/state/dotfiles/windows-files.json"
record_file="${HOME}/.local/state/dotfiles/powertoys-keyboard-manager.reloaded"
event=PowerToys_KeyboardManager_Event_Settings

manual() {
  echo "   PowerToys の設定 → Keyboard Manager を一度オフにしてオンに戻すと、読み直します。" >&2
}

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
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
default_json="${windows_home}/AppData/Local/Microsoft/PowerToys/Keyboard Manager/default.json"
if [[ -z ${windows_home} || ! -f ${default_json} ]]; then
  echo "Keyboard Manager の default.json がまだありません (${default_json})。この手順は飛ばします。"
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
echo "!! powershell.exe で Keyboard Manager に読み直させられませんでした (終了コード ${rc}。WSL の interop が落ちているかもしれません):" >&2
if [[ -n ${out} ]]; then
  printf '%s\n' "${out}" | sed 's/^/   /' >&2
fi
manual
exit 0
