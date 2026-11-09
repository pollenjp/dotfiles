#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/check-herdr-app-installers.sh の振る舞いを、偽の curl と使い捨ての記録で確かめる。
#
#   bash nix/tests/check-herdr-app-installers.test.sh [<script のパス>]
#
# flake の checks (check-herdr-app-installers-test) が Nix のサンドボックスで流す。ネットワークには出ない
# (curl は偽物で、URL のホストとパスで fixture のファイルを返す)。使うのは bash・coreutils・grep だけ。
#
# ## 確かめること
#
#   - 記録の sha256 と、落とした中身の sha256 が全部同じなら exit 0 で、URL ごとに「同じ」を出す
#   - 1 つでも違えば exit 1 で、URL・記録の sha256・今の sha256・差分を読む所 (3 列目) を出す
#   - GitHub Actions の中 (GITHUB_ACTIONS=true) なら、変わった・落とせなかったことを ::error の行にも出す
#   - 落とせない (curl が失敗する) ときは exit 2。変わったものもあれば exit 1 を優先する
#   - 記録の書き損じ (sha256 が 64 桁の小文字の hex でない・URL が https でない・列が足りない・多い)・
#     install.ps1 の行が無い・記録が無いときは exit 2
#   - # で始まる行と空行と CRLF の改行は読み飛ばす
#   - 知らない引数は exit 2、-h は使い方を出して exit 0。curl には --max-time を付け、stdin を渡さない
#
# ## 本物の curl を見せない
#
# 手元の PATH には本物の curl があり、見えると releases.herdr.dev へ取りにいく。要るコマンドだけを symlink で
# 並べた PATH で流す (bootstrap-windows-herdr.test.sh と同じ作り)。偽の curl の shebang は $BASH から作る
# (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/check-herdr-app-installers.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/check-herdr-app-installers-test.XXXXXX")
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

app_url='https://releases.herdr.dev/app/install.ps1'
core_url='https://releases.herdr.dev/core/install.ps1'
app_hist='https://github.com/herdrdev/herdr-app/commits/master/distribution/install.ps1'
core_hist='https://github.com/herdrdev/herdr-core/commits/master/distribution/install.ps1'

# 要るコマンドだけを並べた PATH (curl は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env grep sed cat cp mkdir mktemp rm dirname sha256sum head tr; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

sha_of() {
  local s
  s=$(printf '%s' "$1" | sha256sum)
  echo "${s%% *}"
}

# 1 ケースぶんの場所を作る。$1: 名前。fixture は <case>/web/<ホスト>/<パス> に置く
new_case() {
  local d="${work}/$1"
  mkdir -p "${d}/bin" "${d}/web/releases.herdr.dev/app" "${d}/web/releases.herdr.dev/core"
  printf '%s' 'app installer v1' >"${d}/web/releases.herdr.dev/app/install.ps1"
  printf '%s' 'core installer v1' >"${d}/web/releases.herdr.dev/core/install.ps1"
  # 偽の curl。引数を記録し、-o の先へ <case>/web/<URL のホストとパス> を写す。無ければ 22 (curl -f の HTTP エラー)。
  # stdin は読み切って curl-stdin に足す (script が </dev/null を付けていれば空。付け忘れると、while read が読んでいる
  # 記録の残りの行を食べて curl-stdin に出る)
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${FAKE_DIR}/curl-calls"
cat >>"${FAKE_DIR}/curl-stdin"
dest='' url=''
while (($#)); do
  case $1 in
    -o)
      dest=$2
      shift 2
      ;;
    --max-time)
      shift 2
      ;;
    -*) shift ;;
    *)
      url=$1
      shift
      ;;
  esac
done
src="${FAKE_DIR}/web/${url#https://}"
[[ -f ${src} ]] || exit 22
cp "${src}" "${dest}"
EOF
  } >"${d}/bin/curl"
  chmod +x "${d}/bin/curl"
  echo "${d}"
}

# 記録を書く。$1: case、残り: 行 (そのまま書く)
write_record() {
  local d=$1
  shift
  printf '%s\n' "$@" >"${d}/record.txt"
}

good_lines() {
  printf '%s\n' \
    '# 公式の install.ps1 の sha256' \
    '' \
    "$(sha_of 'app installer v1')  ${app_url}  ${app_hist}" \
    "$(sha_of 'core installer v1')  ${core_url}  ${core_hist}"
}

# $1: case、残り: script の引数 (既定は記録のファイル)。環境変数は呼び出し側で付ける
run() {
  local d=$1
  shift
  local args=("$@")
  if ((${#args[@]} == 0)); then
    args=("${d}/record.txt")
  fi
  env PATH="${d}/bin:${sys_bin}" FAKE_DIR="${d}" "${BASH}" "${script}" "${args[@]}" >"${d}/out" 2>"${d}/err"
  echo $? >"${d}/rc"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }
# 判定の grep -q はパイプで受けず、ファイルを直に読む (pipefail の下で SIGPIPE を拾わない)
seen() {
  local d=$1
  shift
  grep -q "$@" "${d}/out" "${d}/err"
}

echo "== check-herdr-app-installers.sh: ${script}"

# 1. 全部同じ: exit 0、URL ごとに「同じ」
d=$(new_case c1)
mapfile -t lines < <(good_lines)
write_record "${d}" "${lines[@]}"
run "${d}"
if [[ $(rc "${d}") == 0 ]] && seen "${d}" -F "同じ: ${app_url}" && seen "${d}" -F "同じ: ${core_url}" \
  && ! seen "${d}" '^::'; then
  ok "記録と同じなら exit 0 で、URL ごとに「同じ」を出す (Actions の外では ::error を出さない)"
else
  ng "全部同じ" "rc=$(rc "${d}") $(outerr "${d}")"
fi
if grep -q -- '--max-time' "${d}/curl-calls" && [[ -e ${d}/curl-stdin && ! -s ${d}/curl-stdin ]]; then
  ok "curl には --max-time を付け、stdin を渡さない"
else
  ng "curl の呼び方" "calls=$(cat "${d}/curl-calls" 2>/dev/null) stdin=$(cat "${d}/curl-stdin" 2>/dev/null)"
fi

# 2. core だけ変わった: exit 1、記録と今の sha256 と差分を読む所
d=$(new_case c2)
write_record "${d}" "${lines[@]}"
printf '%s' 'core installer v2' >"${d}/web/releases.herdr.dev/core/install.ps1"
run "${d}"
if [[ $(rc "${d}") == 1 ]] && seen "${d}" -F "同じ: ${app_url}" && seen "${d}" -F "変わった: ${core_url}" \
  && seen "${d}" -F "$(sha_of 'core installer v1')" && seen "${d}" -F "$(sha_of 'core installer v2')" \
  && seen "${d}" -F "${core_hist}" && seen "${d}" -F 'Install-HerdrApp.ps1'; then
  ok "変わったら exit 1 で、記録と今の sha256・差分を読む所・合わせるもの (Install-HerdrApp.ps1) を出す"
else
  ng "core が変わった" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 3. GitHub Actions の中: 変わったことを ::error の行にも出す
d=$(new_case c3)
write_record "${d}" "${lines[@]}"
printf '%s' 'app installer v2' >"${d}/web/releases.herdr.dev/app/install.ps1"
GITHUB_ACTIONS=true run "${d}"
if [[ $(rc "${d}") == 1 ]] && grep -q "^::error title=[^:]*::.*${app_url}" "${d}/out" "${d}/err"; then
  ok "GitHub Actions の中では、変わったことを ::error の行にも出す"
else
  ng "::error の行" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 4. 落とせない: exit 2
d=$(new_case c4)
write_record "${d}" "${lines[@]}"
rm "${d}/web/releases.herdr.dev/app/install.ps1"
GITHUB_ACTIONS=true run "${d}"
if [[ $(rc "${d}") == 2 ]] && seen "${d}" -F "落とせませんでした (curl の終了コード 22): ${app_url}" \
  && grep -q '^::error ' "${d}/out" "${d}/err"; then
  ok "落とせなければ exit 2 で、curl の終了コードを出す (Actions の中では ::error も)"
else
  ng "落とせない" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 5. 変わったものと落とせないものが両方: exit 1 を優先する
d=$(new_case c5)
write_record "${d}" "${lines[@]}"
rm "${d}/web/releases.herdr.dev/app/install.ps1"
printf '%s' 'core installer v2' >"${d}/web/releases.herdr.dev/core/install.ps1"
run "${d}"
if [[ $(rc "${d}") == 1 ]] && seen "${d}" -F '落とせませんでした' && seen "${d}" -F "変わった: ${core_url}"; then
  ok "変わったものと落とせないものが両方あれば exit 1 (両方を出す)"
else
  ng "両方" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 6. 書き損じ: exit 2 (sha256 の桁・大文字・URL・列の数)
bad=0
detail=''
i=0
for line in \
  "abc  ${app_url}  ${app_hist}" \
  "$(sha_of 'app installer v1' | tr 'a-f' 'A-F')  ${app_url}  ${app_hist}" \
  "$(sha_of 'app installer v1')  http://releases.herdr.dev/app/install.ps1  ${app_hist}" \
  "$(sha_of 'app installer v1')  ${app_url}" \
  "$(sha_of 'app installer v1')  ${app_url}  ${app_hist}  余り"; do
  i=$((i + 1))
  d=$(new_case "c6-${i}")
  write_record "${d}" "${line}"
  run "${d}"
  if [[ $(rc "${d}") != 2 ]] || ! seen "${d}" -F '1 行目'; then
    bad=1
    detail+="[${line}] rc=$(rc "${d}") $(outerr "${d}")"$'\n'
  fi
done
if ((bad == 0)); then
  ok "記録の書き損じ (sha256 の桁・大文字・http の URL・列の過不足) は、何行目かを出して exit 2"
else
  ng "書き損じ" "${detail}"
fi

# 7. install.ps1 の行が無い (コメントと空行だけ)・記録が無い: exit 2
d=$(new_case c7)
write_record "${d}" '# だけ' ''
run "${d}"
d2=$(new_case c7b)
run "${d2}" "${d2}/missing.txt"
if [[ $(rc "${d}") == 2 && $(rc "${d2}") == 2 ]] && seen "${d}" -F '行がありません' && seen "${d2}" -F '読めません'; then
  ok "install.ps1 の行が無い・記録が無いときは exit 2"
else
  ng "行が無い・記録が無い" "rc=$(rc "${d}") $(outerr "${d}") / rc=$(rc "${d2}") $(outerr "${d2}")"
fi

# 8. CRLF の記録も読む
d=$(new_case c8)
printf '%s\r\n' "${lines[@]}" >"${d}/record.txt"
run "${d}"
if [[ $(rc "${d}") == 0 ]] && seen "${d}" -F "同じ: ${core_url}"; then
  ok "CRLF の改行の記録も読む"
else
  ng "CRLF" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 9. 知らない引数は exit 2、-h は exit 0
d=$(new_case c9)
run "${d}" --bogus
d2=$(new_case c9b)
run "${d2}" -h
if [[ $(rc "${d}") == 2 && $(rc "${d2}") == 0 ]] && seen "${d2}" '使い方'; then
  ok "知らない引数は exit 2、-h は使い方を出して exit 0"
else
  ng "引数" "rc=$(rc "${d}") rc2=$(rc "${d2}") $(outerr "${d2}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
