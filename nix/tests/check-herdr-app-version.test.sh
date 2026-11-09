#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/check-herdr-app-version.sh の振る舞いを、偽の curl・gh と使い捨ての ps1 で確かめる。
#
#   bash nix/tests/check-herdr-app-version.test.sh [<script のパス>]
#
# flake の checks (check-herdr-app-version-test) が Nix のサンドボックスで流す。ネットワークには出ない
# (curl は URL のホストとパスで fixture を返し、gh は repo ごとの tag とソースの fixture を返す)。
# 使うのは bash・coreutils・grep・sed・jq だけ。
#
# ## 確かめること
#
#   - 固定した版の成果物の sha256 と manifest が固定した値と同じで、新しい版が無ければ exit 0
#   - 固定した版の成果物の sha256 が変わった・manifest の sha256 や core の generation が違う・app の core_min が固定した
#     core より新しいときは exit 1 で、何が違うかを出す
#   - 固定した版より新しい版が猶予 (7 日) の中なら ※ の行で知らせて exit 0 (GitHub Actions の中なら ::notice の行にも)
#   - 猶予がたった新しい版があれば exit 1 で、いちばん新しい版と、その sha256・core_min と、ソースが HERDR_RELEASES_URL を
#     読むか (読まなければ上げないこと) と、固定した版からの差分の URL を出す。core の generation が固定と違えば、app と一緒に
#     上げると出す。Windows の成果物が無い (HEAD が 404) 版は数えない。redirect の先の Last-Modified を読む
#   - 新しい版の HEAD が 404 のほか (5xx など) か、Last-Modified が無ければ、黙って飛ばさずに exit 2
#   - tag は gh api --paginate で全部読む
#   - GitHub Actions の中なら、知らせることを ::error の行にも出す
#   - 落とせない・gh が失敗する・ps1 が読めない (版や sha256 の形でない) ときは exit 2。知らないことがあれば 1 を優先する
#   - 知らない引数は exit 2、-h は使い方を出して exit 0。curl に stdin を渡さない
#
# ## 本物の curl と gh を見せない
#
# 手元の PATH には本物の curl と gh があり、見えると releases.herdr.dev と GitHub へ取りにいく。要るコマンドだけを symlink で
# 並べた PATH で流す (bootstrap-windows-herdr.test.sh と同じ作り)。偽物の shebang は $BASH から作る (サンドボックスに
# /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/check-herdr-app-version.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/check-herdr-app-version-test.XXXXXX")
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

# 要るコマンドだけを並べた PATH (curl と gh は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env grep sed cat cp mkdir mktemp rm dirname sha256sum jq base64 date sort tail head tr; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# 2026-11-20 00:00 UTC。app 0.1.13 と core 0.1.18 は 2026-11-04 (16 日前)、0.1.14 と 0.1.19 は 2026-11-18 (2 日前) に出た
now=$(date -u -d '2026-11-20T00:00:00Z' +%s)
old_date='Wed, 04 Nov 2026 14:43:26 GMT'
new_date='Wed, 18 Nov 2026 16:50:32 GMT'
rel=releases.herdr.dev

sha_of() {
  local s
  s=$(printf '%s' "$1" | sha256sum)
  echo "${s%% *}"
}

# 1 ケースぶんの場所を作る。$1: 名前。固定した版は app 0.1.12・core 0.1.17。新しい版の成果物と tag は、各ケースで足す
new_case() {
  local d="${work}/$1"
  mkdir -p "${d}/bin" "${d}/web/${rel}/app/0.1.12" "${d}/web/${rel}/core/0.1.17" "${d}/gh/herdrdev/herdr-app" "${d}/gh/herdrdev/herdr-core"
  put_release "${d}" app 0.1.12 "${old_date}" '"core_min": "0.1.11"'
  put_release "${d}" core 0.1.17 "${old_date}" '"generation": 1'
  printf 'v0.1.12\nv0.1.11\nnot-a-version\n' >"${d}/gh/herdrdev/herdr-app/tags"
  printf 'v0.1.17\nv0.1.16\n' >"${d}/gh/herdrdev/herdr-core/tags"
  write_ps1 "${d}" "$(sha_of 'app 0.1.12')" "$(sha_of 'core 0.1.17')" 1
  # 偽の curl。引数を記録し、stdin を読み切って curl-stdin に足す (script が </dev/null を付けていれば空)。
  # -sSIL (HEAD) なら <URL のホストとパス>.headers を出し、無ければ 404 の見出しを出す (-f が無いので終了コードは 0)。
  # -o なら <URL のホストとパス> を写し、無ければ 22 (curl -f の HTTP エラー)
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${FAKE_DIR}/curl-calls"
cat >>"${FAKE_DIR}/curl-stdin"
dest='' url='' head=0
while (($#)); do
  case $1 in
    -o)
      dest=$2
      shift 2
      ;;
    --max-time)
      shift 2
      ;;
    -sSIL) head=1; shift ;;
    -*) shift ;;
    *)
      url=$1
      shift
      ;;
  esac
done
src="${FAKE_DIR}/web/${url#https://}"
if ((head)); then
  if [[ -f ${src}.headers ]]; then
    cat "${src}.headers"
  else
    printf 'HTTP/2 404\r\ncontent-length: 0\r\n\r\n'
  fi
  exit 0
fi
[[ -f ${src} ]] || exit 22
cp "${src}" "${dest}"
EOF
  } >"${d}/bin/curl"
  # 偽の gh。gh api [--paginate] <endpoint> --jq <式> の endpoint で、tag の一覧か、ソースの中身 (base64) を返す。
  # FAKE_GH_FAIL があれば失敗する
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${FAKE_DIR}/gh-calls"
[[ -z ${FAKE_GH_FAIL-} ]] || exit 1
endpoint=''
for a in "$@"; do
  case ${a} in repos/*) endpoint=${a} ;; esac
done
case ${endpoint} in
  repos/*/tags\?*)
    repo=${endpoint#repos/}
    repo=${repo%/tags*}
    cat "${FAKE_DIR}/gh/${repo}/tags"
    ;;
  repos/*/contents/*)
    rest=${endpoint#repos/}
    repo=${rest%%/contents/*}
    path=${rest#*/contents/}
    file=${path%%\?ref=*}
    ref=${path#*\?ref=v}
    src="${FAKE_DIR}/gh/${repo}/src/${ref}/${file}"
    [[ -f ${src} ]] || exit 1
    base64 <"${src}"
    ;;
  *) exit 1 ;;
esac
EOF
  } >"${d}/bin/gh"
  chmod +x "${d}/bin/curl" "${d}/bin/gh"
  echo "${d}"
}

# 版つきの成果物と manifest と、Last-Modified の headers を置く。$1: case、$2: app か core、$3: 版、$4: 公開日、$5: manifest の追加の項目
put_release() {
  local d=$1 kind=$2 v=$3 date=$4 extra=$5 name
  if [[ ${kind} == app ]]; then name='herdr-app-windows-x86_64.tar.gz'; else name='herdr-core-windows-x86_64.zip'; fi
  mkdir -p "${d}/web/${rel}/${kind}/${v}"
  printf '%s' "${kind} ${v}" >"${d}/web/${rel}/${kind}/${v}/${name}"
  printf 'HTTP/2 200\r\nlast-modified: %s\r\ncontent-length: 1\r\n\r\n' "${date}" >"${d}/web/${rel}/${kind}/${v}/${name}.headers"
  printf '{"version": "%s", %s, "targets": {"windows-x86_64": {"url": "https://%s/%s/%s/%s", "sha256": "%s"}}}\n' \
    "${v}" "${extra}" "${rel}" "${kind}" "${v}" "${name}" "$(sha_of "${kind} ${v}")" >"${d}/web/${rel}/${kind}/${v}/manifest.json"
}

# ソースの fixture を置く。$1: case、$2: repo、$3: 版、$4: ファイル、$5: 中身
put_source() {
  mkdir -p "$(dirname "$1/gh/$2/src/$3/$4")"
  printf '%s\n' "$5" >"$1/gh/$2/src/$3/$4"
}

# 固定した版を書いた ps1。$1: case、$2: app の sha256、$3: core の sha256、$4: generation
write_ps1() {
  cat >"$1/Install-HerdrApp.ps1" <<EOF
param(
    [switch]\$Check,
    [string]\$AppVersion = '0.1.12',
    [string]\$AppSha256 = '$2',
    [string]\$CoreVersion = '0.1.17',
    [string]\$CoreSha256 = '$3',
    [int]\$CoreGeneration = $4
)
EOF
}

# $1: case、残り: script の引数 (既定は ps1)。環境変数は呼び出し側で付ける
run() {
  local d=$1
  shift
  local args=("$@")
  if ((${#args[@]} == 0)); then
    args=("${d}/Install-HerdrApp.ps1")
  fi
  env PATH="${d}/bin:${sys_bin}" FAKE_DIR="${d}" CHECK_HERDR_APP_NOW="${now}" "${BASH}" "${script}" "${args[@]}" >"${d}/out" 2>"${d}/err"
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

echo "== check-herdr-app-version.sh: ${script}"

# 1. 揃っていて、新しい版も無い: exit 0
d=$(new_case c1)
run "${d}"
if [[ $(rc "${d}") == 0 ]] && seen "${d}" -F '同じ: app 0.1.12 の成果物の sha256' && seen "${d}" -F '同じ: core 0.1.17 の成果物の sha256' \
  && seen "${d}" -F '新しい版は無い: app 0.1.12 が最新' && ! seen "${d}" '^::'; then
  ok "固定した版が揃っていて新しい版も無ければ exit 0 (Actions の外では ::error を出さない)"
else
  ng "揃っている" "rc=$(rc "${d}") $(outerr "${d}")"
fi
if [[ -e ${d}/curl-stdin && ! -s ${d}/curl-stdin ]]; then
  ok "curl に stdin を渡さない"
else
  ng "curl に stdin を渡した" "$(cat "${d}/curl-stdin" 2>/dev/null)"
fi

# 2. 固定した版の成果物が差し替えられた: exit 1
d=$(new_case c2)
printf '%s' 'tampered' >"${d}/web/${rel}/app/0.1.12/herdr-app-windows-x86_64.tar.gz"
GITHUB_ACTIONS=true run "${d}"
if [[ $(rc "${d}") == 1 ]] && seen "${d}" -F "app 0.1.12 の成果物の sha256 が、固定した値 $(sha_of 'app 0.1.12') と違う (今は $(sha_of 'tampered'))" \
  && grep -q '^::error title=herdr-app の固定した版::app 0.1.12 の成果物の sha256' "${d}/out"; then
  ok "固定した版の成果物の sha256 が変われば exit 1 で、今の値を出す (Actions の中では ::error も)"
else
  ng "成果物が変わった" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 3. manifest の sha256・generation・core_min が合わない: exit 1
d=$(new_case c3)
put_release "${d}" core 0.1.17 "${old_date}" '"generation": 2'
put_release "${d}" app 0.1.12 "${old_date}" '"core_min": "0.1.18"'
run "${d}"
if [[ $(rc "${d}") == 1 ]] && seen "${d}" -F 'core 0.1.17 の manifest の generation (2) が、固定した値 1 と違う' \
  && seen "${d}" -F 'app 0.1.12 の core_min (0.1.18) が、固定した core 0.1.17 より新しい'; then
  ok "core の generation が違う・app の core_min が固定した core より新しければ exit 1"
else
  ng "manifest が合わない" "rc=$(rc "${d}") $(outerr "${d}")"
fi
d=$(new_case c3b)
write_ps1 "${d}" "$(sha_of 'app 0.1.12')" "$(sha_of 'core 0.1.17')" 1
sed -i "s/$(sha_of 'app 0.1.12')/$(printf '%064d' 0)/" "${d}/web/${rel}/app/0.1.12/manifest.json"
run "${d}"
if [[ $(rc "${d}") == 1 ]] && seen "${d}" -F "app 0.1.12 の manifest の sha256 ($(printf '%064d' 0)) が、固定した値"; then
  ok "manifest の sha256 が固定した値と違えば exit 1"
else
  ng "manifest の sha256" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 4. 新しい版が猶予の中: ※ で知らせて exit 0
d=$(new_case c4)
put_release "${d}" app 0.1.14 "${new_date}" '"core_min": "0.1.11"'
printf 'v0.1.14\n' >>"${d}/gh/herdrdev/herdr-app/tags"
GITHUB_ACTIONS=true run "${d}"
if [[ $(rc "${d}") == 0 ]] && seen "${d}" -F '※ app の新しい版 0.1.14 (公開 2026-11-18, 1 日前。あと 6 日) は猶予の中 (固定した版 0.1.12)' \
  && grep -q '^::notice title=herdr-app の固定した版::app の新しい版 0.1.14' "${d}/out"; then
  ok "新しい版が猶予の中なら ※ と ::notice で知らせて exit 0"
else
  ng "猶予の中" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 5. 猶予がたった新しい版: いちばん新しい猶予がたった版を、sha256・core_min・ソースの読み方とともに exit 1 で知らせる
d=$(new_case c5)
put_release "${d}" app 0.1.13 "${old_date}" '"core_min": "0.1.11"'
put_release "${d}" app 0.1.14 "${new_date}" '"core_min": "0.1.11"'
printf 'v0.1.13\nv0.1.14\n' >>"${d}/gh/herdrdev/herdr-app/tags"
put_source "${d}" herdrdev/herdr-app 0.1.13 src/update.rs 'fn releases() -> String { std::env::var("HERDR_RELEASES_URL").unwrap_or_else(|_| "https://releases.herdr.dev".into()) }'
run "${d}"
if [[ $(rc "${d}") == 1 ]] && seen "${d}" -F "app の新しい版 0.1.13 が公開から 15 日たった (公開 2026-11-04・猶予 7 日)。sha256 $(sha_of 'app 0.1.13')・core_min 0.1.11。ソース (src/update.rs) は HERDR_RELEASES_URL を読む" \
  && seen "${d}" -F '差分 (src/update.rs も読む): https://github.com/herdrdev/herdr-app/compare/v0.1.12...v0.1.13' \
  && seen "${d}" -F '※ app の新しい版 0.1.14' && grep -q -- '--paginate repos/herdrdev/herdr-app/tags' "${d}/gh-calls"; then
  ok "猶予がたった版があれば exit 1 で、版・sha256・core_min・ソースが変数を読むこと・差分の URL を出す (猶予の中の版は ※。tag は --paginate で読む)"
else
  ng "猶予がたった" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 6. 猶予がたった新しい版のソースが HERDR_RELEASES_URL を読まない: 上げないと出す
d=$(new_case c6)
put_release "${d}" core 0.1.18 "${old_date}" '"generation": 1'
printf 'v0.1.18\n' >>"${d}/gh/herdrdev/herdr-core/tags"
put_source "${d}" herdrdev/herdr-core 0.1.18 crates/herdr-core/src/releases.rs 'fn base() -> String { "https://releases.herdr.dev".into() }'
run "${d}"
if [[ $(rc "${d}") == 1 ]] && seen "${d}" -F 'core の新しい版 0.1.18 が公開から 15 日たった' \
  && seen "${d}" -F 'ソース (crates/herdr-core/src/releases.rs) が HERDR_RELEASES_URL を読まない。上げると取得元をフィードに替えられない (公式から上がる) ので、上げない'; then
  ok "猶予がたった版のソースが変数を読まなければ、上げないと出す"
else
  ng "変数を読まない" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 7. Windows の成果物が無い新しい版は数えない
d=$(new_case c7)
printf 'v0.1.20\n' >>"${d}/gh/herdrdev/herdr-core/tags"
run "${d}"
if [[ $(rc "${d}") == 0 ]] && seen "${d}" -F '新しい版は無い: core 0.1.17 が最新'; then
  ok "版つきの成果物が無い版 (Windows の成果物を出さなかった版) は数えない"
else
  ng "成果物の無い版" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 7b. 猶予がたった core の generation が固定と違えば、app と一緒に上げると出す
d=$(new_case c7b)
put_release "${d}" core 0.1.18 "${old_date}" '"generation": 2'
printf 'v0.1.18\n' >>"${d}/gh/herdrdev/herdr-core/tags"
put_source "${d}" herdrdev/herdr-core 0.1.18 crates/herdr-core/src/releases.rs 'std::env::var("HERDR_RELEASES_URL")'
run "${d}"
if [[ $(rc "${d}") == 1 ]] && seen "${d}" -F '・generation 2 (固定した 1 と違う。app はこの generation の core と話せる版と一緒に上げる。CHANGELOG で確かめる)'; then
  ok "猶予がたった core の generation が固定と違えば、app と一緒に上げると出す"
else
  ng "generation が変わる" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 7c. redirect の先の Last-Modified を読む
d=$(new_case c7c)
put_release "${d}" app 0.1.13 "${old_date}" '"core_min": "0.1.11"'
printf 'HTTP/2 301\r\nlocation: https://%s/x\r\n\r\nHTTP/2 200\r\nlast-modified: %s\r\n\r\n' "${rel}" "${old_date}" >"${d}/web/${rel}/app/0.1.13/herdr-app-windows-x86_64.tar.gz.headers"
printf 'v0.1.13\n' >>"${d}/gh/herdrdev/herdr-app/tags"
put_source "${d}" herdrdev/herdr-app 0.1.13 src/update.rs 'std::env::var("HERDR_RELEASES_URL")'
run "${d}"
if [[ $(rc "${d}") == 1 ]] && seen "${d}" -F 'app の新しい版 0.1.13 が公開から 15 日たった'; then
  ok "redirect の先の応答の Last-Modified で公開日を読む"
else
  ng "redirect" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 7d. 新しい版の HEAD が 404 のほかで失敗する・Last-Modified が無い: 黙って飛ばさずに exit 2
d=$(new_case c7d)
put_release "${d}" app 0.1.13 "${old_date}" '"core_min": "0.1.11"'
printf 'HTTP/2 503\r\n\r\n' >"${d}/web/${rel}/app/0.1.13/herdr-app-windows-x86_64.tar.gz.headers"
printf 'v0.1.13\n' >>"${d}/gh/herdrdev/herdr-app/tags"
run "${d}"
d2=$(new_case c7e)
put_release "${d2}" core 0.1.18 "${old_date}" '"generation": 1'
printf 'HTTP/2 200\r\ncontent-length: 1\r\n\r\n' >"${d2}/web/${rel}/core/0.1.18/herdr-core-windows-x86_64.zip.headers"
printf 'v0.1.18\n' >>"${d2}/gh/herdrdev/herdr-core/tags"
run "${d2}"
if [[ $(rc "${d}") == 2 && $(rc "${d2}") == 2 ]] \
  && seen "${d}" -F 'app 0.1.13 の成果物の公開日 (HEAD の Last-Modified) を読めない' && ! seen "${d}" -F '新しい版は無い: app' \
  && seen "${d2}" -F 'core 0.1.18 の成果物の公開日 (HEAD の Last-Modified) を読めない'; then
  ok "新しい版の HEAD が 404 のほか (503) か Last-Modified が無ければ、飛ばさずに exit 2"
else
  ng "HEAD の失敗" "rc=$(rc "${d}")/$(rc "${d2}") $(outerr "${d}") $(outerr "${d2}")"
fi

# 8. 確かめられない: 固定した版を落とせない・gh が失敗する・ps1 が読めない
d=$(new_case c8)
rm "${d}/web/${rel}/core/0.1.17/herdr-core-windows-x86_64.zip"
run "${d}"
d2=$(new_case c8b)
FAKE_GH_FAIL=1 run "${d2}"
d3=$(new_case c8c)
write_ps1 "${d3}" 'not-a-sha' "$(sha_of 'core 0.1.17')" 1
run "${d3}"
d4=$(new_case c8d)
run "${d4}" "${d4}/missing.ps1"
if [[ $(rc "${d}") == 2 && $(rc "${d2}") == 2 && $(rc "${d3}") == 2 && $(rc "${d4}") == 2 ]] \
  && seen "${d}" -F 'core 0.1.17 の成果物を落とせない' && seen "${d2}" -F 'tag を読めない' \
  && seen "${d3}" -F 'ps1 から固定した版と sha256 を読めません' && seen "${d4}" -F 'ps1 が読めません'; then
  ok "落とせない・gh が失敗する・ps1 から読めない・ps1 が無いときは exit 2"
else
  ng "確かめられない" "rc=$(rc "${d}")/$(rc "${d2}")/$(rc "${d3}")/$(rc "${d4}") $(outerr "${d}") $(outerr "${d2}") $(outerr "${d3}")"
fi

# 9. 知らせることと確かめられないことが両方あれば exit 1
d=$(new_case c9)
printf '%s' 'tampered' >"${d}/web/${rel}/app/0.1.12/herdr-app-windows-x86_64.tar.gz"
rm "${d}/web/${rel}/core/0.1.17/herdr-core-windows-x86_64.zip"
run "${d}"
if [[ $(rc "${d}") == 1 ]] && seen "${d}" -F '落とせない' && seen "${d}" -F '成果物の sha256 が'; then
  ok "知らせることと確かめられないことが両方あれば exit 1 (両方を出す)"
else
  ng "両方" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 10. 知らない引数は exit 2、-h は exit 0
d=$(new_case c10)
run "${d}" --bogus
d2=$(new_case c10b)
run "${d2}" -h
if [[ $(rc "${d}") == 2 && $(rc "${d2}") == 0 ]] && seen "${d2}" '使い方'; then
  ok "知らない引数は exit 2、-h は使い方を出して exit 0"
else
  ng "引数" "rc=$(rc "${d}") rc2=$(rc "${d2}") $(outerr "${d2}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
