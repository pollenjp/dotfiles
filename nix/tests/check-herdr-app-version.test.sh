#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/check-herdr-app-version.sh の振る舞いを、偽の curl・gh と使い捨ての releases.json で確かめる。
#
#   bash nix/tests/check-herdr-app-version.test.sh [<script のパス>]
#
# flake の checks (check-herdr-app-version-test) が Nix のサンドボックスで流す。ネットワークには出ない
# (curl は URL のホストとパスで fixture を返し、gh は repo ごとの tag とソースの fixture を返す)。
# 使うのは bash・coreutils・grep・sed・jq だけ。
#
# ## 確かめること
#
#   - 固定した版の成果物 (app の Windows、core の Linux 2 つと Windows) の sha256 と manifest が固定した値と同じで、新しい版が
#     無ければ exit 0
#   - 固定した版の成果物の sha256 が変わった (core の Linux の target も)・manifest の target ごとの sha256 が違うか無い・core の
#     generation が違う・app の core_min が固定した core より新しいときは exit 1 で、何が違うかを出す
#   - 固定した版より新しい版が猶予 (7 日) の中なら ※ の行で知らせて exit 0 (GitHub Actions の中なら ::notice の行にも)
#   - 猶予がたった新しい版があれば exit 1 で、いちばん新しい版と、その sha256 (core は target ごと。無い target は無いと出す)・
#     core_min と、ソースが HERDR_RELEASES_URL を
#     読むか (読まなければ上げないこと) と、固定した版からの差分の URL を出す。core の generation が固定と違えば、app と一緒に
#     上げると出す。Windows の成果物が無い (HEAD が 404) 版は数えない。redirect の先の Last-Modified を読む
#   - 新しい版の HEAD が 404 のほか (5xx など) か、Last-Modified が無ければ、黙って飛ばさずに exit 2
#   - tag は gh api --paginate で全部読む
#   - GitHub Actions の中なら、知らせることを ::error の行にも出す
#   - 落とせない・gh が失敗する・releases.json が無い・JSON でない・版や sha256 の形でないときは exit 2。知らせることがあれば
#     1 を優先する
#   - 知らない引数は exit 2、-h は使い方を出して exit 0。curl に stdin を渡さない
#   - 見送りの一覧 (releases.json の隣の skipped-versions.txt。「app か core・版・理由」) の版は数えず、猶予がたっていても
#     exit 0 で「見送った」と出す。固定した版以下の行は消してよいと出す。書き損じの行は exit 2
#   - --json は app と core の 2 行の JSON (新しい版を古い順に、見送った版は理由つきで、出た日と差分の URL つき) を出して
#     exit 0。固定した版の成果物は落とし直さない。Windows の成果物の無い版は入れず、HEAD が 404 のほかで落ちた版は出た日を
#     null にして datesProblem にわけを入れる。tag が読めなければ何も出さずに exit 2
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
  write_releases "${d}"
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

# 版つきの成果物の名前。$1: app か core、$2: target
artifact_name() {
  case $1:$2 in
    app:*) echo herdr-app-windows-x86_64.tar.gz ;;
    core:windows-x86_64) echo herdr-core-windows-x86_64.zip ;;
    *) echo "herdr-core-$2.tar.gz" ;;
  esac
}

# 版つきの成果物と manifest と、Last-Modified の headers を置く。$1: case、$2: app か core、$3: 版、$4: 公開日、$5: manifest の
# 追加の項目。target は app が windows-x86_64、core が linux-aarch64・linux-x86_64・windows-x86_64。成果物の中身は
# "<部品> <版> <target>" (sha256 は同じ文字から sha_of で作る)
put_release() {
  local d=$1 kind=$2 v=$3 date=$4 extra=$5 target name entries=''
  local -a targets=(windows-x86_64)
  if [[ ${kind} == core ]]; then targets=(linux-aarch64 linux-x86_64 windows-x86_64); fi
  mkdir -p "${d}/web/${rel}/${kind}/${v}"
  for target in "${targets[@]}"; do
    name=$(artifact_name "${kind}" "${target}")
    printf '%s' "${kind} ${v} ${target}" >"${d}/web/${rel}/${kind}/${v}/${name}"
    printf 'HTTP/2 200\r\nlast-modified: %s\r\ncontent-length: 1\r\n\r\n' "${date}" >"${d}/web/${rel}/${kind}/${v}/${name}.headers"
    entries+="${entries:+, }\"${target}\": {\"url\": \"https://${rel}/${kind}/${v}/${name}\", \"sha256\": \"$(sha_of "${kind} ${v} ${target}")\"}"
  done
  printf '{"version": "%s", %s, "targets": {%s}}\n' "${v}" "${extra}" "${entries}" >"${d}/web/${rel}/${kind}/${v}/manifest.json"
}

# manifest から 1 つの target を消す。$1: case、$2: app か core、$3: 版、$4: target
drop_target() {
  local m="$1/web/${rel}/$2/$3/manifest.json"
  jq --arg t "$4" 'del(.targets[$t])' "${m}" >"${m}.new" && mv "${m}.new" "${m}"
}

# ソースの fixture を置く。$1: case、$2: repo、$3: 版、$4: ファイル、$5: 中身
put_source() {
  mkdir -p "$(dirname "$1/gh/$2/src/$3/$4")"
  printf '%s\n' "$5" >"$1/gh/$2/src/$3/$4"
}

# 固定した版を書いた releases.json (app 0.1.12・core 0.1.17。sha256 は put_release の成果物と同じ)。$1: case。残りは上書き
# (app=<sha>・linux-aarch64=<sha>・linux-x86_64=<sha>・windows-x86_64=<sha>・generation=<値>)
write_releases() {
  local d=$1 kv app la lx win gen=1
  app=$(sha_of 'app 0.1.12 windows-x86_64')
  la=$(sha_of 'core 0.1.17 linux-aarch64')
  lx=$(sha_of 'core 0.1.17 linux-x86_64')
  win=$(sha_of 'core 0.1.17 windows-x86_64')
  shift
  for kv in "$@"; do
    case ${kv} in
      app=*) app=${kv#*=} ;;
      linux-aarch64=*) la=${kv#*=} ;;
      linux-x86_64=*) lx=${kv#*=} ;;
      windows-x86_64=*) win=${kv#*=} ;;
      generation=*) gen=${kv#*=} ;;
    esac
  done
  cat >"${d}/releases.json" <<EOF
{
  "app": {"version": "0.1.12", "sha256": {"windows-x86_64": "${app}"}},
  "core": {"version": "0.1.17", "generation": ${gen}, "sha256": {"linux-aarch64": "${la}", "linux-x86_64": "${lx}", "windows-x86_64": "${win}"}}
}
EOF
}

# $1: case、残り: script の引数 (既定は releases.json)。環境変数は呼び出し側で付ける
run() {
  local d=$1
  shift
  local args=("$@")
  if ((${#args[@]} == 0)); then
    args=("${d}/releases.json")
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
if [[ $(rc "${d}") == 0 ]] && seen "${d}" -F '同じ: app 0.1.12 の成果物 (windows-x86_64) の sha256' \
  && seen "${d}" -F '同じ: core 0.1.17 の成果物 (linux-aarch64) の sha256' && seen "${d}" -F '同じ: core 0.1.17 の成果物 (linux-x86_64) の sha256' \
  && seen "${d}" -F '同じ: core 0.1.17 の成果物 (windows-x86_64) の sha256' \
  && seen "${d}" -F '新しい版は無い: app 0.1.12 が最新' && ! seen "${d}" '^::'; then
  ok "固定した版 (core は 3 つの target) が揃っていて新しい版も無ければ exit 0 (Actions の外では ::error を出さない)"
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
if [[ $(rc "${d}") == 1 ]] && seen "${d}" -F "app 0.1.12 の成果物 (windows-x86_64) の sha256 が、固定した値 $(sha_of 'app 0.1.12 windows-x86_64') と違う (今は $(sha_of 'tampered'))" \
  && grep -q '^::error title=herdr-app の固定した版::app 0.1.12 の成果物 (windows-x86_64) の sha256' "${d}/out"; then
  ok "固定した版の成果物の sha256 が変われば exit 1 で、今の値を出す (Actions の中では ::error も)"
else
  ng "成果物が変わった" "rc=$(rc "${d}") $(outerr "${d}")"
fi
d=$(new_case c2b)
printf '%s' 'tampered' >"${d}/web/${rel}/core/0.1.17/herdr-core-linux-x86_64.tar.gz"
run "${d}"
if [[ $(rc "${d}") == 1 ]] && seen "${d}" -F "core 0.1.17 の成果物 (linux-x86_64) の sha256 が、固定した値 $(sha_of 'core 0.1.17 linux-x86_64') と違う" \
  && seen "${d}" -F '同じ: core 0.1.17 の成果物 (windows-x86_64) の sha256'; then
  ok "core の Linux の target の成果物が変わっても exit 1 (Linux の home-manager が入れるもの)"
else
  ng "Linux の成果物が変わった" "rc=$(rc "${d}") $(outerr "${d}")"
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
sed -i "s/$(sha_of 'app 0.1.12 windows-x86_64')/$(printf '%064d' 0)/" "${d}/web/${rel}/app/0.1.12/manifest.json"
run "${d}"
d2=$(new_case c3c)
drop_target "${d2}" core 0.1.17 linux-aarch64
run "${d2}"
if [[ $(rc "${d}") == 1 && $(rc "${d2}") == 1 ]] && seen "${d}" -F "app 0.1.12 の manifest の windows-x86_64 の sha256 ($(printf '%064d' 0)) が、固定した値" \
  && seen "${d2}" -F "core 0.1.17 の manifest の linux-aarch64 の sha256 (無い) が、固定した値"; then
  ok "manifest の target の sha256 が固定した値と違う・無ければ exit 1"
else
  ng "manifest の sha256" "rc=$(rc "${d}")/$(rc "${d2}") $(outerr "${d}") $(outerr "${d2}")"
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
if [[ $(rc "${d}") == 1 ]] && seen "${d}" -F "app の新しい版 0.1.13 が公開から 15 日たった (公開 2026-11-04・猶予 7 日)。sha256 $(sha_of 'app 0.1.13 windows-x86_64')・core_min 0.1.11。ソース (src/update.rs) は HERDR_RELEASES_URL を読む" \
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
  && seen "${d}" -F "sha256 linux-aarch64 $(sha_of 'core 0.1.18 linux-aarch64')・linux-x86_64 $(sha_of 'core 0.1.18 linux-x86_64')・windows-x86_64 $(sha_of 'core 0.1.18 windows-x86_64')・generation 1" \
  && seen "${d}" -F 'ソース (crates/herdr-core/src/releases.rs) が HERDR_RELEASES_URL を読まない。上げると取得元をフィードに替えられない (公式から上がる) ので、上げない'; then
  ok "猶予がたった core は target ごとの sha256 を出し、ソースが変数を読まなければ、上げないと出す"
else
  ng "変数を読まない" "rc=$(rc "${d}") $(outerr "${d}")"
fi
d=$(new_case c6b)
put_release "${d}" core 0.1.18 "${old_date}" '"generation": 1'
drop_target "${d}" core 0.1.18 linux-aarch64
printf 'v0.1.18\n' >>"${d}/gh/herdrdev/herdr-core/tags"
put_source "${d}" herdrdev/herdr-core 0.1.18 crates/herdr-core/src/releases.rs 'std::env::var("HERDR_RELEASES_URL")'
run "${d}"
if [[ $(rc "${d}") == 1 ]] && seen "${d}" -F 'sha256 linux-aarch64 無い (この版には上げられない)・linux-x86_64'; then
  ok "猶予がたった core の manifest に無い target は、無い (上げられない) と出す"
else
  ng "target の無い新しい版" "rc=$(rc "${d}") $(outerr "${d}")"
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

# 8. 確かめられない: 固定した版を落とせない・gh が失敗する・releases.json が読めない
d=$(new_case c8)
rm "${d}/web/${rel}/core/0.1.17/herdr-core-windows-x86_64.zip"
run "${d}"
d2=$(new_case c8b)
FAKE_GH_FAIL=1 run "${d2}"
d3=$(new_case c8c)
write_releases "${d3}" app=not-a-sha linux-x86_64=ABC
run "${d3}"
d4=$(new_case c8d)
run "${d4}" "${d4}/missing.json"
d5=$(new_case c8e)
printf 'not json\n' >"${d5}/releases.json"
run "${d5}"
if [[ $(rc "${d}") == 2 && $(rc "${d2}") == 2 && $(rc "${d3}") == 2 && $(rc "${d4}") == 2 && $(rc "${d5}") == 2 ]] \
  && seen "${d}" -F 'core 0.1.17 の成果物 (windows-x86_64) を落とせない' && seen "${d2}" -F 'tag を読めない' \
  && seen "${d3}" -F 'releases.json から固定した版と sha256 を読めません' && seen "${d3}" -F 'app.sha256.windows-x86_64=not-a-sha' \
  && seen "${d3}" -F 'core.sha256.linux-x86_64=ABC' && seen "${d4}" -F 'releases.json が読めません' && seen "${d5}" -F 'releases.json が読めません'; then
  ok "落とせない・gh が失敗する・releases.json の値の形が違う・無い・JSON でないときは exit 2"
else
  ng "確かめられない" "rc=$(rc "${d}")/$(rc "${d2}")/$(rc "${d3}")/$(rc "${d4}")/$(rc "${d5}") $(outerr "${d}") $(outerr "${d2}") $(outerr "${d3}")"
fi

# 9. 知らせることと確かめられないことが両方あれば exit 1
d=$(new_case c9)
printf '%s' 'tampered' >"${d}/web/${rel}/app/0.1.12/herdr-app-windows-x86_64.tar.gz"
rm "${d}/web/${rel}/core/0.1.17/herdr-core-windows-x86_64.zip"
run "${d}"
if [[ $(rc "${d}") == 1 ]] && seen "${d}" -F '落とせない' && seen "${d}" -F 'の sha256 が、固定した値'; then
  ok "知らせることと確かめられないことが両方あれば exit 1 (両方を出す)"
else
  ng "両方" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 11. 見送った新しい版は、猶予がたっていても数えずに exit 0。固定した版以下の行は消してよいと出す
d=$(new_case c11)
put_release "${d}" app 0.1.13 "${old_date}" '"core_min": "0.1.11"'
printf 'v0.1.13\n' >>"${d}/gh/herdrdev/herdr-app/tags"
printf '# 見送り\napp 0.1.13 窓が開かなかった\ncore 0.1.16 前の版の行\n' >"${d}/skipped-versions.txt"
run "${d}"
if [[ $(rc "${d}") == 0 ]] && seen "${d}" -F 'app 0.1.13 は見送った (窓が開かなかった)' \
  && ! seen "${d}" -F '公開から 15 日たった' && seen "${d}" -F '見送りの一覧' \
  && seen "${d}" -F 'core 0.1.16 は固定した版 (0.1.17) 以下なので、消してよい' \
  && ! grep -q 'app/0.1.13/herdr-app-windows-x86_64.tar.gz' "${d}/curl-calls"; then
  ok "見送った新しい版は数えずに exit 0 (成果物の HEAD も打たない)。固定した版以下の行は消してよいと出す"
else
  ng "見送り" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 12. 見送りの一覧の書き損じ (部品の名前・版の形・理由が無い) は exit 2
d=$(new_case c12)
printf 'herdr 0.1.13 違う名前\n' >"${d}/skipped-versions.txt"
run "${d}"
d2=$(new_case c12b)
printf 'app 0.1.13\n' >"${d2}/skipped-versions.txt"
run "${d2}"
if [[ $(rc "${d}") == 2 && $(rc "${d2}") == 2 ]] && seen "${d}" -F '見送りの一覧の 1 行目が読めません' && seen "${d2}" -F 'app か core・版・理由'; then
  ok "見送りの一覧の書き損じは exit 2"
else
  ng "見送りの書き損じ" "rc=$(rc "${d}")/$(rc "${d2}") $(outerr "${d}") $(outerr "${d2}")"
fi

# 13. --json: app と core の 2 行。新しい版を古い順に、見送った版は理由つき・出た日なしで出す。Windows の成果物の無い版は
#     入れない。固定した版の成果物は落とし直さない (-o の curl を打たない)
d=$(new_case c13)
put_release "${d}" app 0.1.13 "${old_date}" '"core_min": "0.1.11"'
put_release "${d}" app 0.1.14 "${new_date}" '"core_min": "0.1.11"'
printf 'v0.1.14\nv0.1.13\nv0.1.15\n' >>"${d}/gh/herdrdev/herdr-app/tags"
printf 'core 0.1.18 試したら落ちた\n' >"${d}/skipped-versions.txt"
printf 'v0.1.18\n' >>"${d}/gh/herdrdev/herdr-core/tags"
run "${d}" --json "${d}/releases.json"
if [[ $(rc "${d}") == 0 && $(grep -c '' "${d}/out") == 2 ]] \
  && jq -se '.[0].name == "herdr-app" and .[0].pinned == "0.1.12" and .[0].packageId == null
    and .[0].datesFrom == "last-modified" and .[0].datesChecked == true and .[0].readmeSection == "固定した版を上げる"
    and ([.[0].newer[].version] == ["0.1.13", "0.1.14"])
    and .[0].newer[0].published == "2026-11-04" and .[0].newer[0].age == 15
    and .[0].newer[1].age == 1 and .[0].newer[1].url == "https://github.com/herdrdev/herdr-app/compare/v0.1.12...v0.1.14"
    and .[1].name == "herdr-core" and .[1].title == "herdr-core"
    and .[1].newer == [{"version": "0.1.18", "skipped": "試したら落ちた", "published": null, "age": null,
      "url": "https://github.com/herdrdev/herdr-core/compare/v0.1.17...v0.1.18"}]' "${d}/out" >/dev/null \
  && ! grep -q -- ' -o ' "${d}/curl-calls"; then
  ok "--json: app と core の 2 行に新しい版を出し (見送った版は理由つき・成果物の無い版は入れない)、成果物は落とし直さない"
else
  ng "--json" "rc=$(rc "${d}") $(outerr "${d}") curl=$(cat "${d}/curl-calls" 2>/dev/null)"
fi

# 14. --json: HEAD が 404 のほかで落ちた版は出た日を null にし、datesProblem にわけを入れる。tag が読めなければ exit 2
d=$(new_case c14)
put_release "${d}" app 0.1.13 "${old_date}" '"core_min": "0.1.11"'
printf 'HTTP/2 503\r\n\r\n' >"${d}/web/${rel}/app/0.1.13/herdr-app-windows-x86_64.tar.gz.headers"
printf 'v0.1.13\n' >>"${d}/gh/herdrdev/herdr-app/tags"
run "${d}" --json "${d}/releases.json"
d2=$(new_case c14b)
FAKE_GH_FAIL=1 run "${d2}" --json "${d2}/releases.json"
if [[ $(rc "${d}") == 0 ]] && jq -se '.[0].datesChecked == false and (.[0].datesProblem | test("app 0.1.13"))
    and .[0].newer[0].version == "0.1.13" and .[0].newer[0].published == null' "${d}/out" >/dev/null \
  && [[ $(rc "${d2}") == 2 && ! -s ${d2}/out ]] && seen "${d2}" -F 'tag を読めない'; then
  ok "--json: HEAD が落ちた版は出た日を null にして datesProblem に入れ、tag が読めなければ何も出さずに exit 2"
else
  ng "--json の失敗" "rc=$(rc "${d}")/$(rc "${d2}") $(outerr "${d}") $(outerr "${d2}")"
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
