#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/pkgs/pjp-wsl-xdg-open/pjp-wsl-xdg-open.sh (WSL の xdg-open) を、偽の rundll32.exe と wslpath で確かめる。
#
#   bash nix/tests/pjp-wsl-xdg-open.test.sh [<pjp-wsl-xdg-open.sh のパス>]
#
# flake の checks (pjp-wsl-xdg-open-test) が Nix のサンドボックスで流す。使うのは bash と coreutils だけ
# (本物の rundll32.exe は使わない。ブラウザが開くので)。
#
# ## 確かめること
#
# xdg-open は実機と同じ UTF-8 のロケール (LC_ALL=C.UTF-8) で流す (サンドボックスの既定の C では文字とバイトが同じになり、
# 文字数え・切り出しの誤りが見えない)。
#
#   URL
#     - http・https の URL は、rundll32.exe url.dll,FileProtocolHandler に 1 つの引数で渡す。& ? = # + % ' ^ | ( ) ! ~ は
#       そのまま (%XX を二重に変えない)。scheme の大文字小文字は問わない
#     - 空白・タブ・改行・DEL・" と ASCII の外の文字は %XX にして渡す (url.dll の入口は ANSI なので、UTF-8 のバイトで渡す)
#   ファイル
#     - あるファイル・ディレクトリは、wslpath -w で変換した絶対パスを渡す。相対パスは cwd から解決し、空白を含む名前も 1 つの
#       引数のまま。symlink は実体を渡す。scheme に見える名前 (foo:bar.txt) もファイルがあればファイルとして開く。名前の
#       末尾の改行も落とさない
#     - file:/// と file://localhost/ の URL は、%XX を戻し、# と ? の後ろを外してファイルとして開く。戻した %23・%3F は名前の
#       文字のまま。%XX の形でない % と \ も文字のまま読む。scheme の大文字小文字は問わない
#     - 無いファイルは 2 で終わり、rundll32.exe を呼ばない (file:// の URL も、Windows のパス \\host\share\x も)
#   断るもの (どれも 4 で終わり、rundll32.exe を呼ばない。stderr に出す)
#     - Windows が実行するファイル (exec_exts の拡張子。大文字でも、symlink の先でも、file:// の %XX の中でも)
#     - 末尾が . か空白の名前と、途中のディレクトリの末尾が . のパス (Windows では別のファイルを指す)
#     - http・https のほかの scheme (mailto:・ms-msdt:・javascript:・vscode://・C:\…)
#     - ほかのホストの file:// (Windows が SMB で読みに行く)・%00 を含む file://
#     - 解決できないパス (消えた cwd の .)
#   断るときの stderr に、渡された制御文字 (端末のエスケープ) をそのまま出さない
#   実行ファイルの名前のディレクトリは開く (ディレクトリは実行されない)
#   引数
#     - 引数が無い・空・2 つ以上・知らない option は 1 で終わり、rundll32.exe を呼ばない
#     - -h・--help・--manual・--version は 0 で終わり、stdout に出し、rundll32.exe を呼ばない
#   rundll32.exe と wslpath
#     - rundll32.exe は、それが置かれたディレクトリを cwd にして起こす (Linux 側の cwd を Windows のプロセスに持たせない)
#     - rundll32.exe が失敗したら 4、無ければ 3 で終わる。wslpath が失敗したら 4 で終わり、rundll32.exe を呼ばない
#
# ## 作り
#
# 偽の rundll32.exe は cwd と引数を FAKE_DIR/calls に書く (PJP_WSL_XDG_OPEN_RUNDLL32 で差し替える)。FAKE_RUNDLL32_RC で
# 終了コードを変える。偽の wslpath は本物の変換の一部を真似る: -w の絶対パスは \\wsl.localhost\u24\…、相対パスは相対のまま
# (本物も -a が無ければそう返す)、改行は U+F00A (本物は : や \ なども U+F0xx に変えるが、それは真似ない)。
# FAKE_WSLPATH_RC があれば失敗する。shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../pkgs/pjp-wsl-xdg-open/pjp-wsl-xdg-open.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/pjp-wsl-xdg-open-test.XXXXXX")
work=$(cd "${work}" && pwd -P)
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "  ok   $1"
}
ng() {
  fail=$((fail + 1))
  echo "  FAIL $1"
  if [[ -n ${2:-} ]]; then
    echo "       ${2//$'\n'/$'\n'       }"
  fi
}

mkdir -p "${work}/bin" "${work}/win" "${work}/files/sub" "${work}/case"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
{
  printf 'cwd=%s\n' "${PWD}"
  printf 'argc=%s\n' "$#"
  i=0
  for a in "$@"; do
    i=$((i + 1))
    printf 'arg%s=%s\n' "${i}" "${a}"
  done
} >>"${FAKE_DIR:?}/calls"
exit "${FAKE_RUNDLL32_RC:-0}"
EOF
} >"${work}/win/rundll32.exe"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
if [[ -n ${FAKE_WSLPATH_RC-} ]]; then
  echo 'wslpath: Invalid argument' >&2
  exit "${FAKE_WSLPATH_RC}"
fi
if [[ $# != 2 || $1 != -w ]]; then
  echo "偽の wslpath が知らない引数: $*" >&2
  exit 99
fi
p=${2//$'\n'/$'\xef\x80\x8a'}
case ${p} in
  /*) printf '\\\\wsl.localhost\\u24%s\n' "${p//\//\\}" ;;
  *) printf '%s\n' "${p//\//\\}" ;;
esac
EOF
} >"${work}/bin/wslpath"
chmod +x "${work}/win/rundll32.exe" "${work}/bin/wslpath"

# テストの置くファイル
files=${work}/files
touch "${files}/report.html" "${files}/sub/a b.html" "${files}/foo:bar.txt" "${files}/noext"
touch "${files}/run.exe" "${files}/RUN.BAT" "${files}/dot." "${files}/space "
touch "${files}/%41.html" "${files}/a\\nb.html" "${files}/日本語.html"
touch "${files}/100%.html" "${files}/%zz.html" "${files}/%a.html" "${files}/a#b.html" "${files}/a?b.html"
touch "${files}/"$'nl\n'
ln -s "${files}/report.html" "${files}/link.html"
ln -s "${files}/run.exe" "${files}/safe.html"
ln -s "${files}/nothing.html" "${files}/dangling.html"
mkdir "${files}/dir.exe" "${files}/dir."
touch "${files}/dir./in.html"

# Windows が実行する (入れたアプリの関連付けで実行される) ので開かない拡張子
exec_exts=(
  com exe bat cmd vbs vbe js jse wsf wsh msc cpl
  scr pif msi msp msu ps1 hta jar reg lnk url scf
  appref-ms application chm diagcab xbap settingcontent-ms
  theme themepack deskthemepack sh py pyw pyz pl rb
)

# このテストの files の下のパスが Windows でどう見えるか (偽の wslpath と同じ形。本物は wslpath -w /tmp が \\wsl.localhost\u24\tmp)
win_path() {
  local p=${files}/$1
  printf '\\\\wsl.localhost\\u24%s' "${p//\//\\}"
}

case_no=0
# 空のケースのディレクトリを作る (c に入れる)
new_case() {
  case_no=$((case_no + 1))
  c=${work}/case/${case_no}
  mkdir -p "${c}"
}

# xdg-open を流す。stdout・stderr・終了コードを ${c}/{stdout,stderr,rc} に残す。cwd は run_cwd (既定は files)。
# remove_cwd があれば、流す前に cwd を消す
run_cwd=${files}
run() {
  (
    cd "${run_cwd}" || exit 99
    if [[ -n ${remove_cwd-} ]]; then
      rmdir "${run_cwd}" || exit 99
    fi
    LC_ALL=C.UTF-8 FAKE_DIR=${c} PJP_WSL_XDG_OPEN_RUNDLL32=${rundll32_path:-${work}/win/rundll32.exe} \
      PATH="${work}/bin:${PATH}" "${BASH}" "${script}" "$@"
  ) >"${c}/stdout" 2>"${c}/stderr" </dev/null
  echo $? >"${c}/rc"
}

show() {
  printf 'rc=%s\nstdout=%s\nstderr=%s\ncalls=%s' "$(cat "${c}/rc")" "$(cat "${c}/stdout")" "$(cat "${c}/stderr")" "$(cat "${c}/calls" 2>/dev/null)"
}

# <確かめること> <引数> <rundll32.exe に渡るはずの文字列>: 0 で終わり、1 回だけ、1 つの引数で渡したか
opens() {
  local label=$1 target=$2 want=$3 expected
  new_case
  run "${target}"
  expected=$(printf 'cwd=%s\nargc=2\narg1=url.dll,FileProtocolHandler\narg2=%s' "${work}/win" "${want}")
  if [[ $(cat "${c}/rc") == 0 && $(cat "${c}/calls" 2>/dev/null) == "${expected}" ]]; then
    ok "${label}"
  else
    ng "${label}" "$(show)"
  fi
}

# <確かめること> <終了コード> <引数…>: その終了コードで終わり、rundll32.exe を呼ばず、stderr に理由を出したか
refuses() {
  local label=$1 want_rc=$2
  shift 2
  new_case
  run "$@"
  if [[ $(cat "${c}/rc") == "${want_rc}" && ! -e ${c}/calls && -s ${c}/stderr ]]; then
    ok "${label}"
  else
    ng "${label}" "$(show)"
  fi
}

# <確かめること> <引数>: 0 で終わり、stdout に出し、rundll32.exe を呼ばないか
informs() {
  local label=$1
  shift
  new_case
  run "$@"
  if [[ $(cat "${c}/rc") == 0 && ! -e ${c}/calls && -s ${c}/stdout ]]; then
    ok "${label}"
  else
    ng "${label}" "$(show)"
  fi
}

echo "== pjp-wsl-xdg-open (${script})"

opens "http の URL の & は切れない" 'http://localhost:8000/?a=1&b=2' 'http://localhost:8000/?a=1&b=2'
opens "https の URL の %XX を二重に変えない" 'https://example.com/p%20q?x=%E3%81%82&y=a+b#frag' 'https://example.com/p%20q?x=%E3%81%82&y=a+b#frag'
opens "URL の記号はそのまま" "https://example.com/?q=^x|y&r='z'&s=(w)&t=!v~" "https://example.com/?q=^x|y&r='z'&s=(w)&t=!v~"
opens "scheme の大文字小文字は問わない" 'HTTPS://EXAMPLE.COM/' 'HTTPS://EXAMPLE.COM/'
opens "URL の空白を %20 にする" 'https://example.com/a b' 'https://example.com/a%20b'
opens 'URL の " を %22 にする' 'https://example.com/?q="x"' 'https://example.com/?q=%22x%22'
opens "URL のタブ・改行・DEL を %XX にする" $'https://example.com/a\tb\nc\x7fd' 'https://example.com/a%09b%0Ac%7Fd'
opens "URL の日本語を UTF-8 の %XX にする" 'https://example.com/日本語' 'https://example.com/%E6%97%A5%E6%9C%AC%E8%AA%9E'
opens "URL の絵文字を UTF-8 の %XX にする" 'https://example.com/😀' 'https://example.com/%F0%9F%98%80'

opens "絶対パスのファイルを Windows のパスにして渡す" "${files}/report.html" "$(win_path report.html)"
opens "相対パスは cwd から解決する" 'sub/a b.html' "$(win_path 'sub/a b.html')"
opens "ディレクトリも開く" 'sub' "$(win_path sub)"
opens "symlink は実体を渡す" "${files}/link.html" "$(win_path report.html)"
opens "scheme に見える名前もファイルがあれば開く" 'foo:bar.txt' "$(win_path foo:bar.txt)"
opens "拡張子の無いファイルも開く" 'noext' "$(win_path noext)"
opens "日本語の名前も開く" '日本語.html' "$(win_path 日本語.html)"
opens "実行ファイルの名前のディレクトリは開く" 'dir.exe' "$(win_path dir.exe)"
opens "名前の末尾の改行を落とさない" $'nl\n' "$(win_path 'nl')"$'\xef\x80\x8a'

opens "file:/// の URL の %XX を戻してファイルとして開く" "file://${files}/sub/a%20b.html" "$(win_path 'sub/a b.html')"
opens "file://localhost/ の URL も開く" "file://localhost${files}/report.html" "$(win_path report.html)"
opens "file:// の scheme の大文字小文字は問わない" "FILE://${files}/report.html" "$(win_path report.html)"
opens "file://localhost の host の大文字小文字は問わない" "file://LOCALHOST${files}/report.html" "$(win_path report.html)"
opens "file:// の ? の後ろを外す" "file://${files}/report.html?a=1" "$(win_path report.html)"
opens "file:// の # の後ろを外す" "file://${files}/report.html#frag" "$(win_path report.html)"
opens "file:// の %25 は 1 回だけ戻す" "file://${files}/%2541.html" "$(win_path %41.html)"
opens "file:// の \\ は文字のまま読む" "file://${files}/a\\nb.html" "$(win_path 'a\nb.html')"
opens "file:// の日本語の %XX を戻す" "file://${files}/%E6%97%A5%E6%9C%AC%E8%AA%9E.html" "$(win_path 日本語.html)"
opens "file:// の 100% の % は文字のまま読む" "file://${files}/100%.html" "$(win_path 100%.html)"
opens "file:// の %XX の形でない %zz は文字のまま読む" "file://${files}/%zz.html" "$(win_path %zz.html)"
opens "file:// の 1 桁の %a は文字のまま読む" "file://${files}/%a.html" "$(win_path %a.html)"
opens "file:// の %23 は # の文字のまま" "file://${files}/a%23b.html" "$(win_path 'a#b.html')"
opens "file:// の %3F は ? の文字のまま" "file://${files}/a%3Fb.html" "$(win_path 'a?b.html')"

refuses "無いファイルは 2" 2 'nothing.html'
refuses "壊れた symlink は 2" 2 'dangling.html'
refuses "Windows のパスの \\\\host\\share は無いファイルとして 2" 2 '\\attacker.example\share\run.exe'
refuses "file:// の無いファイルは 2" 2 "file://${files}/nothing.html"

for ext in "${exec_exts[@]}"; do
  touch "${files}/x.${ext}"
  refuses ".${ext} は開かない" 4 "x.${ext}"
done
refuses "大文字の BAT も開かない" 4 'RUN.BAT'
refuses "symlink の先が exe なら開かない" 4 'safe.html'
refuses "file:// の exe も開かない" 4 "file://${files}/run.exe"
refuses "file:// の %XX の中の exe も開かない" 4 "file://${files}/run%2Eexe"
refuses "末尾が . の名前は開かない" 4 'dot.'
refuses "末尾が空白の名前は開かない" 4 'space '
refuses "途中のディレクトリの末尾が . のパスは開かない" 4 'dir./in.html'
refuses "file:// の %00 は開かない (後ろを切って別のファイルを開かない)" 4 "file://${files}/report.html%00.exe"
mkdir "${work}/gone"
run_cwd=${work}/gone
remove_cwd=1
refuses "消えた cwd の . は開かない" 4 '.'
unset remove_cwd
run_cwd=${files}

refuses "mailto: は開かない" 4 'mailto:a@example.com'
refuses "ms-msdt: は開かない" 4 'ms-msdt:/id PCWDiagnostic'
refuses "javascript: は開かない" 4 'javascript:alert(1)'
refuses "vscode:// は開かない" 4 'vscode://file/x'
refuses "Windows のパスの C:\\ は scheme として開かない" 4 'C:\Windows\notepad.exe'
refuses "ほかのホストの file:// は開かない" 4 'file://attacker.example/share/x.html'

new_case
run $'ms-msdt:\e]0;owned\a'
stderr_text=$(cat "${c}/stderr")
if [[ $(cat "${c}/rc") == 4 && ! -e ${c}/calls && -n ${stderr_text} && ${stderr_text} != *$'\e'* && ${stderr_text} != *$'\a'* ]]; then
  ok "断るときの stderr に、渡された制御文字をそのまま出さない"
else
  ng "断るときの stderr に、渡された制御文字をそのまま出さない" "$(show)"
fi

refuses "引数が無いと 1" 1
refuses "引数が空だと 1" 1 ''
refuses "引数が 2 つだと 1" 1 'https://example.com/' 'https://example.org/'
refuses "知らない option は 1" 1 '--nope'
informs "-h は stdout に出す" -h
informs "--help は stdout に出す" --help
informs "--manual は stdout に出す" --manual
informs "--version は stdout に出す" --version

export FAKE_RUNDLL32_RC=5
new_case
run 'https://example.com/'
if [[ $(cat "${c}/rc") == 4 && -s ${c}/calls && -s ${c}/stderr ]]; then
  ok "rundll32.exe が失敗したら 4"
else
  ng "rundll32.exe が失敗したら 4" "$(show)"
fi
unset FAKE_RUNDLL32_RC

rundll32_path=${work}/win/nothing.exe
refuses "rundll32.exe が無ければ 3" 3 'https://example.com/'
unset rundll32_path

export FAKE_WSLPATH_RC=1
refuses "wslpath が失敗したら 4" 4 'report.html'
unset FAKE_WSLPATH_RC

echo
echo "pass=${pass} fail=${fail}"
[[ ${fail} == 0 ]]
