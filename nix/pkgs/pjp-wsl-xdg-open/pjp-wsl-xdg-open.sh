#!/usr/bin/env bash
# shellcheck shell=bash
#
# WSL の xdg-open。URL とファイルを Windows の既定のアプリ (URL なら既定のブラウザ) で開く。
#
#   xdg-open <URL かファイルのパス>
#
# Linux の CLI が開くものを Windows へ渡すためのもの。Linux 版の herdr も、pane のリンクの Ctrl+クリックで xdg-open を
# 呼ぶ (WSL かを見ない)。nix/pkgs/pjp-wsl-xdg-open/default.nix が writeShellApplication で包み (coreutils を PATH の先頭に
# 置く)、home/modules/wsl-xdg-open.nix が dotfiles.wsl.enable のマシンの PATH に入れる。単体でも bash pjp-wsl-xdg-open.sh で
# 動く (nix/tests/pjp-wsl-xdg-open.test.sh が偽の rundll32.exe でそうして流す)。
#
# 渡す先は rundll32.exe url.dll,FileProtocolHandler (中で ShellExecute を呼ぶ)。シェルを通らないので、URL の & で切れず、
# % も展開されない。すぐ返るので、呼んだ側を待たせない。開けなくても 0 を返すことがある (開いたかは分からない)。
#
# url.dll の入口には ANSI 版しかないので、rundll32.exe は引数を Windows の ANSI のコードページに変えてから渡す。そこで URL の
# ASCII の外の文字は UTF-8 の %XX にしてから渡す。ファイルのパスは %XX にできないので、コードページに無い文字を含む名前は
# 開けない (コードページが 65001 でない Windows の絵文字など)。
#
# ShellExecute が開けるものは xdg-open より広く、実行ファイルをそのまま起動し、http・https のほかの scheme は登録された
# アプリへ渡す。この xdg-open はサーバーから受け取った URL を開く CLI からも呼ばれるので、次のものは開かずに 4 で終わる。
#
#   - http・https のほかの scheme (ms-msdt: や search-ms: のように、Windows では別のアプリを動かすものがある)
#   - ほかのホストの file:// (Windows が SMB で読みに行く)
#   - Windows が実行するファイル (open_path の一覧。網羅ではない。実行したいなら直に打つ)
#
# 終了コードは xdg-utils の xdg-open と同じ意味にする。

set -euo pipefail

# Windows の rundll32.exe。WSL の PATH に Windows の PATH が無いマシンもあるので、固定のパスで呼ぶ。テストで差し替える
rundll32=${PJP_WSL_XDG_OPEN_RUNDLL32:-/mnt/c/Windows/System32/rundll32.exe}

usage() {
  cat <<'EOS'
使い方: xdg-open <URL かファイルのパス>
  Windows の既定のアプリで開く (WSL 用。dotfiles の pjp-wsl-xdg-open)
    http・https の URL       既定のブラウザで開く
    ファイル・ディレクトリ   wslpath で変換して開く (file:// の URL も)。Windows が実行するファイルは開かない
  ほかの scheme は開かない
終了コード:
  0 渡した / 1 引数の誤り / 2 ファイルが無い / 3 rundll32.exe が無い / 4 開けなかった・開かないもの
EOS
}

# <終了コード> <文>
die() {
  local code=$1
  shift
  printf 'xdg-open: %s\n' "$*" >&2
  exit "${code}"
}

hand_to_windows() {
  [[ -x ${rundll32} ]] || die 3 "${rundll32} がありません"
  # cwd を Linux 側のままにすると、Windows のプロセス (ここで初めて起きるブラウザなど) が \\wsl.localhost\… を cwd に持ち続ける
  cd -- "$(dirname -- "${rundll32}")" || die 3 "${rundll32} の場所へ移れません"
  "${rundll32}" url.dll,FileProtocolHandler "$1" || die 4 "rundll32.exe で開けませんでした: $1"
}

# URL に生で置けない文字 (制御文字・空白・DEL・ASCII の外) と " だけを %XX にする。残りは意味を変えないようそのまま
encode_url() {
  local LC_ALL=C
  local url=$1 encoded='' c i
  for ((i = 0; i < ${#url}; i++)); do
    c=${url:i:1}
    case ${c} in
      [^!-~] | '"') printf -v c '%%%02X' "'${c}" ;;
    esac
    encoded+=${c}
  done
  printf '%s\n' "${encoded}"
}

# あるファイル・ディレクトリを開く
open_path() {
  local resolved windows_path
  # 絶対パスにする (wslpath -w は相対パスを相対のまま返す)。下の判定は symlink の先の名前で決める
  resolved=$(readlink -f -- "$1")
  case ${resolved} in
    *. | *' ')
      die 4 "末尾が . か空白の名前は、Windows では別のファイルを指すので開きません: ${resolved}"
      ;;
  esac
  if [[ ! -d ${resolved} ]]; then
    # Windows の既定の PATHEXT と、ShellExecute が起動・導入・登録するほかの主なもの
    case ${resolved,,} in
      *.com | *.exe | *.bat | *.cmd | *.vbs | *.vbe | *.js | *.jse | *.wsf | *.wsh | *.msc | *.cpl | \
        *.scr | *.pif | *.msi | *.msp | *.ps1 | *.hta | *.jar | *.reg | *.lnk | *.url | *.scf | *.appref-ms | *.application)
        die 4 "Windows が実行するファイルなので開きません: ${resolved}"
        ;;
    esac
  fi
  windows_path=$(wslpath -w "${resolved}") || die 4 "wslpath で変換できませんでした: ${resolved}"
  hand_to_windows "${windows_path}"
}

# file:///<パス> と file://localhost/<パス> をファイルとして開く
open_file_url() {
  local rest=${1:7} path
  case ${rest,,} in
    /*) ;;
    localhost/*) rest=${rest:9} ;;
    *) die 4 "ほかのホストの file:// は開きません: $1" ;;
  esac
  rest=${rest%%#*}
  rest=${rest%%\?*}
  # %XX を戻す。\ は文字のまま (printf に読ませない)
  rest=${rest//\\/\\\\}
  printf -v path '%b' "${rest//%/\\x}"
  [[ -e ${path} ]] || die 2 "ファイルがありません: ${path}"
  open_path "${path}"
}

if [[ $# != 1 || -z $1 ]]; then
  usage >&2
  exit 1
fi
target=$1

case ${target} in
  -h | --help | --manual)
    usage
    exit 0
    ;;
  --version)
    echo 'xdg-open (dotfiles の pjp-wsl-xdg-open)'
    exit 0
    ;;
  -*)
    usage >&2
    exit 1
    ;;
esac

case ${target,,} in
  http://* | https://*)
    hand_to_windows "$(encode_url "${target}")"
    ;;
  file://*)
    open_file_url "${target}"
    ;;
  *)
    if [[ -e ${target} ]]; then
      open_path "${target}"
    elif [[ ${target} =~ ^[[:alpha:]][[:alnum:]+.-]*: ]]; then
      die 4 "http・https の URL とファイルのほかは開きません: ${target}"
    else
      die 2 "ファイルがありません: ${target}"
    fi
    ;;
esac
