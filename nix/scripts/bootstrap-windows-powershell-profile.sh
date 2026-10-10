#!/usr/bin/env bash
# shellcheck shell=bash
#
# win/ から配った PowerShell の共有設定 (dotfiles.ps1) を、PowerShell 7 の $PROFILE から読ませる。
# 冪等。`setup.sh --update` でも毎回走る。
#
# order: 95
#
# ^ setup.sh が読む実行順。bootstrap-windows-files.sh (order: 90) が dotfiles.ps1 を置いた
#   後に走らせる。あちらが衝突で失敗すると setup はそこで止まり、これは走らない
#   (衝突を解いて流し直す)。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# win/powershell/dotfiles.ps1 (herdr の alias など) は %USERPROFILE%\.config\powershell\ へ
# 配るが、PowerShell が自分で読むのは $PROFILE だけ。$PROFILE はドキュメントの下にあり、
# ドキュメントの位置は OneDrive の設定でマシンごとに変わる (この PC では OneDrive\ドキュメント)
# ので、manifest の dst には書けない。そこで $PROFILE に読み込みの 1 行を足す
# (win/README.md の「PowerShell」)。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json (home-manager が置く) を読み、配らない
#    マシンなら飛ばす。<windowsHome>/.config/powershell/dotfiles.ps1 が無いときも飛ばす
# 2. pwsh.exe に $PROFILE (CurrentUserCurrentHost) の場所を聞き、wslpath で /mnt/c の
#    パスにする。WSL の interop を通るので、落ちていたら手で打つコマンドを出して飛ばす
#    (exit 0)。ファイルを配る経路 (bootstrap-windows-files.sh) には exe を挟まない (ADR 010)
# 3. $PROFILE に dotfiles.ps1 を読む行があれば何もしない。無ければ 1 行足して記録する
#    (~/.local/state/dotfiles/windows-powershell-profile.json に、$PROFILE のパスごと)
#
# 足した記録があるのに行が無いのは、Windows 側で外したということなので足し直さない
# (黙って戻さない。bootstrap-windows-files.sh の衝突と同じ考え方)。--force で足し直す。
#
# 改行はファイルに合わせる (CRLF があれば CRLF)。末尾に改行が無ければ先に補う。
# $PROFILE が無ければ親ごと作る。UTF-16 のファイルには書かない (ASCII を足すと壊れる)。
#
# Windows PowerShell 5.1 の $PROFILE は扱わない。5.1 は実行ポリシーの既定が Restricted で、
# 足しても読まれない。実行ポリシーはセキュリティの設定なので、ここでは変えない。

set -eu -o pipefail

usage() {
  cat <<'EOS'
win/ から配った PowerShell の共有設定 (dotfiles.ps1) を、PowerShell 7 の $PROFILE から読ませる。

使い方:
  bootstrap-windows-powershell-profile.sh            $PROFILE に読み込みの 1 行が無ければ足す
  bootstrap-windows-powershell-profile.sh --dry-run  判定だけ出して何も書かない
  bootstrap-windows-powershell-profile.sh --force    足した後で消されていても足し直す
EOS
}

force=0
dry_run=0
for arg in "$@"; do
  case ${arg} in
    --force) force=1 ;;
    --dry-run) dry_run=1 ;;
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

state_dir="${HOME}/.local/state/dotfiles"
state_file="${state_dir}/windows-files.json"
record_file="${state_dir}/windows-powershell-profile.json"

# $PROFILE に足す 1 行。dotfiles.ps1 が無いマシン (OneDrive の同期で $PROFILE だけが届いた PC
# など) でもエラーを出さないよう Test-Path で囲む。& で呼ぶと子の scope で定義されて
# 呼び終わりに消えるので dot-source で読む。$HOME は PowerShell が展開する。
# shellcheck disable=SC2016
line='if (Test-Path "$HOME\.config\powershell\dotfiles.ps1") { . "$HOME\.config\powershell\dotfiles.ps1" }'
# 「読む行がある」の判定。書き方が違っても dotfiles.ps1 を指していればよい
marker='.config\powershell\dotfiles.ps1'

# 自動で足せないときに、同じ 1 行を手で足すコマンドを出す
manual() {
  echo "   PowerShell 7 で次を 1 回打つと、同じ 1 行が足されます:" >&2
  # shellcheck disable=SC2016
  printf '     Add-Content -Path $PROFILE -Value '\''%s'\''\n' "${line}" >&2
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
deployed="${windows_home}/.config/powershell/dotfiles.ps1"
if [[ -z ${windows_home} || ! -f ${deployed} ]]; then
  echo "dotfiles.ps1 がまだ配られていません (${deployed})。この手順は飛ばします。"
  exit 0
fi

if [[ -e ${record_file} ]]; then
  if ! jq -e 'type == "object"' "${record_file}" >/dev/null 2>&1; then
    echo "!! ${record_file} が壊れています (JSON の object ではありません)。" >&2
    echo "   消してから流し直してください (足した記録が無いものとして扱います)。" >&2
    exit 1
  fi
  records=$(jq -c . "${record_file}")
else
  records='{}'
fi

if ! command -v pwsh.exe &>/dev/null; then
  echo "!! pwsh.exe が見つかりません (PowerShell 7 が無いか、WSL の PATH に Windows の PATH が入っていない)。" >&2
  manual
  exit 0
fi

# WSL の interop を通る。落ちていると Exec format error などで失敗する。
# -NoProfile: これから書き換える $PROFILE を読ませない。出力は UTF-8 にする (ドキュメントが化けないよう)。
# shellcheck disable=SC2016
if ! out=$(timeout 60 pwsh.exe -NoProfile -NonInteractive -Command '[Console]::OutputEncoding = [Text.Encoding]::UTF8; $PROFILE.CurrentUserCurrentHost' </dev/null 2>&1); then
  echo "!! pwsh.exe に \$PROFILE の場所を聞けませんでした (WSL の interop が落ちているかもしれません):" >&2
  printf '   %s\n' "${out}" >&2
  manual
  exit 0
fi
win_profile=$(printf '%s\n' "${out}" | tr -d '\r' | grep -E '^[A-Za-z]:[\]' | tail -n 1 || true)
if [[ -z ${win_profile} ]]; then
  echo "!! pwsh.exe が \$PROFILE の場所を返しませんでした:" >&2
  printf '   %s\n' "${out}" >&2
  manual
  exit 0
fi
if ! profile=$(wslpath -u "${win_profile}" 2>/dev/null) || [[ -z ${profile} ]]; then
  echo "!! \$PROFILE の場所を WSL のパスに直せませんでした: ${win_profile}" >&2
  manual
  exit 0
fi

recorded=$(jq -r --arg k "${profile}" '.[$k] // ""' <<<"${records}")

# 足した (または既にあった) ことを記録する。--dry-run と、記録済みのときは書かない
remember() {
  if ((dry_run)) || [[ ${recorded} == added ]]; then
    return 0
  fi
  mkdir -p "${state_dir}"
  local tmp_file
  tmp_file=$(mktemp "${record_file}.XXXXXX")
  jq -S --arg k "${profile}" '.[$k] = "added"' <<<"${records}" >"${tmp_file}"
  mv -f -- "${tmp_file}" "${record_file}"
}

if [[ -f ${profile} ]] && grep -qF -- "${marker}" "${profile}"; then
  echo "読み込み済みです: ${profile}"
  remember
  exit 0
fi

if [[ ${recorded} == added ]] && ((! force)); then
  echo "!! 以前 \$PROFILE に足した 1 行が見当たりません: ${profile}" >&2
  echo "   Windows 側で外したのなら、そのままにします。足し直すなら --force を付けて流してください。" >&2
  exit 0
fi

if [[ -s ${profile} ]]; then
  bom=$(head -c 2 -- "${profile}" | od -An -tx1 | tr -d ' \n')
  if [[ ${bom} == fffe || ${bom} == feff ]]; then
    echo "!! \$PROFILE が UTF-16 なので書き足しません: ${profile}" >&2
    manual
    exit 0
  fi
fi

if ((dry_run)); then
  echo "[dry-run] 1 行を足す: ${profile}"
  exit 0
fi

nl=$'\n'
prefix=""
if [[ -f ${profile} ]]; then
  if grep -q $'\r' -- "${profile}"; then
    nl=$'\r\n'
  fi
  if [[ -s ${profile} && $(tail -c 1 -- "${profile}" | od -An -tx1 | tr -d ' \n') != 0a ]]; then
    prefix=${nl}
  fi
else
  mkdir -p -- "$(dirname -- "${profile}")"
fi
printf '%s%s%s' "${prefix}" "${line}" "${nl}" >>"${profile}"
remember
echo "足しました: ${profile}"
# shellcheck disable=SC2016
echo '開いている PowerShell では . $PROFILE で読み直してください。'
