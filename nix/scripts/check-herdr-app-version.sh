#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows の herdr-app と herdr-core の、dotfiles が固定した版を確かめ、上げられる新しい版を知らせる。
#
#   check-herdr-app-version.sh [<Install-HerdrApp.ps1>]
#
# 固定した版と sha256 は win/herdr-app/Install-HerdrApp.ps1 の -AppVersion・-AppSha256・-CoreVersion・-CoreSha256・
# -CoreGeneration の既定値 (書くのはそこ 1 か所だけ)。Install-HerdrApp.ps1 は、その版を入れ、app と core の自己更新の取得元
# (HERDR_RELEASES_URL) を、その版だけを載せた手元のフィードに向ける (win/README.md の「herdr-app」)。
#
# GitHub Actions の herdr-app-installers (.github/workflows/herdr-app-installers.yml) が週 1 回と PR で流し、落ちることで
# 知らせる。win/ は flake からは見えない (ADR 010) ので、checkout の上で走らせる。手元でも打てる (gh のログインが要る)。
#
# ## 確かめること
#
# 1. 固定した版の成果物 (releases.herdr.dev の app/<版>/herdr-app-windows-x86_64.tar.gz・core/<版>/herdr-core-windows-x86_64.zip)
#    を落とし直し、sha256 が固定した値と同じか。公開の後で取得元の成果物が差し替えられると、ここで気づく (exit 1)
# 2. 固定した版の manifest (app/<版>/manifest.json・core/<版>/manifest.json) の windows-x86_64 の sha256 が固定した値と同じか、
#    core の generation が固定した値と同じか、app の core_min が固定した core の版以下か (exit 1)
# 3. 固定した版より新しい版 (GitHub の tag vX.Y.Z を並べ、版つきの成果物が releases.herdr.dev にあるもの) のうち、公開
#    (成果物の Last-Modified) から猶予の 7 日がたったもの。あれば、いちばん新しいものを知らせる (exit 1)。その版の
#    sha256 (と app なら core_min) と、その版のソースが HERDR_RELEASES_URL を読むか (app は src/update.rs、core は
#    crates/herdr-core/src/releases.rs) を添える。読まない版に上げると、取得元をフィードに替えられない (公式から上がる)。
#    猶予の中の版だけなら、※ の行で知らせて exit 0 (GitHub Actions の中なら ::notice の行にも)
#
# 署名 (Authenticode) はここでは見ない。Linux の信頼の束に Microsoft のコード署名の root が無いので、Windows の
# Install-HerdrApp.ps1 が入れる前と -Check で見る。
#
# 終了コード: 0 = 知らせることは無い、1 = 知らせることがある、2 = 確かめられなかった (ps1 が読めない・落とせない・
# API の失敗)。1 と 2 が両方あれば 1。GitHub Actions の中では、落ちる理由を ::error の行にも出す。
#
# ## 依存
#
# bash・curl・gh (GitHub API。CI では GH_TOKEN)・jq・sha256sum・base64・date (GNU)・sort (-V)。GitHub の ubuntu の
# ランナーにはどれも最初から入っている。

set -eu -o pipefail

# 新しい版を知らせるまでの猶予 (公開からの日数)。決めるのはここ 1 か所だけ。テストは CHECK_HERDR_APP_GRACE_DAYS で変える
grace_days=${CHECK_HERDR_APP_GRACE_DAYS:-7}
# 今の時刻 (UNIX 秒)。テストは CHECK_HERDR_APP_NOW で決める
now=${CHECK_HERDR_APP_NOW:-$(date +%s)}
releases='https://releases.herdr.dev'

script_dir=$(
  cd -- "$(dirname -- "$0")" &>/dev/null
  pwd -P
)
repo_dir=$(dirname "$(dirname "${script_dir}")")

usage() {
  cat <<'EOS'
Windows の herdr-app と herdr-core の、dotfiles が固定した版を確かめ、上げられる新しい版を知らせる。

使い方:
  check-herdr-app-version.sh [<Install-HerdrApp.ps1>]

  ps1 の既定は repo の win/herdr-app/Install-HerdrApp.ps1 (固定した版と sha256 は、その -AppVersion などの既定値)。

終了コード: 0 = 知らせることは無い、1 = 知らせることがある、2 = 確かめられなかった
EOS
}

args=()
for arg in "$@"; do
  case ${arg} in
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "不明な引数です: ${arg}" >&2
      usage >&2
      exit 2
      ;;
    *) args+=("${arg}") ;;
  esac
done
if ((${#args[@]} > 1)); then
  usage >&2
  exit 2
fi
ps1=${args[0]:-${repo_dir}/win/herdr-app/Install-HerdrApp.ps1}

# GitHub Actions の中なら、実行の画面の先頭に出る ::<$1> の行 (error か notice) を出す (% と改行は決まりどおりに書き換える)
annotate() {
  local level=$1 m=$2
  [[ ${GITHUB_ACTIONS-} == true ]] || return 0
  m=${m//'%'/'%25'}
  m=${m//$'\r'/'%0D'}
  m=${m//$'\n'/'%0A'}
  echo "::${level} title=herdr-app の固定した版::${m}"
}

changed=0
broken=0
# 知らせること (exit 1)
report() {
  echo "!! $1"
  annotate error "$1"
  changed=1
}
# 確かめられなかったこと (exit 2)
trouble() {
  echo "!! 確かめられなかった: $1" >&2
  annotate error "確かめられなかった: $1"
  broken=1
}

# $1 が $2 より新しいか (sort -V で数として比べる)
newer_than() {
  [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]
}

# ps1 の param の既定値を読む。$1: 名前 (AppVersion など)。'…' で囲んだ値か、数
ps1_default() {
  local line value
  line=$(grep -m 1 -E "^[[:space:]]*\[(string|int)\]\\\$$1[[:space:]]*=" "${ps1}") || true
  value=${line#*=}
  value=${value%,}
  value=${value//[[:space:]]/}
  value=${value#\'}
  value=${value%\'}
  printf '%s' "${value}"
}

if [[ ! -r ${ps1} ]]; then
  echo "!! ps1 が読めません: ${ps1}" >&2
  annotate error "ps1 が読めません: ${ps1}"
  exit 2
fi
app_version=$(ps1_default AppVersion)
app_sha=$(ps1_default AppSha256)
core_version=$(ps1_default CoreVersion)
core_sha=$(ps1_default CoreSha256)
core_generation=$(ps1_default CoreGeneration)
version_re='^[0-9]+\.[0-9]+\.[0-9]+$'
if [[ ! ${app_version} =~ ${version_re} || ! ${core_version} =~ ${version_re} || ! ${app_sha} =~ ^[0-9a-f]{64}$ ||
  ! ${core_sha} =~ ^[0-9a-f]{64}$ || ! ${core_generation} =~ ^[1-9][0-9]*$ ]]; then
  echo "!! ps1 から固定した版と sha256 を読めません (AppVersion=${app_version} AppSha256=${app_sha} CoreVersion=${core_version} CoreSha256=${core_sha} CoreGeneration=${core_generation}): ${ps1}" >&2
  annotate error "ps1 から固定した版と sha256 を読めません: ${ps1}"
  exit 2
fi
echo "固定した版: app ${app_version} (sha256 ${app_sha:0:12}…)・core ${core_version} (sha256 ${core_sha:0:12}…・generation ${core_generation})"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/check-herdr-app-version.XXXXXX")
trap 'rm -rf "${tmp}"' EXIT

# 版つきの成果物の URL。$1: app か core、$2: 版
artifact_url() {
  if [[ $1 == app ]]; then
    echo "${releases}/app/$2/herdr-app-windows-x86_64.tar.gz"
  else
    echo "${releases}/core/$2/herdr-core-windows-x86_64.zip"
  fi
}

# URL を $2 に落とす。落とせなければ 1 (stdin は渡さない)
fetch() {
  curl -fsSL --max-time 300 -o "$2" "$1" </dev/null
}

# 成果物が公開された時刻 (Last-Modified。UNIX 秒)。成果物が無い (この版に Windows の成果物が無い) か読めなければ 1
published_at() {
  local headers line lm=''
  headers=$(curl -fsSI --max-time 60 "$1" </dev/null) || return 1
  while IFS= read -r line; do
    line=${line%$'\r'}
    if [[ ${line,,} == last-modified:* ]]; then
      lm=${line#*:}
      lm=${lm# }
      break
    fi
  done <<<"${headers}"
  [[ -n ${lm} ]] || return 1
  date -d "${lm}" +%s
}

# GitHub の repo の、版の形の tag (vX.Y.Z) の版 (v を外し、古い順)。$1: repo
tag_versions() {
  gh api "repos/$1/tags?per_page=100" --jq '.[].name' </dev/null >"${tmp}/tags" || return 1
  sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' "${tmp}/tags" | sort -V
}

# その版のソースが HERDR_RELEASES_URL を読むか。$1: repo、$2: 版、$3: ファイル。読めば 0、読まなければ 1、確かめられなければ 2
reads_feed_variable() {
  local file="${tmp}/source"
  if ! gh api "repos/$1/contents/$3?ref=v$2" --jq .content </dev/null >"${file}.b64"; then
    return 2
  fi
  base64 -d <"${file}.b64" >"${file}" 2>/dev/null || return 2
  if grep -qF '"HERDR_RELEASES_URL"' "${file}"; then
    return 0
  fi
  return 1
}

# 1 つの部品 (app か core) を確かめる。$1: app か core、$2: 固定した版、$3: 固定した sha256、$4: GitHub の repo、
# $5: HERDR_RELEASES_URL を読むはずのソース
check_one() {
  local kind=$1 pinned=$2 sha=$3 repo=$4 src_file=$5
  local file="${tmp}/${kind}-pinned" got manifest="${tmp}/${kind}-manifest.json" listed

  # 1. 固定した版の成果物を落とし直して sha256 を比べる
  if fetch "$(artifact_url "${kind}" "${pinned}")" "${file}"; then
    got=$(sha256sum "${file}")
    got=${got%% *}
    if [[ ${got} == "${sha}" ]]; then
      echo "同じ: ${kind} ${pinned} の成果物の sha256 (${sha:0:12}…)"
    else
      report "${kind} ${pinned} の成果物の sha256 が、固定した値 ${sha} と違う (今は ${got})。公開の後で取得元の成果物が差し替えられたかもしれない。win/README.md の「固定した版の成果物が変わったとき」"
    fi
  else
    trouble "${kind} ${pinned} の成果物を落とせない: $(artifact_url "${kind}" "${pinned}")"
  fi

  # 2. 固定した版の manifest の sha256 (と generation・core_min)
  if fetch "${releases}/${kind}/${pinned}/manifest.json" "${manifest}"; then
    listed=$(jq -r '.targets["windows-x86_64"].sha256 // ""' "${manifest}" 2>/dev/null) || listed=''
    if [[ ${listed} != "${sha}" ]]; then
      report "${kind} ${pinned} の manifest の sha256 (${listed:-無い}) が、固定した値 ${sha} と違う"
    fi
    if [[ ${kind} == core ]]; then
      local generation
      generation=$(jq -r '.generation // ""' "${manifest}" 2>/dev/null) || generation=''
      if [[ ${generation} != "${core_generation}" ]]; then
        report "core ${pinned} の manifest の generation (${generation:-無い}) が、固定した値 ${core_generation} と違う"
      fi
    else
      local core_min
      core_min=$(jq -r '.core_min // ""' "${manifest}" 2>/dev/null) || core_min=''
      if [[ -n ${core_min} ]] && newer_than "${core_min}" "${core_version}"; then
        report "app ${pinned} の core_min (${core_min}) が、固定した core ${core_version} より新しい。core を ${core_min} 以上に上げる"
      fi
    fi
  else
    trouble "${kind} ${pinned} の manifest を落とせない: ${releases}/${kind}/${pinned}/manifest.json"
  fi

  # 3. 固定した版より新しい版のうち、猶予がたったもの
  local versions v t age ripe='' ripe_age='' ripe_at='' waiting='' listed_versions=()
  if ! versions=$(tag_versions "${repo}"); then
    trouble "GitHub の ${repo} の tag を読めない (gh api repos/${repo}/tags)"
    return 0
  fi
  mapfile -t listed_versions <<<"${versions}"
  for v in "${listed_versions[@]}"; do
    newer_than "${v}" "${pinned}" || continue
    # 版つきの成果物が無い版 (Windows の成果物を出さなかった版) は数えない
    t=$(published_at "$(artifact_url "${kind}" "${v}")") || continue
    age=$(((now - t) / 86400))
    if ((age >= grace_days)); then
      ripe=${v}
      ripe_age=${age}
      ripe_at=$(date -u -d "@${t}" '+%Y-%m-%d')
    else
      waiting+="${v} (公開 $(date -u -d "@${t}" '+%Y-%m-%d'), ${age} 日前。あと $((grace_days - age)) 日)、"
    fi
  done
  if [[ -n ${ripe} ]]; then
    local ripe_manifest="${tmp}/${kind}-ripe.json" ripe_sha='' extra='' reads
    if fetch "${releases}/${kind}/${ripe}/manifest.json" "${ripe_manifest}"; then
      ripe_sha=$(jq -r '.targets["windows-x86_64"].sha256 // ""' "${ripe_manifest}" 2>/dev/null) || ripe_sha=''
      if [[ ${kind} == app ]]; then
        extra="・core_min $(jq -r '.core_min // "?"' "${ripe_manifest}" 2>/dev/null || echo '?')"
      else
        extra="・generation $(jq -r '.generation // "?"' "${ripe_manifest}" 2>/dev/null || echo '?')"
      fi
    fi
    reads=0
    reads_feed_variable "${repo}" "${ripe}" "${src_file}" || reads=$?
    local feed_note
    case ${reads} in
      0) feed_note="ソース (${src_file}) は HERDR_RELEASES_URL を読む" ;;
      1) feed_note="ソース (${src_file}) が HERDR_RELEASES_URL を読まない。上げると取得元をフィードに替えられない (公式から上がる) ので、上げない" ;;
      *) feed_note="ソース (${src_file}) が HERDR_RELEASES_URL を読むかを確かめられなかった (上げる前に確かめる)" ;;
    esac
    report "${kind} の新しい版 ${ripe} が公開から ${ripe_age} 日たった (公開 ${ripe_at}・猶予 ${grace_days} 日)。sha256 ${ripe_sha:-不明}${extra}。${feed_note}。上げ方は win/README.md の「固定した版を上げる」"
  fi
  if [[ -n ${waiting} ]]; then
    local note="${kind} の新しい版 ${waiting%、} は猶予の中 (固定した版 ${pinned})"
    echo "  ※ ${note}"
    annotate notice "${note}"
  fi
  if [[ -z ${ripe} && -z ${waiting} ]]; then
    echo "新しい版は無い: ${kind} ${pinned} が最新"
  fi
}

check_one app "${app_version}" "${app_sha}" herdrdev/herdr-app src/update.rs
check_one core "${core_version}" "${core_sha}" herdrdev/herdr-core crates/herdr-core/src/releases.rs

if ((changed)); then
  exit 1
fi
if ((broken)); then
  exit 2
fi
echo "固定した版の成果物は変わっておらず、猶予のたった新しい版も無い。"
