#!/usr/bin/env bash
# shellcheck shell=bash
#
# herdr-app と herdr-core の、dotfiles が固定した版を確かめ、上げられる新しい版を知らせる。
#
#   check-herdr-app-version.sh [<releases.json>]
#
# 固定した版と sha256 は nix/pkgs/herdr-core/releases.json (書くのはそこ 1 か所だけ)。app の版と windows-x86_64 の sha256、
# core の版・generation と linux-aarch64・linux-x86_64・windows-x86_64 の sha256 を持つ。Windows の
# win/herdr-app/Install-HerdrApp.ps1 は、その版を入れ、app と core の自己更新の取得元 (HERDR_RELEASES_URL) を、その版だけを
# 載せた手元のフィードに向ける (win/README.md の「herdr-app」)。Linux の home-manager は、同じ版の core を入れる
# (nix/pkgs/herdr-core。nix/README.md の「herdr-core (hc) を Nix で入れる」)。
#
# GitHub Actions の herdr-app-installers (.github/workflows/herdr-app-installers.yml) が週 1 回と PR で流し、落ちることで
# 知らせる。手元でも打てる (gh のログインが要る)。
#
# ## 確かめること
#
# 1. 固定した版の成果物 (releases.herdr.dev の app/<版>/herdr-app-windows-x86_64.tar.gz と、core/<版>/ の
#    herdr-core-windows-x86_64.zip・herdr-core-linux-x86_64.tar.gz・herdr-core-linux-aarch64.tar.gz) を落とし直し、sha256 が
#    固定した値と同じか。公開の後で取得元の成果物が差し替えられると、ここで気づく (exit 1)
# 2. 固定した版の manifest (app/<版>/manifest.json・core/<版>/manifest.json) の target ごとの sha256 が固定した値と同じか、
#    core の generation が固定した値と同じか、app の core_min が固定した core の版以下か (exit 1)
# 3. 固定した版より新しい版 (GitHub の tag vX.Y.Z を並べ、Windows の版つきの成果物が releases.herdr.dev にあるもの) のうち、
#    公開 (成果物の Last-Modified) から猶予の 7 日がたったもの。あれば、いちばん新しいものを知らせる (exit 1)。その版の
#    sha256 (core は target ごと。manifest に無い target は無いと出す) と、app なら core_min、core なら generation (固定と
#    違えば、app と一緒に上げると出す) と、その版のソースが HERDR_RELEASES_URL を読むか (app は src/update.rs、core は
#    crates/herdr-core/src/releases.rs) と、固定した版からの差分の URL を添える。読まない版に上げると、取得元をフィードに
#    替えられない (公式から上がる)。文字があるかしか見ないので、上げる前に差分を読む。猶予の中の版だけなら、※ の行で
#    知らせて exit 0 (GitHub Actions の中なら ::notice の行にも)。成果物が無い (404) 版は数えず、HEAD のほかの失敗 (5xx・
#    403・つながらない・Last-Modified が無い) は確かめられない (exit 2)
#
# 署名 (Authenticode) はここでは見ない。Linux の信頼の束に Microsoft のコード署名の root が無いので、Windows の
# Install-HerdrApp.ps1 が入れる前と -Check で見る。
#
# 終了コード: 0 = 知らせることは無い、1 = 知らせることがある、2 = 確かめられなかった (releases.json が読めない・落とせない・
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
# 部品ごとの target (releases.json の sha256 の名前。公式の manifest の targets の名前と同じ)
app_targets=(windows-x86_64)
core_targets=(linux-aarch64 linux-x86_64 windows-x86_64)

script_dir=$(
  cd -- "$(dirname -- "$0")" &>/dev/null
  pwd -P
)
repo_dir=$(dirname "$(dirname "${script_dir}")")

usage() {
  cat <<'EOS'
herdr-app と herdr-core の、dotfiles が固定した版を確かめ、上げられる新しい版を知らせる。

使い方:
  check-herdr-app-version.sh [<releases.json>]

  releases.json の既定は repo の nix/pkgs/herdr-core/releases.json (固定した版と sha256 の 1 か所)。

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
releases_file=${args[0]:-${repo_dir}/nix/pkgs/herdr-core/releases.json}

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

# releases.json の値を読む。$1: jq の式。無ければ空
pin() {
  jq -r "$1 // \"\" | tostring" "${releases_file}" 2>/dev/null || true
}

if [[ ! -r ${releases_file} ]] || ! jq -e 'type == "object"' "${releases_file}" &>/dev/null; then
  echo "!! releases.json が読めません (無い・JSON でない): ${releases_file}" >&2
  annotate error "releases.json が読めません: ${releases_file}"
  exit 2
fi
app_version=$(pin .app.version)
core_version=$(pin .core.version)
core_generation=$(pin .core.generation)
declare -A pinned_sha=()
for target in "${app_targets[@]}"; do
  pinned_sha["app:${target}"]=$(pin ".app.sha256[\"${target}\"]")
done
for target in "${core_targets[@]}"; do
  pinned_sha["core:${target}"]=$(pin ".core.sha256[\"${target}\"]")
done
version_re='^[0-9]+\.[0-9]+\.[0-9]+$'
bad=''
[[ ${app_version} =~ ${version_re} ]] || bad+=" app.version=${app_version}"
[[ ${core_version} =~ ${version_re} ]] || bad+=" core.version=${core_version}"
[[ ${core_generation} =~ ^[1-9][0-9]*$ ]] || bad+=" core.generation=${core_generation}"
for key in "${!pinned_sha[@]}"; do
  [[ ${pinned_sha["${key}"]} =~ ^[0-9a-f]{64}$ ]] || bad+=" ${key%%:*}.sha256.${key#*:}=${pinned_sha["${key}"]}"
done
if [[ -n ${bad} ]]; then
  echo "!! releases.json から固定した版と sha256 を読めません (${bad# }): ${releases_file}" >&2
  annotate error "releases.json から固定した版と sha256 を読めません: ${releases_file}"
  exit 2
fi
core_pins=''
for target in "${core_targets[@]}"; do
  core_pins+="${core_pins:+・}${target} ${pinned_sha["core:${target}"]:0:12}…"
done
echo "固定した版: app ${app_version} (sha256 ${pinned_sha["app:windows-x86_64"]:0:12}…)・core ${core_version} (generation ${core_generation}。sha256 ${core_pins})"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/check-herdr-app-version.XXXXXX")
trap 'rm -rf "${tmp}"' EXIT

# 版つきの成果物の URL。$1: app か core、$2: 版、$3: target (core の Windows は zip、Linux は tar.gz)
artifact_url() {
  case $1:$3 in
    app:*) echo "${releases}/app/$2/herdr-app-windows-x86_64.tar.gz" ;;
    core:windows-x86_64) echo "${releases}/core/$2/herdr-core-windows-x86_64.zip" ;;
    *) echo "${releases}/core/$2/herdr-core-$3.tar.gz" ;;
  esac
}

# URL を $2 に落とす。落とせなければ 1 (stdin は渡さない)
fetch() {
  curl -fsSL --max-time 300 -o "$2" "$1" </dev/null
}

# 成果物が公開された時刻 (Last-Modified。UNIX 秒) を出す。戻り値: 0 = 出した、3 = 成果物が無い (404。この版に Windows の
# 成果物が無い)、1 = 確かめられない (ほかの HTTP の状態・つながらない・Last-Modified が無いか読めない)。-f を付けずに状態を
# 見て、404 のほかの失敗を「無い」として黙って飛ばさない。-L で redirect の先まで見て、最後の応答を読む
published_at() {
  local headers line status='' lm=''
  headers=$(curl -sSIL --max-time 60 "$1" </dev/null) || return 1
  while IFS= read -r line; do
    line=${line%$'\r'}
    if [[ ${line} =~ ^HTTP/[0-9.]+\ ([0-9]{3}) ]]; then
      status=${BASH_REMATCH[1]}
      lm=''
    elif [[ ${line,,} == last-modified:* ]]; then
      lm=${line#*:}
      lm=${lm# }
    fi
  done <<<"${headers}"
  if [[ ${status} == 404 ]]; then
    return 3
  fi
  [[ ${status} == 200 && -n ${lm} ]] || return 1
  date -d "${lm}" +%s 2>/dev/null || return 1
}

# GitHub の repo の、版の形の tag (vX.Y.Z) の版 (v を外し、古い順)。$1: repo。--paginate で全部読む (並び順は決まっていない)
tag_versions() {
  gh api --paginate "repos/$1/tags?per_page=100" --jq '.[].name' </dev/null >"${tmp}/tags" || return 1
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

# 1 つの部品 (app か core) を確かめる。$1: app か core、$2: 固定した版、$3: GitHub の repo、$4: HERDR_RELEASES_URL を読む
# はずのソース、残り: target
check_one() {
  local kind=$1 pinned=$2 repo=$3 src_file=$4
  shift 4
  local targets=("$@") target sha file got manifest="${tmp}/${kind}-manifest.json" listed

  # 1. 固定した版の成果物を target ごとに落とし直して sha256 を比べる
  for target in "${targets[@]}"; do
    sha=${pinned_sha["${kind}:${target}"]}
    file="${tmp}/${kind}-${target}-pinned"
    if fetch "$(artifact_url "${kind}" "${pinned}" "${target}")" "${file}"; then
      got=$(sha256sum "${file}")
      got=${got%% *}
      if [[ ${got} == "${sha}" ]]; then
        echo "同じ: ${kind} ${pinned} の成果物 (${target}) の sha256 (${sha:0:12}…)"
      else
        report "${kind} ${pinned} の成果物 (${target}) の sha256 が、固定した値 ${sha} と違う (今は ${got})。公開の後で取得元の成果物が差し替えられたかもしれない。win/README.md の「固定した版の成果物が変わったとき」"
      fi
    else
      trouble "${kind} ${pinned} の成果物 (${target}) を落とせない: $(artifact_url "${kind}" "${pinned}" "${target}")"
    fi
  done

  # 2. 固定した版の manifest の target ごとの sha256 (と generation・core_min)
  if fetch "${releases}/${kind}/${pinned}/manifest.json" "${manifest}"; then
    for target in "${targets[@]}"; do
      sha=${pinned_sha["${kind}:${target}"]}
      listed=$(jq -r --arg t "${target}" '.targets[$t].sha256 // ""' "${manifest}" 2>/dev/null) || listed=''
      if [[ ${listed} != "${sha}" ]]; then
        report "${kind} ${pinned} の manifest の ${target} の sha256 (${listed:-無い}) が、固定した値 ${sha} と違う"
      fi
    done
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

  # 3. 固定した版より新しい版のうち、猶予がたったもの。公開日は Windows の成果物で見る (app も core も出す target)
  local versions v t rc age ripe='' ripe_age='' ripe_at='' waiting='' unread=0 listed_versions=()
  if ! versions=$(tag_versions "${repo}"); then
    trouble "GitHub の ${repo} の tag を読めない (gh api repos/${repo}/tags)"
    return 0
  fi
  mapfile -t listed_versions <<<"${versions}"
  for v in "${listed_versions[@]}"; do
    newer_than "${v}" "${pinned}" || continue
    rc=0
    t=$(published_at "$(artifact_url "${kind}" "${v}" windows-x86_64)") || rc=$?
    # 版つきの成果物が無い版 (Windows の成果物を出さなかった版) は数えない
    if ((rc == 3)); then
      continue
    fi
    if ((rc != 0)); then
      trouble "${kind} ${v} の成果物の公開日 (HEAD の Last-Modified) を読めない: $(artifact_url "${kind}" "${v}" windows-x86_64)"
      unread=1
      continue
    fi
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
    local ripe_manifest="${tmp}/${kind}-ripe.json" ripe_sha='' extra='' reads ripe_generation one
    if fetch "${releases}/${kind}/${ripe}/manifest.json" "${ripe_manifest}"; then
      if ((${#targets[@]} == 1)); then
        ripe_sha=$(jq -r --arg t "${targets[0]}" '.targets[$t].sha256 // "不明"' "${ripe_manifest}" 2>/dev/null) || ripe_sha='不明'
      else
        for target in "${targets[@]}"; do
          one=$(jq -r --arg t "${target}" '.targets[$t].sha256 // "無い (この版には上げられない)"' "${ripe_manifest}" 2>/dev/null) || one='不明'
          ripe_sha+="${ripe_sha:+・}${target} ${one}"
        done
      fi
      if [[ ${kind} == app ]]; then
        extra="・core_min $(jq -r '.core_min // "?"' "${ripe_manifest}" 2>/dev/null || echo '?')"
      else
        ripe_generation=$(jq -r '.generation // "?"' "${ripe_manifest}" 2>/dev/null) || ripe_generation='?'
        extra="・generation ${ripe_generation}"
        if [[ ${ripe_generation} != "${core_generation}" ]]; then
          # update --from は generation を見ないので、core だけを上げると app と話せない core が入る
          extra+=" (固定した ${core_generation} と違う。app はこの generation の core と話せる版と一緒に上げる。CHANGELOG で確かめる)"
        fi
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
    report "${kind} の新しい版 ${ripe} が公開から ${ripe_age} 日たった (公開 ${ripe_at}・猶予 ${grace_days} 日)。sha256 ${ripe_sha:-不明}${extra}。${feed_note}。差分 (${src_file} も読む): https://github.com/${repo}/compare/v${pinned}...v${ripe}。上げ方は win/README.md の「固定した版を上げる」"
  fi
  if [[ -n ${waiting} ]]; then
    local note="${kind} の新しい版 ${waiting%、} は猶予の中 (固定した版 ${pinned})"
    echo "  ※ ${note}"
    annotate notice "${note}"
  fi
  if [[ -z ${ripe} && -z ${waiting} ]] && ((! unread)); then
    echo "新しい版は無い: ${kind} ${pinned} が最新"
  fi
}

check_one app "${app_version}" herdrdev/herdr-app src/update.rs "${app_targets[@]}"
check_one core "${core_version}" herdrdev/herdr-core crates/herdr-core/src/releases.rs "${core_targets[@]}"

if ((changed)); then
  exit 1
fi
if ((broken)); then
  exit 2
fi
echo "固定した版の成果物は変わっておらず、猶予のたった新しい版も無い。"
