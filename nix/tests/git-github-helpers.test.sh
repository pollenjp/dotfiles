#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/ の script が持つ git_github() (setup が GitHub から取るとき、gitViaGh のマシンでは gh の資格情報を
# 先に試す関数) を、script ごとに切り出して確かめる。
#
#   bash nix/tests/git-github-helpers.test.sh [<nix/scripts のパス>]
#
# flake の checks (git-github-helpers-test) が Nix のサンドボックスで流す。使うのは bash・coreutils・grep・awk・diff
# だけ (git と gh は偽物を置く。GitHub には出ない)。
#
# setup.sh と bootstrap の取得 (TKT-221) は同じ git_github を使う。子の script は単体で配り・テストするので、
# warn() と同じく共通のファイルにせず各 script に同じ形で持つ。どれか 1 つが崩れると、その script の取得だけが
# 黙って ssh に戻る・gh を使い出すので、全部を並べて同じように振る舞うかを見る。
#
# ## 確かめること
#
#   - 下の expected の script が全部 git_github() を持ち、git_github() を持つ script の本文が 1 字も違わない。
#     1 つも見つからなければ落ちる (取り違えた場所を渡して、何も見ずに通さない)
#   - ~/.local/state/dotfiles/git-via-gh.json の enable が真偽値の true でない (無い・false・空・壊れている・
#     文字列の "true") なら、git (ssh) だけで流し、gh も git gh も呼ばず、経路の行も出さない
#   - true でも gh か git-gh が PATH に無い・gh auth token が通らないなら、理由を 1 行出して git (ssh) で流す
#   - true で gh が使えるなら git gh だけで流し、取れたら「gh の資格情報 (HTTPS) で取りました。」を出す
#   - git gh で取れなければ「取り直します」を出して git (ssh) で流し直し、取れたら warn する (stderr と、setup から
#     走るときのまとめのファイル)。終了コードは 0
#   - 取れなければ git の終了コードを返し、試した経路 (ssh だけ・gh が使えず ssh・gh と ssh) に合った案内を
#     git_github_hint に入れる
#   - 引数は git へそのまま渡る。jq が PATH に無くても状態ファイルを読める (setup.sh は Nix より前にも走る)
#
# ## 作り
#
# 偽の git は引数を FAKE_LOG に 1 行で書き、第 1 引数が gh (git gh) なら FAKE_GH_RC、ほかは FAKE_SSH_RC で
# 終わる。偽の gh は auth token なら FAKE_GH_AUTH_RC で終わる。git-gh は有無だけを見るので中身は無い (呼ばれたら
# 99)。PATH は偽物だけを並べる (gh が git と同じディレクトリにあって PATH から抜けない環境があるため。
# bootstrap-claude-env.test.sh と同じ)。偽のコマンドの shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
dir=${1:-${here}/../scripts}
work=$(mktemp -d "${TMPDIR:-/tmp}/git-github-helpers-test.XXXXXX")
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

# git_github() を持つはずの script
expected=(setup.sh bootstrap-cc-pages.sh bootstrap-claude-skills.sh bootstrap-dotfiles-private.sh)

# script から git_github()・warn()・summary_warn() の定義だけを取り出す (読み込むと script が最後まで走るため)
helpers_of() {
  awk '
    /^(git_github|warn|summary_warn)\(\) \{/ { f = 1 }
    f { print; if ($0 ~ /^\}$/) f = 0 }
  ' "$1"
}
# git_github() の定義だけ (script 間で本文を比べる)
body_of() {
  awk '
    /^git_github\(\) \{/ { f = 1 }
    f { print; if ($0 ~ /^\}$/) f = 0 }
  ' "$1"
}
defines() { grep -q '^git_github() {' "$1"; }

# 偽の git (bin) と、偽の gh・git-gh (gh-bin。「gh 無し」では PATH に入れない)
bin="${work}/bin"
ghbin="${work}/gh-bin"
mkdir -p "${bin}" "${ghbin}"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf '%s\n' "$*" >>"${FAKE_LOG}"
if [[ ${1-} == gh ]]; then
  exit "${FAKE_GH_RC:-0}"
fi
exit "${FAKE_SSH_RC:-0}"
EOF
} >"${bin}/git"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
if [[ ${1-} == auth && ${2-} == token ]]; then
  [[ ${FAKE_GH_AUTH_RC:-0} != 0 ]] || echo gho_fake
  exit "${FAKE_GH_AUTH_RC:-0}"
fi
exit 0
EOF
} >"${ghbin}/gh"
printf '#!%s\nexit 99\n' "${BASH}" >"${ghbin}/git-gh"
chmod +x "${bin}/git" "${ghbin}/gh" "${ghbin}/git-gh"

# git_github を 1 回呼ぶ。$1: ケースのディレクトリ、$2: 状態ファイルの中身 (- なら置かない)、$3: gh と git-gh を
# PATH に入れるか (1 / 0)、残り: git_github の引数。偽物の終了コードは呼び元が前に置く (FAKE_GH_RC=1 call …)。
# stdout (最後に RC= と HINT= の行)・stderr・偽の git の書き留め・まとめのファイルを <ケース>/{out,err,log,w} に残す
call() {
  local c=$1 state=$2 with_gh=$3 path="${bin}" q="" a
  shift 3
  mkdir -p "${c}/home"
  if [[ ${state} != - ]]; then
    mkdir -p "${c}/home/.local/state/dotfiles"
    printf '%s' "${state}" >"${c}/home/.local/state/dotfiles/git-via-gh.json"
  fi
  if [[ ${with_gh} == 1 ]]; then
    path="${ghbin}:${path}"
  fi
  for a in "$@"; do
    q+=" $(printf '%q' "${a}")"
  done
  HOME="${c}/home" PATH="${path}" FAKE_LOG="${c}/log" DOTFILES_SETUP_WARNINGS="${c}/w" c_yellow="" c_reset="" \
    "${BASH}" -c "${fns}"$'\n'"set -eu -o pipefail; rc=0; git_github${q} || rc=\$?; printf 'RC=%s\nHINT=%s\n' \"\${rc}\" \"\${git_github_hint}\"" \
    >"${c}/out" 2>"${c}/err"
}

log_of() { cat "$1/log" 2>/dev/null; }
detail() { printf 'out=%s\nerr=%s\nlog=%s\nw=%s' "$(cat "$1/out")" "$(cat "$1/err")" "$(log_of "$1")" "$(cat "$1/w" 2>/dev/null)"; }

ssh_line='-C /x fetch --quiet'
gh_line='gh -C /x fetch --quiet'
on='{"enable":true}'
note_no_gh='  gh (git gh) が見つからないので、ssh (ssh-agent) で取ります。'
note_no_login='  gh が github.com にログインしていないので、ssh (ssh-agent) で取ります。'
note_gh_ok='  gh の資格情報 (HTTPS) で取りました。'
note_retry='  gh の資格情報では取れませんでした。ssh (ssh-agent) で取り直します。'
warn_head='gh の資格情報では取れず、ssh (ssh-agent) で取りました。'
hint_ssh='SSH 鍵 (ssh-agent) で取れませんでした。疎通は ssh -T git@github.com で確かめられます。'

echo "== git_github(): ${dir}"

# 1. expected の script は全部 git_github() を持つ。持つ script の本文は 1 字も違わない
for name in "${expected[@]}"; do
  if [[ -f ${dir}/${name} ]] && defines "${dir}/${name}"; then
    ok "${name}: git_github() を持つ"
  else
    ng "${name}: git_github() を持たない"
  fi
done
first=""
first_body=""
checked=0
for f in "${dir}"/*.sh; do
  defines "${f}" || continue
  checked=$((checked + 1))
  if [[ -z ${first} ]]; then
    first=$(basename "${f}")
    first_body=$(body_of "${f}")
    continue
  fi
  body=$(body_of "${f}")
  if [[ ${body} == "${first_body}" ]]; then
    ok "$(basename "${f}"): git_github() の本文は ${first} と同じ"
  else
    ng "$(basename "${f}"): git_github() の本文が ${first} と違う" \
      "$(diff <(printf '%s\n' "${first_body}") <(printf '%s\n' "${body}") | head -20)"
  fi
done
if ((checked > 0)); then
  ok "git_github() を持つ script を ${checked} 個見た"
else
  ng "git_github() を持つ script が 1 つも無い (${dir})"
fi

for f in "${dir}"/*.sh; do
  defines "${f}" || continue
  name=$(basename "${f}")
  fns=$(helpers_of "${f}")
  c="${work}/${name%.sh}"
  odd=0

  # 2. 状態ファイルが無い・false: gh が PATH にあっても ssh だけ。経路の行も出さない
  for s in none off; do
    state=-
    [[ ${s} == off ]] && state='{"enable":false}'
    call "${c}/${s}" "${state}" 1 -C /x fetch --quiet
    if [[ $(log_of "${c}/${s}") == "${ssh_line}" && $(cat "${c}/${s}/out") == $'RC=0\nHINT=' && ! -s ${c}/${s}/err && ! -e ${c}/${s}/w ]]; then
      ok "${name}: 状態ファイルが ${s} なら ssh だけで流し、経路の行も出さない"
    else
      ng "${name}: 状態ファイルが ${s}" "$(detail "${c}/${s}")"
    fi
  done

  # 3. true でも gh と git-gh が PATH に無い: 理由を 1 行出して ssh
  call "${c}/nogh" "${on}" 0 -C /x fetch --quiet
  if [[ $(log_of "${c}/nogh") == "${ssh_line}" && $(cat "${c}/nogh/out") == "${note_no_gh}"$'\nRC=0\nHINT=' && ! -s ${c}/nogh/err ]]; then
    ok "${name}: gh が無ければ、理由を 1 行出して ssh で流す"
  else
    ng "${name}: gh が無い" "$(detail "${c}/nogh")"
  fi

  # 4. true でも gh auth token が通らない: 理由を 1 行出して ssh
  FAKE_GH_AUTH_RC=1 call "${c}/nologin" "${on}" 1 -C /x fetch --quiet
  if [[ $(log_of "${c}/nologin") == "${ssh_line}" && $(cat "${c}/nologin/out") == "${note_no_login}"$'\nRC=0\nHINT=' && ! -s ${c}/nologin/err ]]; then
    ok "${name}: gh にログインしていなければ、理由を 1 行出して ssh で流す"
  else
    ng "${name}: gh 未ログイン" "$(detail "${c}/nologin")"
  fi

  # 5. true で gh が使える: git gh だけ
  call "${c}/gh" "${on}" 1 -C /x fetch --quiet
  if [[ $(log_of "${c}/gh") == "${gh_line}" && $(cat "${c}/gh/out") == "${note_gh_ok}"$'\nRC=0\nHINT=' && ! -s ${c}/gh/err && ! -e ${c}/gh/w ]]; then
    ok "${name}: gh が使えれば git gh だけで流す (ssh に触れない)"
  else
    ng "${name}: gh で取れる" "$(detail "${c}/gh")"
  fi

  # 6. git gh で取れず ssh で取れる: 取り直して warn (その場とまとめ)、終了コードは 0
  FAKE_GH_RC=1 call "${c}/retry" "${on}" 1 -C /x fetch --quiet
  if [[ $(log_of "${c}/retry") == "${gh_line}"$'\n'"${ssh_line}" ]] \
    && [[ $(cat "${c}/retry/out") == "${note_retry}"$'\nRC=0\nHINT=' ]] \
    && [[ $(head -n 1 "${c}/retry/err") == "!! ${warn_head}" ]] \
    && [[ $(head -n 1 "${c}/retry/w" 2>/dev/null) == "${warn_head}" ]] \
    && grep -q 'gh auth status' "${c}/retry/w"; then
    ok "${name}: git gh で取れなければ ssh で取り直し、取れたら warn する (まとめにも)"
  else
    ng "${name}: gh で落ちて ssh で取れる" "$(detail "${c}/retry")"
  fi

  # 7. gh でも ssh でも取れない: ssh の終了コードを返し、両方の確かめ方を案内する
  FAKE_GH_RC=1 FAKE_SSH_RC=128 call "${c}/both" "${on}" 1 -C /x fetch --quiet
  if grep -qx 'RC=128' "${c}/both/out" && grep -q '^HINT=.*gh auth status' "${c}/both/out" \
    && grep -q '^HINT=.*ssh -T git@github\.com' "${c}/both/out"; then
    ok "${name}: gh でも ssh でも取れなければ、終了コードを返し gh auth status と ssh -T を案内する"
  else
    ng "${name}: 両方で取れない" "$(detail "${c}/both")"
  fi

  # 8. ssh だけで試して取れない: ssh の案内だけ (gh の話はしない)
  FAKE_SSH_RC=128 call "${c}/sshfail" - 1 -C /x fetch --quiet
  if [[ $(cat "${c}/sshfail/out") == $'RC=128\nHINT='"${hint_ssh}" ]]; then
    ok "${name}: ssh だけで試して取れなければ、ssh の確かめ方だけを案内する"
  else
    ng "${name}: ssh だけで取れない" "$(detail "${c}/sshfail")"
  fi

  # 9. gh が使えず ssh でも取れない: gh auth login を案内する
  FAKE_GH_AUTH_RC=1 FAKE_SSH_RC=128 call "${c}/loginhint" "${on}" 1 -C /x fetch --quiet
  if grep -qx 'RC=128' "${c}/loginhint/out" && grep -q '^HINT=.*gh auth login' "${c}/loginhint/out"; then
    ok "${name}: gh が使えず ssh でも取れなければ、gh auth login を案内する"
  else
    ng "${name}: gh が使えず ssh でも取れない" "$(detail "${c}/loginhint")"
  fi

  # 10. 状態ファイルの形: 空白や改行を挟んだ true は true。文字列の "true"・空・壊れたものは false
  call "${c}/spaced" $'{\n  "enable" : true\n}\n' 1 -C /x fetch --quiet
  if [[ $(log_of "${c}/spaced") == "${gh_line}" ]]; then
    ok "${name}: 空白や改行を挟んだ {\"enable\": true} も true として読む"
  else
    ng "${name}: 空白入りの true" "$(detail "${c}/spaced")"
  fi
  for s in '{"enable":"true"}' '' 'not json'; do
    c2="${c}/odd-$((++odd))"
    call "${c2}" "${s}" 1 -C /x fetch --quiet
    if [[ $(log_of "${c2}") == "${ssh_line}" && $(cat "${c2}/out") == $'RC=0\nHINT=' ]]; then
      ok "${name}: 状態ファイルが「${s}」なら false と同じ (ssh だけ)"
    else
      ng "${name}: 状態ファイルが「${s}」" "$(detail "${c2}")"
    fi
  done

  # 11. 引数はそのまま渡る (clone の URL と行き先)
  call "${c}/clone" "${on}" 1 clone git@github.com:o/r.git '/tmp/a b'
  if [[ $(log_of "${c}/clone") == 'gh clone git@github.com:o/r.git /tmp/a b' ]]; then
    ok "${name}: 引数は git へそのまま渡る"
  else
    ng "${name}: 引数" "$(detail "${c}/clone")"
  fi
done

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
