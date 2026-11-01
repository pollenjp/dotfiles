#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-ntn.sh が、ntn の config.json の keyring を状態ファイル (~/.local/state/dotfiles/ntn.json) の値に
# そろえることを、使い捨ての HOME で確かめる。
#
#   bash nix/tests/bootstrap-ntn.test.sh [<bootstrap-ntn.sh のパス>]
#
# flake の checks (bootstrap-ntn-test) が Nix のサンドボックスで流す。使うのは bash・jq・coreutils・findutils だけ。
#
# ## 確かめること
#
#   - config.json が無ければ、ntn が作るのと同じ形 {"version":"1","defaultWorkspaceIds":{},"keyring":<値>} で作る
#     (ディレクトリも)。mode は umask どおり (umask 022 で 0644・0755、002 で 0664・0775)。ntn は呼ばない
#     (入っていなくても作る)
#   - config.json があれば keyring だけを書き換え (無ければ足し)、ほかのキーは残し、元の mode (0640・読み取り専用の
#     0444) を保つ。同じ値なら書かない (中身も inode も変わらない)
#   - keyring が null なら何もしない (config.json もディレクトリも作らない。あるものは変えない)
#   - 状態ファイルが無い・形が違う、jq が無い、config.json が JSON の object として読めない・symlink なら、
#     書き換えずに警告して exit 0 (setup を止めない)
#   - version (文字列) の無い config.json は、keyring を書いたときも、もうそろっているとき (手で置いた
#     {"keyring": false}) も、「ntn が読めない」と警告する
#   - config directory は ntn と同じ規則で決める: NOTION_HOME (空なら無いのと同じ。XDG_CONFIG_HOME より先)
#     → $XDG_CONFIG_HOME/notion (ディレクトリのとき) → ~/.config/notion (~/.config がディレクトリのとき。
#     ~/.notion/config.json があっても見ない) → ~/.notion。NOTION_HOME がディレクトリでなければ、何も作らずに
#     警告して exit 0
#   - 書けない (ディレクトリを作れない・書き換えの一時ファイルを作れない・mv できない) ときも、警告して exit 0。
#     config.json は変えず、隣に中間ファイル (config.json.*) を残さない
#   - setup から走るとき (DOTFILES_SETUP_WARNINGS がある) は、どの警告も続きの行ごとまとめ用のファイルにも残す。
#     作った・書いた・そろっていた・null のときは、警告を何も出さない (stderr にもまとめにも)。
#     DOTFILES_SETUP_WARNINGS が無ければ、まとめ用のファイルを作らずに stderr にだけ出す

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-ntn.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-ntn-test.XXXXXX")
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

# 呼ばれたら印を残して落ちる偽の ntn。PATH の先頭に置く (bootstrap は ntn を呼ばない)。
# shebang は $BASH から作る (Nix のサンドボックスには /usr/bin/env が無い)
fake_bin="${work}/bin"
mkdir -p "${fake_bin}"
printf '#!%s\ntouch %q\nexit 1\n' "${BASH}" "${work}/ntn-called" >"${fake_bin}/ntn"
chmod +x "${fake_bin}/ntn"

# 呼ばれると落ちる偽のコマンドを $1 のディレクトリに置く ($2: コマンドの名前)。PATH の先頭に足して、書けないときを作る
fake_fail() {
  mkdir -p "$1"
  printf '#!%s\necho "%s: 落ちるように置いた偽物" >&2\nexit 1\n' "${BASH}" "$2" >"$1/$2"
  chmod +x "$1/$2"
}

# 1 ケースぶんの HOME を作る。$1: 名前、$2: 状態ファイルの中身 (空なら作らない)。~/.config も作る
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.config" "${h}/.local/state/dotfiles"
  if [[ -n $2 ]]; then printf '%s\n' "$2" >"${h}/.local/state/dotfiles/ntn.json"; fi
  echo "${h}"
}

# HOME を $1 にして、umask ${run_umask} (既定 022) で流す。setup から走るときと同じく、まとめ用のファイル
# ($1/warnings。流すたびに空から) を DOTFILES_SETUP_WARNINGS で渡す。残りの引数は env に足す変数
# (NOTION_HOME=… など。PATH や DOTFILES_SETUP_WARNINGS も上書きできる)。手元の NOTION_HOME・XDG_CONFIG_HOME は外す
run() {
  local h=$1
  shift
  rm -f "${h}/warnings"
  (
    umask "${run_umask:-022}"
    env -u NOTION_HOME -u XDG_CONFIG_HOME \
      HOME="${h}" PATH="${fake_bin}:${PATH}" DOTFILES_SETUP_WARNINGS="${h}/warnings" "$@" \
      "${BASH}" "${script}" >"${h}/out" 2>"${h}/err"
    echo $? >"${h}/rc"
  )
}

rc() { cat "$1/rc"; }
log() { echo "rc=$(rc "$1") out=$(cat "$1/out") err=$(cat "$1/err") warnings=$(cat "$1/warnings" 2>/dev/null)"; }
# 警告を何も出していない (stderr にもまとめにも)
quiet() { [[ ! -s $1/err && ! -s $1/warnings ]]; }
# 警告を出し、まとめにも残した
warned() { [[ -s $1/err && -s $1/warnings ]]; }
# JSON として同じか (キーの順と空白は問わない)。右辺を引用符で囲む (囲まないと == の右辺が glob になる)
same() { [[ $(jq -cS . <<<"$1" 2>/dev/null) == "$(jq -cS . <<<"$2")" ]]; }
# mode が 8 進の $2 にちょうど合うか
mode_is() { [[ -n $(find "$1" -prune -perm "$2") ]]; }
inode() { stat -c '%i' "$1"; }

created_false='{"version":"1","defaultWorkspaceIds":{},"keyring":false}'
created_true='{"version":"1","defaultWorkspaceIds":{},"keyring":true}'
merged_false='{"version":"1","defaultWorkspaceIds":{"ws":"id"},"experiments":["xldb"],"keyring":false}'

echo "== bootstrap-ntn.sh: ${script}"

# 1. config.json が無ければ ntn と同じ形で作る。mode は umask どおり。ntn は呼ばない。警告は出さない
h1=$(new_home t1 '{"keyring":false}')
f1="${h1}/.config/notion/config.json"
run "${h1}"
if [[ $(rc "${h1}") == 0 && -f ${f1} ]] && same "$(cat "${f1}")" "${created_false}" && grep -q '作りました' "${h1}/out" \
  && quiet "${h1}" && [[ ! -e ${work}/ntn-called ]]; then
  ok "config.json が無ければ {\"version\":\"1\",\"defaultWorkspaceIds\":{},\"keyring\":false} で作る (ntn は呼ばない・警告なし)"
else
  ng "config.json が無ければ ntn と同じ形で作る" "$(log "${h1}") ntn-called=$([[ -e ${work}/ntn-called ]] && echo yes || echo no)"
fi
if [[ -f ${f1} ]] && mode_is "${f1}" 644 && mode_is "${h1}/.config/notion" 755; then
  ok "新しいファイルとディレクトリの mode は umask どおり (umask 022 で 0644・0755)"
else
  ng "新しいファイルとディレクトリの mode は umask どおり (umask 022)" "$(ls -ld "${h1}/.config/notion" "${f1}" 2>&1)"
fi

# 1b. umask 002 (対象のホストの umask) なら 0664・0775
h=$(new_home t1b '{"keyring":false}')
f1b="${h}/.config/notion/config.json"
run_umask=002 run "${h}"
if [[ $(rc "${h}") == 0 && -f ${f1b} ]] && mode_is "${f1b}" 664 && mode_is "${h}/.config/notion" 775; then
  ok "umask 002 なら新しいファイルとディレクトリは 0664・0775"
else
  ng "umask 002 なら新しいファイルとディレクトリは 0664・0775" "$(log "${h}") $(ls -ld "${h}/.config/notion" "${f1b}" 2>&1)"
fi

# 2. 冪等: もう一度流しても中身も inode も変わらず、警告も出さない
if [[ -f ${f1} ]]; then
  before=$(cat "${f1}")
  ino=$(inode "${f1}")
  run "${h1}"
  if [[ $(rc "${h1}") == 0 && $(cat "${f1}") == "${before}" && $(inode "${f1}") == "${ino}" ]] \
    && grep -q 'そろっています' "${h1}/out" && quiet "${h1}"; then
    ok "同じ値なら書かない (中身も inode も変わらず、そろっていますと出る・警告なし)"
  else
    ng "同じ値なら書かない" "$(log "${h1}")"
  fi
else
  ng "同じ値なら書かない" "1 で config.json ができていない"
fi

# 3. keyring = true でも同じ形で作る
h=$(new_home t3 '{"keyring":true}')
run "${h}"
if [[ $(rc "${h}") == 0 ]] && same "$(cat "${h}/.config/notion/config.json" 2>/dev/null)" "${created_true}" && quiet "${h}"; then
  ok "keyring = true なら keyring が true の形で作る"
else
  ng "keyring = true なら keyring が true の形で作る" "$(log "${h}")"
fi

# 4. merge: keyring だけを書き換え、ほかのキーと mode (0640。mktemp の 0600 と見分ける) は残す。警告は出さない
h=$(new_home t4 '{"keyring":false}')
f4="${h}/.config/notion/config.json"
mkdir -p "${h}/.config/notion"
printf '%s\n' '{"version":"1","defaultWorkspaceIds":{"ws":"id"},"experiments":["xldb"],"keyring":true}' >"${f4}"
chmod 640 "${f4}"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && same "$(cat "${f4}")" "${merged_false}" && grep -q '書きました' "${h}/out" && quiet "${h}"; then
  ok "既存の config.json は keyring だけを書き換え、ほかのキーは残す (警告なし)"
else
  ng "既存の config.json は keyring だけを書き換え、ほかのキーは残す" "$(log "${h}") file=$(cat "${f4}")"
fi
# 書き換えが起きたうえで mode を見る (書き換えずに残った 0640 を通さない)
if [[ $(rc "${h}") == 0 && $(jq -c '.keyring' "${f4}" 2>/dev/null) == false ]] && mode_is "${f4}" 640; then
  ok "書き換えても元の mode (0640) を保つ"
else
  ng "書き換えても元の mode (0640) を保つ" "rc=$(rc "${h}") $(ls -l "${f4}")"
fi

# 4b. 読み取り専用 (0444) の config.json も書き換え、mode を保つ (一時ファイルに書いてから mode を写す)
h=$(new_home t4b '{"keyring":false}')
f4b="${h}/.config/notion/config.json"
mkdir -p "${h}/.config/notion"
printf '%s\n' "${created_true}" >"${f4b}"
chmod 444 "${f4b}"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && same "$(cat "${f4b}")" "${created_false}" && mode_is "${f4b}" 444 && quiet "${h}"; then
  ok "読み取り専用 (0444) の config.json も keyring を書き換え、mode を保つ"
else
  ng "読み取り専用 (0444) の config.json も keyring を書き換え、mode を保つ" "$(log "${h}") $(ls -l "${f4b}")"
fi

# 5. keyring の無い config.json には keyring を足す
h=$(new_home t5 '{"keyring":true}')
f5="${h}/.config/notion/config.json"
mkdir -p "${h}/.config/notion"
printf '%s\n' '{"version":"1","defaultWorkspaceIds":{}}' >"${f5}"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && same "$(cat "${f5}")" "${created_true}" && quiet "${h}"; then
  ok "keyring の無い config.json には keyring を足す"
else
  ng "keyring の無い config.json には keyring を足す" "$(log "${h}") file=$(cat "${f5}")"
fi

# 6. keyring が null なら何もしない
h=$(new_home t6 '{"keyring":null}')
run "${h}"
if [[ $(rc "${h}") == 0 && ! -e ${h}/.config/notion ]] && quiet "${h}"; then
  ok "keyring が null なら config.json もディレクトリも作らない (警告なし)"
else
  ng "keyring が null なら config.json もディレクトリも作らない" "$(log "${h}")"
fi
h=$(new_home t6b '{"keyring":null}')
f6="${h}/.config/notion/config.json"
mkdir -p "${h}/.config/notion"
printf '%s\n' '{"version":"1","defaultWorkspaceIds":{},"keyring":true}' >"${f6}"
before=$(cat "${f6}")
ino=$(inode "${f6}")
run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "${f6}") == "${before}" && $(inode "${f6}") == "${ino}" ]] && quiet "${h}"; then
  ok "keyring が null なら、ある config.json も変えない"
else
  ng "keyring が null なら、ある config.json も変えない" "$(log "${h}")"
fi

# 7. 状態ファイルが無い: 警告して exit 0、何も作らない
h=$(new_home t7 '')
run "${h}"
if [[ $(rc "${h}") == 0 && ! -e ${h}/.config/notion ]] && warned "${h}" && grep -q 'ntn.json' "${h}/warnings"; then
  ok "状態ファイルが無ければ警告して飛ばす (exit 0、何も作らない)"
else
  ng "状態ファイルが無ければ警告して飛ばす" "$(log "${h}")"
fi
# 7b. setup の外 (DOTFILES_SETUP_WARNINGS が無い) では、まとめ用のファイルを作らずに stderr にだけ出す
h=$(new_home t7b '')
run "${h}" DOTFILES_SETUP_WARNINGS=
if [[ $(rc "${h}") == 0 && ! -e ${h}/warnings ]] && grep -q 'ntn.json' "${h}/err"; then
  ok "setup の外では、まとめ用のファイルを作らずに stderr にだけ警告する"
else
  ng "setup の外では、まとめ用のファイルを作らずに stderr にだけ警告する" "$(log "${h}")"
fi

# 8. 状態ファイルの形が違う: 警告して exit 0、何も作らない
i=0
for bad in '{"keyring":"false"}' '{}' '[]' '{"keyring":'; do
  i=$((i + 1))
  h=$(new_home "t8-${i}" "${bad}")
  run "${h}"
  if [[ $(rc "${h}") == 0 && ! -e ${h}/.config/notion ]] && warned "${h}"; then
    ok "形の違う状態ファイルは警告して飛ばす: ${bad}"
  else
    ng "形の違う状態ファイルは警告して飛ばす: ${bad}" "$(log "${h}")"
  fi
done

# 9. JSON の object として読めない config.json: 書き換えずに警告して exit 0
i=0
for bad in '{"version":' '[]' ''; do
  i=$((i + 1))
  h=$(new_home "t9-${i}" '{"keyring":false}')
  f9="${h}/.config/notion/config.json"
  mkdir -p "${h}/.config/notion"
  if [[ -n ${bad} ]]; then printf '%s\n' "${bad}" >"${f9}"; else : >"${f9}"; fi
  before=$(cat "${f9}")
  ino=$(inode "${f9}")
  run "${h}"
  if [[ $(rc "${h}") == 0 && $(cat "${f9}") == "${before}" && $(inode "${f9}") == "${ino}" ]] && warned "${h}"; then
    ok "読めない config.json は書き換えずに警告する: '${bad}'"
  else
    ng "読めない config.json は書き換えずに警告する: '${bad}'" "$(log "${h}") file=$(cat "${f9}")"
  fi
done

# 10. config.json が symlink: 書き換えずに警告して exit 0 (symlink も先のファイルも変えない)
h=$(new_home t10 '{"keyring":false}')
f10="${h}/.config/notion/config.json"
mkdir -p "${h}/.config/notion"
printf '%s\n' "${created_true}" >"${h}/real.json"
ln -s "${h}/real.json" "${f10}"
run "${h}"
if [[ $(rc "${h}") == 0 && -L ${f10} ]] && same "$(cat "${h}/real.json")" "${created_true}" && warned "${h}" \
  && grep -q 'symlink' "${h}/warnings"; then
  ok "config.json が symlink なら、symlink も先のファイルも書き換えずに警告する"
else
  ng "config.json が symlink なら書き換えずに警告する" "$(log "${h}") real=$(cat "${h}/real.json")"
fi

# 11. version (文字列) の無い config.json: keyring は書き、ntn が読めないと警告する
h=$(new_home t11 '{"keyring":false}')
f11="${h}/.config/notion/config.json"
mkdir -p "${h}/.config/notion"
printf '%s\n' '{"keyring":true}' >"${f11}"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && same "$(cat "${f11}")" '{"keyring":false}' && warned "${h}" && grep -q 'version' "${h}/warnings"; then
  ok "version の無い config.json は keyring を書いたうえで、version が無いと警告する"
else
  ng "version の無い config.json は keyring を書いたうえで警告する" "$(log "${h}") file=$(cat "${f11}")"
fi
# 11b. 手で置いた {"keyring": false} (version が無く、値はもうそろっている) でも黙らずに警告する
h=$(new_home t11b '{"keyring":false}')
f11b="${h}/.config/notion/config.json"
mkdir -p "${h}/.config/notion"
printf '%s\n' '{"keyring": false}' >"${f11b}"
before=$(cat "${f11b}")
ino=$(inode "${f11b}")
run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "${f11b}") == "${before}" && $(inode "${f11b}") == "${ino}" ]] \
  && grep -q 'そろっています' "${h}/out" && warned "${h}" && grep -q 'version' "${h}/warnings"; then
  ok "手で置いた {\"keyring\": false} は、値がそろっていても version が無いと警告する"
else
  ng "手で置いた {\"keyring\": false} は、値がそろっていても version が無いと警告する" "$(log "${h}")"
fi

# 12. config directory の場所 (ntn と同じ規則)
# a. NOTION_HOME (ある)
h=$(new_home t12a '{"keyring":false}')
mkdir -p "${h}/nh"
run "${h}" NOTION_HOME="${h}/nh"
if [[ $(rc "${h}") == 0 && ! -e ${h}/.config/notion ]] && same "$(cat "${h}/nh/config.json" 2>/dev/null)" "${created_false}"; then
  ok "NOTION_HOME があれば、その直下の config.json"
else
  ng "NOTION_HOME があれば、その直下の config.json" "$(log "${h}")"
fi
# b. XDG_CONFIG_HOME (ある)
h=$(new_home t12b '{"keyring":false}')
mkdir -p "${h}/xdg"
run "${h}" XDG_CONFIG_HOME="${h}/xdg"
if [[ $(rc "${h}") == 0 && ! -e ${h}/.config/notion ]] && same "$(cat "${h}/xdg/notion/config.json" 2>/dev/null)" "${created_false}"; then
  ok "XDG_CONFIG_HOME がディレクトリなら \$XDG_CONFIG_HOME/notion/config.json"
else
  ng "XDG_CONFIG_HOME がディレクトリなら \$XDG_CONFIG_HOME/notion/config.json" "$(log "${h}")"
fi
# c. XDG_CONFIG_HOME (無い) → ~/.config/notion
h=$(new_home t12c '{"keyring":false}')
run "${h}" XDG_CONFIG_HOME="${h}/missing"
if [[ $(rc "${h}") == 0 && ! -e ${h}/missing ]] && same "$(cat "${h}/.config/notion/config.json" 2>/dev/null)" "${created_false}"; then
  ok "XDG_CONFIG_HOME が無いディレクトリなら ~/.config/notion/config.json (XDG_CONFIG_HOME は作らない)"
else
  ng "XDG_CONFIG_HOME が無いディレクトリなら ~/.config/notion/config.json" "$(log "${h}")"
fi
# d. ~/.config が無い → ~/.notion
h=$(new_home t12d '{"keyring":false}')
rmdir "${h}/.config"
run "${h}"
if [[ $(rc "${h}") == 0 && ! -e ${h}/.config ]] && same "$(cat "${h}/.notion/config.json" 2>/dev/null)" "${created_false}"; then
  ok "HOME に .config が無ければ ~/.notion/config.json (~/.config は作らない)"
else
  ng "HOME に .config が無ければ ~/.notion/config.json" "$(log "${h}")"
fi
# e. NOTION_HOME が空 → 無いのと同じ
h=$(new_home t12e '{"keyring":false}')
run "${h}" NOTION_HOME=
if [[ $(rc "${h}") == 0 ]] && same "$(cat "${h}/.config/notion/config.json" 2>/dev/null)" "${created_false}"; then
  ok "NOTION_HOME が空なら無いのと同じ (~/.config/notion/config.json)"
else
  ng "NOTION_HOME が空なら無いのと同じ" "$(log "${h}")"
fi
# f. NOTION_HOME (無い) → 何も作らずに警告
h=$(new_home t12f '{"keyring":false}')
run "${h}" NOTION_HOME="${h}/missing"
if [[ $(rc "${h}") == 0 && ! -e ${h}/missing && ! -e ${h}/.config/notion ]] && warned "${h}" && grep -q 'NOTION_HOME' "${h}/warnings"; then
  ok "NOTION_HOME がディレクトリでなければ、何も作らずに警告する"
else
  ng "NOTION_HOME がディレクトリでなければ、何も作らずに警告する" "$(log "${h}")"
fi
# g. NOTION_HOME と XDG_CONFIG_HOME の両方 → NOTION_HOME
h=$(new_home t12g '{"keyring":false}')
mkdir -p "${h}/nh" "${h}/xdg"
run "${h}" NOTION_HOME="${h}/nh" XDG_CONFIG_HOME="${h}/xdg"
if [[ $(rc "${h}") == 0 && ! -e ${h}/xdg/notion ]] && same "$(cat "${h}/nh/config.json" 2>/dev/null)" "${created_false}"; then
  ok "NOTION_HOME と XDG_CONFIG_HOME の両方があれば NOTION_HOME (xdg/notion は作らない)"
else
  ng "NOTION_HOME と XDG_CONFIG_HOME の両方があれば NOTION_HOME" "$(log "${h}")"
fi
# h. ~/.config があれば、~/.notion/config.json があっても ~/.config/notion (~/.notion は変えない)
h=$(new_home t12h '{"keyring":false}')
mkdir -p "${h}/.notion"
printf '%s\n' "${created_true}" >"${h}/.notion/config.json"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && same "$(cat "${h}/.config/notion/config.json" 2>/dev/null)" "${created_false}" \
  && same "$(cat "${h}/.notion/config.json")" "${created_true}"; then
  ok "HOME に .config があれば、~/.notion/config.json があっても ~/.config/notion に書く (~/.notion は変えない)"
else
  ng "HOME に .config があれば、~/.notion/config.json があっても ~/.config/notion に書く" "$(log "${h}")"
fi

# 13. ディレクトリを作れない (~/.config/notion が通常のファイル): 警告して exit 0、そのファイルは変えない
h=$(new_home t13 '{"keyring":false}')
printf 'not a directory\n' >"${h}/.config/notion"
run "${h}"
if [[ $(rc "${h}") == 0 && -f ${h}/.config/notion && $(cat "${h}/.config/notion") == 'not a directory' ]] && warned "${h}"; then
  ok "ディレクトリを作れなければ警告して飛ばす (exit 0)"
else
  ng "ディレクトリを作れなければ警告して飛ばす" "$(log "${h}")"
fi
# 13b・13c. 書き換えるときに一時ファイルを作れない (mktemp が落ちる)・置き換えられない (mv が落ちる):
#           警告して exit 0、config.json は変えず、隣に中間ファイルを残さない
for cmd in mktemp mv; do
  h=$(new_home "t13-${cmd}" '{"keyring":false}')
  f13="${h}/.config/notion/config.json"
  mkdir -p "${h}/.config/notion"
  printf '%s\n' "${created_true}" >"${f13}"
  before=$(cat "${f13}")
  ino=$(inode "${f13}")
  fake_fail "${h}/fail-bin" "${cmd}"
  run "${h}" PATH="${h}/fail-bin:${fake_bin}:${PATH}"
  leftovers=$(find "${h}/.config/notion" -name 'config.json.*' -print)
  if [[ $(rc "${h}") == 0 && $(cat "${f13}") == "${before}" && $(inode "${f13}") == "${ino}" && -z ${leftovers} ]] && warned "${h}"; then
    ok "書き換えるときに ${cmd} が落ちても、警告して exit 0 (config.json は変えず、中間ファイルも残さない)"
  else
    ng "書き換えるときに ${cmd} が落ちても、警告して exit 0" "$(log "${h}") leftovers=${leftovers}"
  fi
done

# 14. 中間ファイル (config.json.XXXXXX) を残さない。書いたケース (1・4) で書けていることも見る
leftovers=$(find "${work}" -name 'config.json.*' -print)
if [[ -z ${leftovers} && -f ${f1} ]] && same "$(cat "${f4}")" "${merged_false}"; then
  ok "config.json の隣に中間ファイルを残さない"
else
  ng "config.json の隣に中間ファイルを残さない" "${leftovers}"
fi

# 15. まとめ用のファイルの形: 1 行目は警告の 1 行目そのもの (「!! 」なし)、続きの行は字下げ (7 の警告で見る)
if [[ $(head -n 1 "${work}/t7/warnings" 2>/dev/null) == 'ntn の keyring の状態ファイルがありません: '* ]] \
  && grep -qE '^[[:space:]]+.*home-manager switch' "${work}/t7/warnings"; then
  ok "まとめ用のファイルには、警告を続きの行ごと字下げして残す"
else
  ng "まとめ用のファイルには、警告を続きの行ごと字下げして残す" "$(cat "${work}/t7/warnings" 2>/dev/null)"
fi

# 16. jq が無い (PATH に何も無い): 警告して exit 0、何も作らない
h=$(new_home t16 '{"keyring":false}')
mkdir -p "${h}/empty-bin"
run "${h}" PATH="${h}/empty-bin"
if [[ $(rc "${h}") == 0 && ! -e ${h}/.config/notion ]] && warned "${h}" && grep -q 'jq' "${h}/warnings"; then
  ok "jq が無ければ警告して飛ばす (exit 0、何も作らない)"
else
  ng "jq が無ければ警告して飛ばす" "$(log "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
