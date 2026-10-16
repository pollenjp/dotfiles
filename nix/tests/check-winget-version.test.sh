#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/check-winget-version.sh の振る舞いを、偽の gh と手で作った Install-*.ps1 と
# skipped-versions.txt で確かめる。
#
#   bash nix/tests/check-winget-version.test.sh [<script のパス>]
#
# flake の checks (check-winget-version-test) が Nix のサンドボックスで流す。
# CI の `nix flake check` もこれを通る。使うのは bash・jq・coreutils・grep だけ。
#
# ## 確かめること
#
#   - 名前 (openssh・herdr・google-japanese-input) を最初の引数に取る。名前が無い・知らない名前は、gh を
#     呼ばずに exit 2。名前だけ渡すと、repo の win/<ディレクトリ>/ の ps1 と見送りの一覧を読む
#
#   OpenSSH (出た日は GitHub の release):
#   - winget-pkgs の場所は Install-OpenSSH.ps1 のパッケージ ID から組む
#   - 固定した版が winget-pkgs の最新なら exit 0。版は数として比べる (9.8.3.0 < 10.0.0.0)
#   - 固定した版より新しい版があり、見送りの一覧に無ければ、GitHub に出て 30 日 (猶予) たったら exit 1。
#     release notes の URL を添える。29 日までは exit 0 で、版・出た日・あと何日で知らせるかを 1 行出す。
#     新しい版がいくつかあれば、いちばん早く出た版から数える。出た日が分からない版は待たない
#   - 見送りは版ごと。新しい版がどれも見送り済みなら exit 0。見送った版は猶予の数えにも入れない
#   - 固定した版・パッケージが winget-pkgs に無い、版の形でないディレクトリがある、は猶予を置かずに exit 1
#   - GitHub に出た版が 30 日たっても winget に載らない (パッケージ ID が移ったなど) は exit 1。
#     30 日たつまでと、見送った版は落とさない。最新 release に Win64 の MSI が無いのは猶予を置かずに exit 1
#   - 確かめられなかった (固定した版が読めない・見送りの一覧が壊れている・API の失敗・gh が無い・
#     猶予の日数が読めない) は exit 2。release の一覧だけ取れず、新しい版が出た日が分からないときも exit 2
#   - 猶予の日数は CHECK_WINGET_VERSION_GRACE_DAYS で変えられる
#   - GitHub Actions の中では、落ちるときに ::error の行を、猶予の中の版には ::notice の行を出す
#
#   herdr (出た日は GitHub の preview の release):
#   - Install-Herdr.ps1 の形 (版は <semver>-preview.<日付>-<hash>、$packageId は関数の中) から読み、
#     winget-pkgs の manifests/h/Herdr/Herdr/Preview と herdrdev/herdr の release を見る。
#     固定した版が herdr の版の形でなければ、gh を呼ばずに exit 2
#   - 版は数として比べる (0.10.0-preview… は 0.9.4-preview… より新しい)。その形でないディレクトリは exit 1
#   - 出た日は、版の -preview. の後ろと tag の preview- の後ろが同じ release が出た日 (版の中の日付ではない)
#   - GitHub と比べるのは preview (prerelease) だけ。winget に無い安定版 (vX.Y.Z) と、winget の最新より
#     古い preview と、winget にある preview は数えない。winget の最新より新しい preview が 30 日たっても
#     載らなければ exit 1
#   - 最新の preview の tag が preview-<日付>-<hash> の形でなければ、猶予を置かずに exit 1
#   - 見送りの一覧の版も herdr の版の形で読み、GitHub の preview とは -preview. の後ろで照らす
#   - 固定した版より古い winget の版は並べず、数だけを出す。GitHub Actions の ::error の行の題は Windows の herdr
#
#   Google 日本語入力 (出た日は winget-pkgs に載った日):
#   - winget-pkgs の manifests/g/Google/JapaneseIME を見る (.validation のファイルは版として数えない)。
#     GitHub の release は引かない
#   - 新しい版ごとに、その版のディレクトリの commit の一覧を引き、いちばん古い commit (足した commit) の日から
#     数える。30 日たったら exit 1 で manifest の URL を添える。いくつかあれば、いちばん早く載った版から数える
#   - commit の一覧が取れなければ ⚠ を出さずに exit 2、空なら出た日が分からないので待たずに exit 1
#
# ## 本物の gh を見せない
#
# 手元では PATH に本物の gh があり、見えると本物の GitHub API を呼ぶ。要るコマンドだけを
# symlink で並べた PATH で流す (bootstrap-windows-openssh.test.sh と同じ作り)。偽の gh の shebang は
# $BASH から作る (サンドボックスに /usr/bin/env が無い)。偽の gh が返す JSON は、本物の API の
# 応答 (2026-10-15・16 に取ったもの) と同じ形にしてある。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/check-winget-version.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/check-winget-version-test.XXXXXX")
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

# 要るコマンドだけを並べた PATH (gh は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env jq grep sed sort tr cat head tail mktemp rm dirname basename; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# 偽の gh。引数を FAKE_GH_LOG に足し、叩いた API ごとに決めた応答を返す。
#   contents (winget-pkgs のディレクトリ)        FAKE_GH_CONTENTS (stdout)・FAKE_GH_CONTENTS_ERR (stderr)・FAKE_GH_CONTENTS_RC
#   releases (Win32-OpenSSH・herdr)              FAKE_GH_RELEASES・FAKE_GH_RELEASES_ERR・FAKE_GH_RELEASES_RC
#   commits?path=… (winget-pkgs の版の履歴)      FAKE_GH_COMMITS_DIR/<版> の中身 (無ければ空の一覧)・
#                                                FAKE_GH_COMMITS_ERR・FAKE_GH_COMMITS_RC
fake_bin="${work}/fake-bin"
mkdir -p "${fake_bin}"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf '%s\n' "$*" >>"${FAKE_GH_LOG}"
[[ $1 == api ]] || { echo "偽の gh: api 以外は知らない: $*" >&2; exit 99; }
case $2 in
  repos/microsoft/winget-pkgs/contents/*)
    out=${FAKE_GH_CONTENTS-} err=${FAKE_GH_CONTENTS_ERR-} rc=${FAKE_GH_CONTENTS_RC:-0} ;;
  repos/PowerShell/Win32-OpenSSH/releases* | repos/herdrdev/herdr/releases*)
    out=${FAKE_GH_RELEASES-} err=${FAKE_GH_RELEASES_ERR-} rc=${FAKE_GH_RELEASES_RC:-0} ;;
  repos/microsoft/winget-pkgs/commits*)
    p=${2#*path=}
    p=${p%%&*}
    out='[]'
    if [[ -n ${FAKE_GH_COMMITS_DIR-} && -f ${FAKE_GH_COMMITS_DIR}/${p##*/} ]]; then
      out=$(<"${FAKE_GH_COMMITS_DIR}/${p##*/}")
    fi
    err=${FAKE_GH_COMMITS_ERR-} rc=${FAKE_GH_COMMITS_RC:-0}
    [[ ${rc} == 0 ]] || out='' ;;
  *)
    echo "偽の gh: 知らない API: $2" >&2
    exit 99 ;;
esac
[[ -z ${out} ]] || printf '%s\n' "${out}"
[[ -z ${err} ]] || printf '%s\n' "${err}" >&2
exit "${rc}"
EOF
} >"${fake_bin}/gh"
chmod +x "${fake_bin}/gh"

# 今つくっているケースのパッケージ (節ごとに変える)。new_case・contents_json・run が読む
pkg=openssh

# パッケージごとの winget-pkgs の manifest のディレクトリと、ps1 の名前 (script はディレクトリを ps1 の
# パッケージ ID から組むので、ここでは本物の値をそのまま書く)
manifest_dir_of() {
  case $1 in
    openssh) echo manifests/m/Microsoft/OpenSSH/Preview ;;
    herdr) echo manifests/h/Herdr/Herdr/Preview ;;
    google-japanese-input) echo manifests/g/Google/JapaneseIME ;;
  esac
}
ps1_of() {
  case $1 in
    openssh) echo Install-OpenSSH.ps1 ;;
    herdr) echo Install-Herdr.ps1 ;;
    google-japanese-input) echo Install-GoogleJapaneseInput.ps1 ;;
  esac
}

# pkg の winget-pkgs の manifest のディレクトリの一覧 (contents API の応答)。
# 引数は版 (ディレクトリ)。file: で始めるとファイルの項目にする
contents_json() {
  local e base='https://api.github.com/repos/microsoft/winget-pkgs' dir
  dir=$(manifest_dir_of "${pkg}")
  for e in "$@"; do
    if [[ ${e} == file:* ]]; then
      jq -n --arg n "${e#file:}" --arg base "${base}" --arg dir "${dir}" '{
        _links: {
          git: ($base + "/git/blobs/0000000000000000000000000000000000000000"),
          html: ("https://github.com/microsoft/winget-pkgs/blob/master/" + $dir + "/" + $n),
          self: ($base + "/contents/" + $dir + "/" + $n + "?ref=master")
        },
        download_url: ("https://raw.githubusercontent.com/microsoft/winget-pkgs/master/" + $dir + "/" + $n),
        git_url: ($base + "/git/blobs/0000000000000000000000000000000000000000"),
        html_url: ("https://github.com/microsoft/winget-pkgs/blob/master/" + $dir + "/" + $n),
        name: $n,
        path: ($dir + "/" + $n),
        sha: "0000000000000000000000000000000000000000",
        size: 123,
        type: "file",
        url: ($base + "/contents/" + $dir + "/" + $n + "?ref=master")
      }'
      continue
    fi
    jq -n --arg v "${e}" --arg base "${base}" --arg dir "${dir}" '{
      _links: {
        git: ($base + "/git/trees/0000000000000000000000000000000000000000"),
        html: ("https://github.com/microsoft/winget-pkgs/tree/master/" + $dir + "/" + $v),
        self: ($base + "/contents/" + $dir + "/" + $v + "?ref=master")
      },
      download_url: null,
      git_url: ($base + "/git/trees/0000000000000000000000000000000000000000"),
      html_url: ("https://github.com/microsoft/winget-pkgs/tree/master/" + $dir + "/" + $v),
      name: $v,
      path: ($dir + "/" + $v),
      sha: "0000000000000000000000000000000000000000",
      size: 0,
      type: "dir",
      url: ($base + "/contents/" + $dir + "/" + $v + "?ref=master")
    }'
  done | jq -s '.'
}

# Win32-OpenSSH の releases (新しい順)。引数は「tag|winget の版|公開日時」で、4 つめに |pre を足すと
# prerelease にする。MSI の名前に winget の版が入る。版が空なら Win64 の MSI を持たない release にする
releases_json() {
  local e tag v at pre
  for e in "$@"; do
    IFS='|' read -r tag v at pre <<<"${e}"
    jq -n --arg tag "${tag}" --arg v "${v}" --arg at "${at}" --arg pre "${pre}" '{
      url: "https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/1",
      html_url: ("https://github.com/PowerShell/Win32-OpenSSH/releases/tag/" + $tag),
      id: 1,
      tag_name: $tag,
      name: $tag,
      draft: false,
      prerelease: ($pre == "pre"),
      created_at: $at,
      published_at: $at,
      assets: ([
        { name: "OpenSSH-ARM64-v\($v).msi", size: 6295552,
          browser_download_url: "https://github.com/PowerShell/Win32-OpenSSH/releases/download/\($tag)/OpenSSH-ARM64-v\($v).msi",
          digest: "sha256:7a17d0e22d004fb47ca4bfd8fef926fa305de4ebf70a6f3c7a29c39aabef0023" },
        { name: "OpenSSH-Win64-v\($v).msi", size: 6586368,
          browser_download_url: "https://github.com/PowerShell/Win32-OpenSSH/releases/download/\($tag)/OpenSSH-Win64-v\($v).msi",
          digest: "sha256:ddec9c53864280759cf9f74791cefd387100e3946aa849a1c138a4ed1b96b7d9" }
      ] | if $v == "" then [] else . end) + [
        { name: "OpenSSH-Win64.zip", size: 5704583,
          browser_download_url: "https://github.com/PowerShell/Win32-OpenSSH/releases/download/\($tag)/OpenSSH-Win64.zip",
          digest: "sha256:23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5" }
      ]
    }'
  done | jq -s '.'
}

# herdrdev/herdr の releases (新しい順)。引数は「tag|公開日時」。tag が preview- で始まるものは preview の
# build で、GitHub では prerelease (3 つめに |pre を足すと、ほかの tag でも prerelease にする)。安定版 (v0.9.5
# など) は prerelease ではない。どちらにも Windows の zip が付く (本物は v0.8.2 から)
herdr_releases_json() {
  local e tag at pre
  for e in "$@"; do
    IFS='|' read -r tag at pre <<<"${e}"
    jq -n --arg tag "${tag}" --arg at "${at}" --arg pre "${pre}" '
      (($tag | startswith("preview-")) or $pre == "pre") as $prerelease
      | {
        url: "https://api.github.com/repos/herdrdev/herdr/releases/412893479",
        assets_url: "https://api.github.com/repos/herdrdev/herdr/releases/412893479/assets",
        html_url: ("https://github.com/herdrdev/herdr/releases/tag/" + $tag),
        id: 412893479,
        tag_name: $tag,
        target_commitish: "fbd2ae23927fe4923752bdb2db29661917fb05d7",
        name: (if $prerelease then "Preview build " + ($tag | ltrimstr("preview-")) else $tag end),
        draft: false,
        immutable: true,
        prerelease: $prerelease,
        created_at: $at,
        updated_at: $at,
        published_at: $at,
        assets: [
          "herdr-linux-aarch64", "herdr-linux-x86_64", "herdr-macos-aarch64", "herdr-macos-x86_64",
          "herdr-windows-x86_64.zip"
          | { name: ., label: "", content_type: "application/octet-stream", state: "uploaded", size: 30303280,
              digest: "sha256:0001fb5f0411124cf3ec42a940f4f74ff4004552f45e8d6ca3c5d050c58b631f",
              browser_download_url: ("https://github.com/herdrdev/herdr/releases/download/" + $tag + "/" + .) }
        ],
        body: (if $prerelease
          then "Preview build " + ($tag | ltrimstr("preview-")) + "\n\n[View changes](https://github.com/herdrdev/herdr/compare/v0.9.4...fbd2ae23927fe4923752bdb2db29661917fb05d7)"
          else "Release " + $tag end)
      }'
  done | jq -s '.'
}

# winget-pkgs の commits?path=… の応答 (新しい順)。$1: 版 (commit の文面に入る)、残り: commit の日時
commits_json() {
  local v=$1 at
  shift
  for at in "$@"; do
    jq -n --arg v "${v}" --arg at "${at}" '{
      sha: "db251aa80450d385a0abeb14309da3363c220126",
      node_id: "C_kwDOC8Ivn9oAKGRiMjUxYWE4MDQ1MGQzODVhMGFiZWIxNDMwOWRhMzM2M2MyMjAxMjY",
      commit: {
        author: { name: "spectopo", email: "175387142+spectopo@users.noreply.github.com", date: $at },
        committer: { name: "GitHub", email: "noreply@github.com", date: $at },
        message: ("New version: Google.JapaneseIME version " + $v + " (#409753)"),
        tree: {
          sha: "bab6f9cf627169696570c7036fe6e22f3f2e0ff7",
          url: "https://api.github.com/repos/microsoft/winget-pkgs/git/trees/bab6f9cf627169696570c7036fe6e22f3f2e0ff7"
        },
        url: "https://api.github.com/repos/microsoft/winget-pkgs/git/commits/db251aa80450d385a0abeb14309da3363c220126",
        comment_count: 0,
        verification: { verified: true, reason: "valid", signature: null, payload: null, verified_at: $at }
      },
      url: "https://api.github.com/repos/microsoft/winget-pkgs/commits/db251aa80450d385a0abeb14309da3363c220126",
      html_url: "https://github.com/microsoft/winget-pkgs/commit/db251aa80450d385a0abeb14309da3363c220126",
      comments_url: "https://api.github.com/repos/microsoft/winget-pkgs/commits/db251aa80450d385a0abeb14309da3363c220126/comments",
      author: { login: "spectopo", id: 175387142, node_id: "U_kgDOCnQyBg", type: "User", user_view_type: "public", site_admin: false },
      committer: { login: "web-flow", id: 19864447, node_id: "MDQ6VXNlcjE5ODY0NDQ3", type: "User", user_view_type: "public", site_admin: false },
      parents: [ {
        sha: "bcae2a61a18c3ac5cebc05e518db2908c9723a5d",
        url: "https://api.github.com/repos/microsoft/winget-pkgs/commits/bcae2a61a18c3ac5cebc05e518db2908c9723a5d",
        html_url: "https://github.com/microsoft/winget-pkgs/commit/bcae2a61a18c3ac5cebc05e518db2908c9723a5d"
      } ]
    }'
  done | jq -s '.'
}

# 猶予 (30 日) の境目を確かめる日時。ago N は、出てからの日数が N になる日時。ちょうど N 日前にすると、
# script が日数を数えるまでの間に時計が 1 秒戻るだけで N - 1 日になる (手元で 8 本並べて流したとき、
# 40 日が 39 日になって落ちた)。半日ずらし、どちらへ時計がずれても日数が変わらないようにする
ago() { date -u -d "-$1 day -12 hour" +%Y-%m-%dT%H:%M:%SZ; }
at29=$(ago 29)

# 今の winget-pkgs と GitHub の releases (2026-10-15) と、その上に 10.1.0.0 / 10.2.0.0 が出た後。
# 本物の contents API は名前の文字列順に並べて返す
winget_now=$(contents_json 10.0.0.0 9.5.0.0 9.8.0.0 9.8.1.0 9.8.2.0 9.8.3.0)
winget_101=$(contents_json 10.0.0.0 10.1.0.0 9.5.0.0 9.8.0.0 9.8.1.0 9.8.2.0 9.8.3.0)
winget_102=$(contents_json 10.0.0.0 10.1.0.0 10.2.0.0 9.5.0.0 9.8.0.0 9.8.1.0 9.8.2.0 9.8.3.0)
rel_100='10.0.0.0p2-Preview|10.0.0.0|2025-10-27T18:58:57Z'
rel_983='v9.8.3.0p2-Preview|9.8.3.0|2025-04-18T17:51:11Z'
rel_101='v10.1.0.0p1-Preview|10.1.0.0|2026-03-02T18:00:00Z'
rel_102='v10.2.0.0p1-Preview|10.2.0.0|2026-06-01T18:00:00Z'
releases_now=$(releases_json "${rel_100}" "${rel_983}")
releases_101=$(releases_json "${rel_101}" "${rel_100}" "${rel_983}")
releases_102=$(releases_json "${rel_102}" "${rel_101}" "${rel_100}")
# rel <版> <公開日時> は releases_json の 1 件
rel() { printf 'v%sp1-Preview|%s|%s' "$1" "$1" "$2"; }
# 昨日出た 10.1.0.0 (まだ winget に載っていなくてよい)・Win64 の MSI を持たない 10.1.0.0
releases_101_recent=$(releases_json "$(rel 10.1.0.0 "$(ago 1)")" "${rel_100}" "${rel_983}")
releases_101_nomsi=$(releases_json 'v10.1.0.0p1-Preview||2026-03-02T18:00:00Z' "${rel_100}" "${rel_983}")
not_found='{"message":"Not Found","documentation_url":"https://docs.github.com/rest/repos/contents#get-repository-content","status":"404"}'

# Install-OpenSSH.ps1 の形。$1: 書き先、$2: 固定した版 (空なら -Version の行を書かない)、
# $3: パッケージ ID (- なら $packageId の行を書かない)
write_openssh_ps1() {
  {
    printf '\xef\xbb\xbf<#\n.SYNOPSIS\nWin32-OpenSSH を、決めた版に揃える。\n#>\n'
    printf '[CmdletBinding()]\nparam(\n'
    if [[ -n $2 ]]; then
      printf "    [string]\$Version = '%s',\n" "$2"
    fi
    # shellcheck disable=SC2016 # PowerShell の $Check などを文字のまま書く
    printf '    [switch]$Check,\n    [switch]$Force,\n    [string]$LogPath\n)\n\n'
    # shellcheck disable=SC2016
    printf 'function Invoke-InstallOpenSsh {\n    param([string]$Version, [switch]$Check, [switch]$Force, [string]$LogPath)\n'
    if [[ $3 != - ]]; then
      printf "    \$packageId = '%s'\n" "$3"
    fi
    # shellcheck disable=SC2016
    printf '    $installDir = Join-Path $env:ProgramFiles '"'"'OpenSSH'"'"'\n}\n'
  } >"$1"
}

# Install-Herdr.ps1 の形 ($packageId より前に、引数に $PackageId を取る関数がある)。引数は write_openssh_ps1 と同じ
write_herdr_ps1() {
  {
    printf '\xef\xbb\xbf<#\n.SYNOPSIS\nWindows の herdr (winget の Herdr.Herdr.Preview) を、決めた版に揃える。\n#>\n'
    printf '[CmdletBinding()]\nparam(\n'
    if [[ -n $2 ]]; then
      printf "    [string]\$Version = '%s',\n" "$2"
    fi
    # shellcheck disable=SC2016
    printf '    [switch]$Check,\n    [switch]$IfMissing\n)\n\n'
    # shellcheck disable=SC2016
    printf 'function Get-WingetCommands {\n    param([string]$Plan, [string]$PackageId, [string]$Version)\n}\n\n'
    # shellcheck disable=SC2016
    printf 'function Invoke-InstallHerdr {\n    param([string]$Version, [switch]$Check, [switch]$IfMissing)\n'
    if [[ $3 != - ]]; then
      printf "    \$packageId = '%s'\n" "$3"
    fi
    # shellcheck disable=SC2016
    printf '    $packageDir = Join-Path $env:LOCALAPPDATA '"'"'Microsoft\\WinGet\\Packages\\Herdr.Herdr.Preview_Microsoft.Winget.Source_8wekyb3d8bbwe'"'"'\n}\n'
  } >"$1"
}

# Install-GoogleJapaneseInput.ps1 の形。引数は write_openssh_ps1 と同じ
write_gime_ps1() {
  {
    printf '\xef\xbb\xbf<#\n.SYNOPSIS\nWindows の Google 日本語入力 (winget の Google.JapaneseIME) を、決めた版に揃える。\n#>\n'
    printf '[CmdletBinding()]\nparam(\n'
    if [[ -n $2 ]]; then
      printf "    [string]\$Version = '%s',\n" "$2"
    fi
    # shellcheck disable=SC2016
    printf '    [switch]$Check,\n    [switch]$IfMissing\n)\n\n'
    # shellcheck disable=SC2016
    printf 'function Invoke-InstallGoogleJapaneseInput {\n    param([string]$Version, [switch]$Check, [switch]$IfMissing)\n'
    if [[ $3 != - ]]; then
      printf "    \$packageId = '%s'\n" "$3"
    fi
    # shellcheck disable=SC2016
    printf '    $target = ConvertTo-GoogleImeVersion -Text $Version\n}\n'
  } >"$1"
}

# 1 ケースぶんのディレクトリを作る。パッケージは今の pkg で、ps1 は本物と同じく BOM 付き。
#   $1: 名前、$2: 固定した版 (空なら -Version の行を書かない)、$3: 見送りの一覧の中身 (- なら作らない)、
#   $4: パッケージ ID (省くと pkg の本物の ID、- なら $packageId の行を書かない)
new_case() {
  local d="${work}/$1" id=${4:-}
  mkdir -p "${d}"
  printf '%s\n' "${pkg}" >"${d}/pkg"
  case ${pkg} in
    openssh) write_openssh_ps1 "${d}/Install-OpenSSH.ps1" "$2" "${id:-Microsoft.OpenSSH.Preview}" ;;
    herdr) write_herdr_ps1 "${d}/Install-Herdr.ps1" "$2" "${id:-Herdr.Herdr.Preview}" ;;
    google-japanese-input) write_gime_ps1 "${d}/Install-GoogleJapaneseInput.ps1" "$2" "${id:-Google.JapaneseIME}" ;;
  esac
  if [[ $3 != - ]]; then
    printf '%s\n' "$3" >"${d}/skipped-versions.txt"
  fi
  : >"${d}/gh-calls"
  echo "${d}"
}

# Google 日本語入力の版 $2 のディレクトリの commit の一覧を、ケース $1 の偽の gh に持たせる。
# 残り: commit の日時 (新しい順。最後がその版を足した commit)
put_commits() {
  local d=$1 v=$2
  shift 2
  mkdir -p "${d}/commits"
  commits_json "${v}" "$@" >"${d}/commits/${v}"
}

# $1: ケースのディレクトリ、$2: 1 なら偽の gh を PATH に置かない、残り: script の引数 (そのまま渡す)。
# 環境変数 (FAKE_GH_*・GITHUB_ACTIONS_FOR_TEST・GRACE_DAYS_FOR_TEST・SCRIPT_FOR_TEST) は呼び出し側で付ける。
run_args() {
  local d=$1 nogh=$2
  shift 2
  local path="${fake_bin}:${sys_bin}"
  if [[ ${nogh} == 1 ]]; then
    path="${sys_bin}"
  fi
  env PATH="${path}" FAKE_GH_LOG="${d}/gh-calls" FAKE_GH_COMMITS_DIR="${d}/commits" \
    GITHUB_ACTIONS="${GITHUB_ACTIONS_FOR_TEST-}" CHECK_WINGET_VERSION_GRACE_DAYS="${GRACE_DAYS_FOR_TEST-}" \
    "${BASH}" "${SCRIPT_FOR_TEST:-${script}}" "$@" >"${d}/out" 2>"${d}/err"
  echo $? >"${d}/rc"
}

# run_args と同じだが、script の引数を渡さなければ、ケースのパッケージの名前・ps1・skipped-versions.txt を渡す
run() {
  local d=$1 nogh=$2 p
  shift 2
  if (($# == 0)); then
    p=$(<"${d}/pkg")
    set -- "${p}" "${d}/$(ps1_of "${p}")" "${d}/skipped-versions.txt"
  fi
  run_args "${d}" "${nogh}" "$@"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }
calls() { cat "$1/gh-calls"; }
gh_called() { [[ -s $1/gh-calls ]]; }

# 判定の grep -q はパイプで受けず、ファイルを直に読む。outerr を grep -q へパイプでつなぐと、grep が
# out で合って先に抜けたあと cat が err を書こうとして SIGPIPE (141) で終わり、pipefail で「合わない」
# に見える (CI の混んだランナーで実際に落ちた)。$1: ケースのディレクトリ、残り: grep の引数
seen() {
  local d=$1
  shift
  grep -q "$@" "${d}/out" "${d}/err"
}
seen_out() {
  local d=$1
  shift
  grep -q "$@" "${d}/out"
}
called() {
  local d=$1
  shift
  grep -q "$@" "${d}/gh-calls"
}

echo "== check-winget-version.sh: ${script}"

echo "-- openssh"
pkg=openssh

# 1. 固定した版が winget-pkgs の最新: exit 0、⚠ は出さない。9.8.3.0 を 10.0.0.0 より新しいと読まない
d=$(new_case t1 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_now}" FAKE_GH_RELEASES="${releases_now}" run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && ! seen "${d}" '⚠' && seen "${d}" -F '10.0.0.0'; then
  ok "固定した版が最新なら exit 0 で ⚠ を出さない (9.8.3.0 は 10.0.0.0 より古いと読む)"
else
  ng "最新" "rc=$(rc "${d}") $(outerr "${d}")"
fi
if called "${d}" -xF 'api repos/microsoft/winget-pkgs/contents/manifests/m/Microsoft/OpenSSH/Preview'; then
  ok "Microsoft.OpenSSH.Preview なら winget-pkgs の manifests/m/Microsoft/OpenSSH/Preview を読む"
else
  ng "読む場所が違う" "calls=$(calls "${d}")"
fi

# 2. winget-pkgs の場所は Install-OpenSSH.ps1 のパッケージ ID から組む (ID を移したら、見る場所も移る)
d=$(new_case t2 10.0.0.0 - Microsoft.OpenSSH.Beta)
FAKE_GH_CONTENTS="${winget_now}" FAKE_GH_RELEASES="${releases_now}" run "${d}" 0
if called "${d}" -xF 'api repos/microsoft/winget-pkgs/contents/manifests/m/Microsoft/OpenSSH/Beta'; then
  ok "winget-pkgs の場所は Install-OpenSSH.ps1 のパッケージ ID から組む"
else
  ng "パッケージ ID から組んでいない" "calls=$(calls "${d}") $(outerr "${d}")"
fi

# 3. 固定した版より新しい版があり、GitHub に出て 30 日を過ぎた: exit 1。版・release notes の URL・
#    見送りの一覧の場所を出す
d=$(new_case t3 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_101}" FAKE_GH_RELEASES="${releases_101}" run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*10\.1\.0\.0' \
  && seen "${d}" -F 'https://github.com/PowerShell/Win32-OpenSSH/releases/tag/v10.1.0.0p1-Preview' \
  && seen "${d}" -F 'skipped-versions.txt'; then
  ok "新しい版が 30 日を過ぎていれば exit 1 で、版・release notes の URL・見送りの一覧の場所を出す"
else
  ng "新しい版がある" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 3b. 猶予の境目: GitHub に出て 29 日の新しい版は、まだ知らせない (exit 0)。版・出た日・あと何日で
#     知らせるかを 1 行に出す。新しい版が無いとは言わない。GitHub Actions の外では :: の行を出さない
d=$(new_case t3b 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_101}" FAKE_GH_RELEASES=$(releases_json "$(rel 10.1.0.0 "${at29}")" "${rel_100}" "${rel_983}") run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && ! seen "${d}" '⚠' && ! seen "${d}" '^::' \
  && seen "${d}" "10\\.1\\.0\\.0.*${at29:0:10}.*あと 1 日" \
  && ! seen "${d}" '見送っていないものは winget にも GitHub にも無い'; then
  ok "GitHub に出て 29 日の新しい版は exit 0 で待ち、版・出た日・あと 1 日を 1 行に出す"
else
  ng "29 日の新しい版" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 3c. 猶予の境目: GitHub に出て 30 日たった新しい版は知らせる (exit 1)
d=$(new_case t3c 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_101}" FAKE_GH_RELEASES=$(releases_json "$(rel 10.1.0.0 "$(ago 30)")" "${rel_100}" "${rel_983}") run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*10\.1\.0\.0'; then
  ok "GitHub に出て 30 日たった新しい版は exit 1 で知らせる"
else
  ng "30 日の新しい版" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 3d. 新しい版がいくつかあるときは、いちばん早く出た版から数える (25 日前の 10.1.0.0 から数えて、あと 5 日。
#     5 日前の 10.2.0.0 から数えると、あと 25 日になってしまう)
d=$(new_case t3d 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_102}" FAKE_GH_RELEASES=$(releases_json "$(rel 10.2.0.0 "$(ago 5)")" "$(rel 10.1.0.0 "$(ago 25)")" "${rel_100}") run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && ! seen "${d}" '⚠' \
  && seen "${d}" '10\.1\.0\.0.*あと 5 日' && seen "${d}" '10\.2\.0\.0.*あと 5 日'; then
  ok "新しい版がいくつかあるときは、いちばん早く出た版から数える (あと 5 日)"
else
  ng "いくつかの新しい版 (待つ)" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 3e. いちばん早い版が 30 日を過ぎたら、あとから出た版がまだ新しくても知らせる。どちらの版も出す
d=$(new_case t3e 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_102}" FAKE_GH_RELEASES=$(releases_json "$(rel 10.2.0.0 "$(ago 5)")" "$(rel 10.1.0.0 "$(ago 31)")" "${rel_100}") run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*10\.1\.0\.0' && seen "${d}" '⚠.*10\.2\.0\.0'; then
  ok "いちばん早い版が 30 日を過ぎたら、あとから出た版が新しくても exit 1 で両方を知らせる"
else
  ng "いくつかの新しい版 (知らせる)" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 3f. 見送った版は数えない: 40 日前の 10.1.0.0 を見送ったら、5 日前の 10.2.0.0 から数えて、あと 25 日
d=$(new_case t3f 10.0.0.0 '10.1.0.0 1Password の agent に繋がらない')
FAKE_GH_CONTENTS="${winget_102}" FAKE_GH_RELEASES=$(releases_json "$(rel 10.2.0.0 "$(ago 5)")" "$(rel 10.1.0.0 "$(ago 40)")" "${rel_100}") run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && ! seen "${d}" '⚠' && seen "${d}" '10\.2\.0\.0.*あと 25 日'; then
  ok "見送った版は数えず、見送っていない版のうちいちばん早く出たものから数える (あと 25 日)"
else
  ng "見送った版を数えた" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 4. 新しい版を見送った: exit 0 で、見送った理由を出す。ps1 が CRLF でも読める
d=$(new_case t4 10.0.0.0 $'# 見送った版\n\n10.1.0.0  1Password の agent に繋がらない (TKT-999)')
sed -i 's/$/\r/' "${d}/Install-OpenSSH.ps1"
FAKE_GH_CONTENTS="${winget_101}" FAKE_GH_RELEASES="${releases_101}" run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && ! seen "${d}" '⚠' \
  && seen "${d}" -F '1Password の agent に繋がらない (TKT-999)'; then
  ok "新しい版が見送りの一覧にあれば exit 0 で、見送った理由を出す (ps1 が CRLF でも読む)"
else
  ng "見送った" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 5. 見送りの一覧が BOM 付き・CRLF でも読める (win/ の ps1 は BOM 付きで保存する決まりなので取り違えやすい)
d=$(new_case t5 10.0.0.0 -)
printf '\xef\xbb\xbf# 見送った版\r\n10.1.0.0 MSI が ssh-agent を自動に戻す\r\n' >"${d}/skipped-versions.txt"
FAKE_GH_CONTENTS="${winget_101}" FAKE_GH_RELEASES="${releases_101}" run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && seen "${d}" 'MSI が ssh-agent を自動に戻す)$'; then
  ok "見送りの一覧が BOM 付き・CRLF でも読み、理由に CR を残さない"
else
  ng "BOM 付き・CRLF の見送りの一覧" "rc=$(rc "${d}") $(outerr "${d}" | od -c | head -20)"
fi

# 6. 見送りは版ごと: 10.2.0.0 だけ見送っても、10.1.0.0 は知らせる
d=$(new_case t6 10.0.0.0 '10.2.0.0 MSI が ssh-agent を消す')
FAKE_GH_CONTENTS="${winget_102}" FAKE_GH_RELEASES="${releases_102}" run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*10\.1\.0\.0' && ! seen "${d}" '⚠.*10\.2\.0\.0'; then
  ok "見送りは版ごと (10.2.0.0 を見送っても、見送っていない 10.1.0.0 は知らせる)"
else
  ng "見送りは版ごと" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 7. 新しい版の release が GitHub に見つからない: 出た日が分からないので待たずに知らせ (exit 1)、
#    releases の一覧の URL を代わりに出す
d=$(new_case t7 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_101}" FAKE_GH_RELEASES="${releases_now}" run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*出た日が分からない' \
  && seen "${d}" '10\.1\.0\.0.*https://github\.com/PowerShell/Win32-OpenSSH/releases$'; then
  ok "新しい版の release が見つからなければ、出た日が分からないので待たずに exit 1 で、releases の一覧の URL を出す"
else
  ng "release が見つからない" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 8. release の一覧が取れず、新しい版が GitHub に出た日が分からない: 猶予の中かを決められないので exit 2
#    (API の失敗は新しい版の知らせではないので、⚠ で「上げるか見送るか」を迫らない)
d=$(new_case t8 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_101}" FAKE_GH_RELEASES_ERR='gh: HTTP 502' FAKE_GH_RELEASES_RC=1 run "${d}" 0
if [[ $(rc "${d}") == 2 ]] && ! seen "${d}" '⚠' \
  && seen "${d}" '10\.1\.0\.0' && seen "${d}" -F 'gh: HTTP 502'; then
  ok "release の一覧が取れず、新しい版が出た日が分からなければ、⚠ を出さずに exit 2"
else
  ng "新しい版があって release の一覧が取れない" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 8b. release の一覧が取れず、winget の版では知らせることも無い: GitHub と比べられなかったので exit 2
d=$(new_case t8b 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_now}" FAKE_GH_RELEASES_ERR='gh: HTTP 502' FAKE_GH_RELEASES_RC=1 run "${d}" 0
if [[ $(rc "${d}") == 2 ]] && seen "${d}" -F 'gh: HTTP 502'; then
  ok "release の一覧が取れず、ほかに知らせることも無ければ、gh のエラーを見せて exit 2"
else
  ng "release の一覧だけ取れない" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 9. 固定した版が winget-pkgs に無い (新しいマシンで入れられない): exit 1
d=$(new_case t9 10.0.0.0 -)
FAKE_GH_CONTENTS=$(contents_json 9.5.0.0 9.8.3.0) FAKE_GH_RELEASES=$(releases_json "${rel_983}") run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*10\.0\.0\.0'; then
  ok "固定した版が winget-pkgs に無ければ exit 1"
else
  ng "固定した版が無い" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 10. パッケージごと winget-pkgs に無い (404。Microsoft.OpenSSH.Beta は 2025-04 に丸ごと外された): exit 1
d=$(new_case t10 10.0.0.0 -)
FAKE_GH_CONTENTS="${not_found}" FAKE_GH_CONTENTS_ERR='gh: Not Found (HTTP 404)' FAKE_GH_CONTENTS_RC=1 run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*Microsoft\.OpenSSH\.Preview'; then
  ok "パッケージが winget-pkgs に無ければ (404) exit 1"
else
  ng "パッケージが無い" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 11. 版の形でないディレクトリがある (版の付け方が変わったなど): exit 1。ファイルの項目は版として扱わない
d=$(new_case t11 10.0.0.0 -)
FAKE_GH_CONTENTS=$(contents_json 10.0.0.0 10.1.0.0p1 9.8.3.0 file:README.md) FAKE_GH_RELEASES="${releases_now}" run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*10\.1\.0\.0p1' && ! seen "${d}" '⚠.*README'; then
  ok "版の形でないディレクトリがあれば exit 1 (ファイルの項目は数えない)"
else
  ng "版の形でないディレクトリ" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 12. GitHub の最新 release が、出て 30 日を過ぎても winget に載らない (パッケージ ID が移ったなど): exit 1
#     (2024-10 に Microsoft.OpenSSH.Preview ができた後、Beta には新しい版が来なくなった)
d=$(new_case t12 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_now}" FAKE_GH_RELEASES="${releases_101}" run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*10\.1\.0\.0'; then
  ok "GitHub の最新 release が 30 日を過ぎても winget に無ければ exit 1"
else
  ng "GitHub の最新が winget に無い" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 13. GitHub に出て 30 日たっていない版は、winget にまだ無くても落とさず、あと何日で知らせるかを出す
#     (これまで載るまで 5 時間〜4 日)
d=$(new_case t13 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_now}" FAKE_GH_RELEASES="${releases_101_recent}" run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && ! seen "${d}" '⚠' && seen "${d}" '10\.1\.0\.0.*あと 29 日' \
  && ! seen "${d}" '見送っていないものは winget にも GitHub にも無い'; then
  ok "GitHub に出て 1 日の版は、winget に無くても落とさず、あと 29 日で知らせると出す"
else
  ng "30 日たっていない" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 13b. 猶予の境目: GitHub に出て 29 日の版は、winget に無くてもまだ落とさない
d=$(new_case t13b 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_now}" FAKE_GH_RELEASES=$(releases_json "$(rel 10.1.0.0 "${at29}")" "${rel_100}" "${rel_983}") run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && ! seen "${d}" '⚠' && seen "${d}" "10\\.1\\.0\\.0.*${at29:0:10}.*あと 1 日"; then
  ok "GitHub に出て 29 日の版は、winget に無くても exit 0 で待ち、出た日とあと 1 日を出す"
else
  ng "GitHub だけにある 29 日の版" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 13c. 猶予の境目: GitHub に出て 30 日たっても winget に無ければ落とす
d=$(new_case t13c 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_now}" FAKE_GH_RELEASES=$(releases_json "$(rel 10.1.0.0 "$(ago 30)")" "${rel_100}" "${rel_983}") run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*10\.1\.0\.0'; then
  ok "GitHub に出て 30 日たっても winget に無ければ exit 1"
else
  ng "GitHub だけにある 30 日の版" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 13d. GitHub にだけある版がいくつかあるときも、いちばん早く出た版から数える (31 日前の 10.1.0.0 で知らせる。
#      いちばん新しい 10.2.0.0 だけを見ると、出て 5 日なので黙ってしまう)
d=$(new_case t13d 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_now}" FAKE_GH_RELEASES=$(releases_json "$(rel 10.2.0.0 "$(ago 5)")" "$(rel 10.1.0.0 "$(ago 31)")" "${rel_100}") run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*10\.1\.0\.0'; then
  ok "GitHub にだけある版がいくつかあるときも、いちばん早く出た版から数える"
else
  ng "GitHub だけにある版がいくつか" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 13e. GitHub の prerelease は、winget に載らなくても数えない (40 日前の prerelease だけなら落とさない)
d=$(new_case t13e 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_now}" FAKE_GH_RELEASES=$(releases_json "$(rel 10.1.0.0 "$(ago 40)")|pre" "${rel_100}" "${rel_983}") run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && ! seen "${d}" '⚠' && ! seen "${d}" '10\.1\.0\.0'; then
  ok "GitHub の prerelease は、winget に無くても数えない"
else
  ng "prerelease を数えた" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 14. GitHub の最新 release を見送ってあれば、winget に無くても落とさない
d=$(new_case t14 10.0.0.0 '10.1.0.0 1Password の agent に繋がらない')
FAKE_GH_CONTENTS="${winget_now}" FAKE_GH_RELEASES="${releases_101}" run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && ! seen "${d}" '⚠'; then
  ok "見送った版は、GitHub にあって winget に無くても落とさない"
else
  ng "見送った版が GitHub だけにある" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 15. GitHub の最新 release に Win64 の MSI (OpenSSH-Win64-v<版>.msi) が無い (名前が変わった): exit 1
d=$(new_case t15 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_now}" FAKE_GH_RELEASES="${releases_101_nomsi}" run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*v10\.1\.0\.0p1-Preview'; then
  ok "GitHub の最新 release に Win64 の MSI が無ければ exit 1"
else
  ng "MSI が無い" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 16. API が失敗した (404 以外): 確かめられなかったので exit 2 (揃っている扱いにしない)
d=$(new_case t16 10.0.0.0 -)
FAKE_GH_CONTENTS_ERR='error connecting to api.github.com' FAKE_GH_CONTENTS_RC=1 run "${d}" 0
if [[ $(rc "${d}") == 2 ]] && seen "${d}" -F 'error connecting to api.github.com'; then
  ok "API が 404 以外で失敗したら、gh のエラーを見せて exit 2"
else
  ng "API の失敗" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 17. 応答が JSON の一覧でない: exit 2
d=$(new_case t17 10.0.0.0 -)
FAKE_GH_CONTENTS='<html>rate limited</html>' run "${d}" 0
if [[ $(rc "${d}") == 2 ]]; then
  ok "応答が JSON の一覧でなければ exit 2"
else
  ng "JSON でない" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 18. 固定した版が読めない: gh を呼ばずに exit 2
d=$(new_case t18 '' -)
FAKE_GH_CONTENTS="${winget_now}" run "${d}" 0
if [[ $(rc "${d}") == 2 ]] && ! gh_called "${d}"; then
  ok "Install-OpenSSH.ps1 から固定した版が読めなければ、gh を呼ばずに exit 2"
else
  ng "固定した版が読めない" "rc=$(rc "${d}") calls=$(calls "${d}") $(outerr "${d}")"
fi

# 19. パッケージ ID が読めない: gh を呼ばずに exit 2
d=$(new_case t19 10.0.0.0 - -)
FAKE_GH_CONTENTS="${winget_now}" run "${d}" 0
if [[ $(rc "${d}") == 2 ]] && ! gh_called "${d}"; then
  ok "Install-OpenSSH.ps1 からパッケージ ID が読めなければ、gh を呼ばずに exit 2"
else
  ng "パッケージ ID が読めない" "rc=$(rc "${d}") calls=$(calls "${d}") $(outerr "${d}")"
fi

# 20. Install-OpenSSH.ps1 が無い: 行が無いとは言わず、ファイルが読めないと言って exit 2
d=$(new_case t20 10.0.0.0 -)
run "${d}" 0 openssh "${d}/no-such.ps1" "${d}/skipped-versions.txt"
if [[ $(rc "${d}") == 2 ]] && seen "${d}" -F "${d}/no-such.ps1" && ! seen "${d}" '行がありません'; then
  ok "Install-OpenSSH.ps1 が無ければ、行が無いとは言わずに exit 2"
else
  ng "Install-OpenSSH.ps1 が無い" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 21. 見送りの一覧に理由の無い行がある: exit 2 (版と理由を 1 行に書く決まり)
d=$(new_case t21 10.0.0.0 '10.1.0.0')
FAKE_GH_CONTENTS="${winget_101}" FAKE_GH_RELEASES="${releases_101}" run "${d}" 0
if [[ $(rc "${d}") == 2 ]] && seen "${d}" -F 'skipped-versions.txt'; then
  ok "見送りの一覧に理由の無い行があれば、ファイルの場所を出して exit 2"
else
  ng "見送りの一覧が壊れている" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 22. 固定した版以下の見送りが残っている: 落とさず、消してよいと出す
d=$(new_case t22 10.0.0.0 '9.8.3.0 試した時期の 1Password と合わない')
FAKE_GH_CONTENTS="${winget_now}" FAKE_GH_RELEASES="${releases_now}" run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && seen "${d}" '9\.8\.3\.0.*消して'; then
  ok "固定した版以下の見送りは落とさず、消してよいと出す"
else
  ng "古い見送り" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 23. GitHub Actions の中では、落ちるとき (exit 1 も 2 も) だけ ::error の行を出す (stdout)
d=$(new_case t23 10.0.0.0 -)
GITHUB_ACTIONS_FOR_TEST=true FAKE_GH_CONTENTS="${winget_101}" FAKE_GH_RELEASES="${releases_101}" run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen_out "${d}" '^::error.*10\.1\.0\.0'; then
  ok "GitHub Actions の中で新しい版があれば、::error の行を出す"
else
  ng "::error が出ない" "rc=$(rc "${d}") $(outerr "${d}")"
fi
d=$(new_case t23b 10.0.0.0 -)
GITHUB_ACTIONS_FOR_TEST=true FAKE_GH_CONTENTS_ERR='error connecting to api.github.com' FAKE_GH_CONTENTS_RC=1 run "${d}" 0
if [[ $(rc "${d}") == 2 ]] && seen_out "${d}" '^::error'; then
  ok "GitHub Actions の中では、確かめられなかったとき (exit 2) も ::error の行を出す"
else
  ng "exit 2 で ::error が出ない" "rc=$(rc "${d}") $(outerr "${d}")"
fi
d=$(new_case t23c 10.0.0.0 -)
GITHUB_ACTIONS_FOR_TEST=true FAKE_GH_CONTENTS="${winget_now}" FAKE_GH_RELEASES="${releases_now}" run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && ! seen "${d}" '^::error'; then
  ok "GitHub Actions の中でも、知らせることが無ければ ::error を出さない"
else
  ng "揃っているのに ::error" "rc=$(rc "${d}") $(outerr "${d}")"
fi
d=$(new_case t23d 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_101}" FAKE_GH_RELEASES="${releases_101}" run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && ! seen "${d}" '^::error'; then
  ok "GitHub Actions の外では、新しい版があっても ::error を出さない"
else
  ng "外で ::error" "rc=$(rc "${d}") $(outerr "${d}")"
fi
# 23e. 猶予の中の版は ::notice の行で出す (落とさないので ::error は出さない)。summary は :: の行を除いて
#      写すので、※ の行も残す
d=$(new_case t23e 10.0.0.0 -)
GITHUB_ACTIONS_FOR_TEST=true FAKE_GH_CONTENTS="${winget_101}" FAKE_GH_RELEASES=$(releases_json "$(rel 10.1.0.0 "$(ago 10)")" "${rel_100}") run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && seen_out "${d}" '^::notice.*10\.1\.0\.0.*あと 20 日' \
  && seen_out "${d}" '^  ※.*10\.1\.0\.0.*あと 20 日' && ! seen "${d}" '^::error'; then
  ok "GitHub Actions の中では、猶予の中の版を ::notice の行と ※ の行で出し、::error は出さない"
else
  ng "猶予の中の ::notice" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 24. gh が無い: exit 2
d=$(new_case t24 10.0.0.0 -)
run "${d}" 1
if [[ $(rc "${d}") == 2 ]] && seen "${d}" 'gh'; then
  ok "gh が無ければ exit 2"
else
  ng "gh が無い" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 25. 知らない引数: gh を呼ばずに exit 2
d=$(new_case t25 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_now}" run "${d}" 0 openssh --bogus
if [[ $(rc "${d}") == 2 ]] && ! gh_called "${d}"; then
  ok "知らない引数は、gh を呼ばずに exit 2"
else
  ng "知らない引数" "rc=$(rc "${d}") calls=$(calls "${d}") $(outerr "${d}")"
fi

# 26. 猶予の日数は CHECK_WINGET_VERSION_GRACE_DAYS で変えられる (60 日なら、出て 40 日の版はまだ待つ)
d=$(new_case t26 10.0.0.0 -)
GRACE_DAYS_FOR_TEST=60 FAKE_GH_CONTENTS="${winget_101}" FAKE_GH_RELEASES=$(releases_json "$(rel 10.1.0.0 "$(ago 40)")" "${rel_100}") run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && seen "${d}" '10\.1\.0\.0.*あと 20 日'; then
  ok "猶予の日数は CHECK_WINGET_VERSION_GRACE_DAYS で変えられる (60 日なら、出て 40 日の版はあと 20 日)"
else
  ng "猶予の日数を変える" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 27. 猶予の日数が読めない: gh を呼ばずに exit 2 (030 は bash の算術で 8 進数になるので受けない)
i=0
for g in '1か月' '-1' '030'; do
  i=$((i + 1))
  d=$(new_case "t27-${i}" 10.0.0.0 -)
  GRACE_DAYS_FOR_TEST=${g} FAKE_GH_CONTENTS="${winget_now}" FAKE_GH_RELEASES="${releases_now}" run "${d}" 0
  if [[ $(rc "${d}") == 2 ]] && ! gh_called "${d}" && seen "${d}" -F 'CHECK_WINGET_VERSION_GRACE_DAYS'; then
    ok "猶予の日数が ${g} なら、gh を呼ばずに exit 2"
  else
    ng "猶予の日数 ${g}" "rc=$(rc "${d}") calls=$(calls "${d}") $(outerr "${d}")"
  fi
done

echo "-- herdr"
pkg=herdr

# 今の winget-pkgs と GitHub (2026-10-16)。winget の版は文字列の順で返る。GitHub には winget に無い安定版
# (v0.9.x) と、winget に載らなかった preview (2026-09-21-0ff0f27e2226) もあり、並びは出た順とは限らない
h_pin=0.9.2-preview.2026-09-29-8e78f929d8f0
h_latest=0.9.4-preview.2026-10-14-fbd2ae23927f
herdr_winget_now=$(contents_json 0.9.1-preview.2026-09-28-80c0c07250d2 0.9.1-preview.2026-09-29-9dc3a1df2b56 \
  "${h_pin}" 0.9.3-preview.2026-10-12-6d697e1e75ff "${h_latest}")
h_rel_now=(
  'v0.9.5|2026-10-14T16:07:28Z'
  'preview-2026-10-14-fbd2ae23927f|2026-10-14T15:43:51Z'
  'v0.9.4|2026-10-13T15:41:22Z'
  'preview-2026-10-12-6d697e1e75ff|2026-10-12T13:48:36Z'
  'v0.9.3|2026-09-29T19:29:23Z'
  'v0.9.2|2026-09-29T13:19:42Z'
  'preview-2026-09-29-9dc3a1df2b56|2026-09-29T12:12:58Z'
  'preview-2026-09-29-8e78f929d8f0|2026-09-29T18:54:39Z'
  'preview-2026-09-28-80c0c07250d2|2026-09-28T13:48:10Z'
  'preview-2026-09-21-0ff0f27e2226|2026-09-20T21:50:59Z'
)
herdr_releases_now=$(herdr_releases_json "${h_rel_now[@]}")
# 版の中の日付 (2020-01-01) と GitHub に出た日をわざと離した、固定した版より新しい preview。出た日を
# 版の中の日付から取ると、何年も前に出たことになってすぐ落ちる
h_next=0.9.3-preview.2020-01-01-6d697e1e75ff
h_next_tag=preview-2020-01-01-6d697e1e75ff
herdr_winget_next=$(contents_json "${h_pin}" "${h_next}")
# 固定した版の preview。鍵 (2026-09-29-…) は h_next の鍵 (2020-01-01-…) より新しく並ぶが、winget に
# あるので、GitHub と比べるときに winget に無い版として数えてはいけない。数えてしまうと猶予を過ぎて
# 落ちるよう、40 日前に出たことにする
h_pin_rel="preview-2026-09-29-8e78f929d8f0|$(ago 40)"

# h1. 固定した版が winget の最新: exit 0。Install-Herdr.ps1 の形 ($packageId は関数の中) から読み、
#     manifests/h/Herdr/Herdr/Preview と herdrdev/herdr の release を見る。winget に無い安定版 (v0.9.5 は
#     いちばん新しい preview より後に出た) と、winget に載らなかった古い preview は数えない
d=$(new_case h1 "${h_latest}" -)
FAKE_GH_CONTENTS="${herdr_winget_now}" FAKE_GH_RELEASES="${herdr_releases_now}" run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && ! seen "${d}" '⚠' && ! seen "${d}" -F '0ff0f27e2226' \
  && called "${d}" -xF 'api repos/microsoft/winget-pkgs/contents/manifests/h/Herdr/Herdr/Preview' \
  && called "${d}" -F 'api repos/herdrdev/herdr/releases'; then
  ok "herdr: 固定した版が最新なら exit 0 (安定版と、winget の最新より古い preview は数えない)"
else
  ng "herdr: 最新" "rc=$(rc "${d}") calls=$(calls "${d}") $(outerr "${d}")"
fi
# 固定した版より古い winget の版は並べず、数だけを出す (preview は週に何度も増える)
if seen_out "${d}" -F 'ほかに古い版が 4 個' && ! seen_out "${d}" -F '0.9.1-preview'; then
  ok "herdr: 固定した版より古い winget の版は並べず、数だけを出す"
else
  ng "herdr: 古い版の出し方" "$(outerr "${d}")"
fi

# h2. 固定した版より新しい版が winget にあり、その preview が GitHub に出て 10 日: exit 0 で待つ。
#     出た日は、版の -preview. の後ろと tag の preview- の後ろが同じ release から取る
at10=$(ago 10)
d=$(new_case h2 "${h_pin}" -)
FAKE_GH_CONTENTS="${herdr_winget_next}" \
  FAKE_GH_RELEASES=$(herdr_releases_json "${h_next_tag}|${at10}" "${h_pin_rel}") run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && ! seen "${d}" '⚠' \
  && seen "${d}" "0\\.9\\.3-preview\\.2020-01-01-6d697e1e75ff.*${at10:0:10}.*あと 20 日"; then
  ok "herdr: 新しい版の出た日は tag の合う preview の release から取り、10 日なら exit 0 で待つ"
else
  ng "herdr: 猶予の中" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# h3. 同じ版が GitHub に出て 31 日: exit 1。版・release notes の URL・見送りの一覧の場所を出す
d=$(new_case h3 "${h_pin}" -)
FAKE_GH_CONTENTS="${herdr_winget_next}" \
  FAKE_GH_RELEASES=$(herdr_releases_json "${h_next_tag}|$(ago 31)" "${h_pin_rel}") run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*0\.9\.3-preview\.2020-01-01-6d697e1e75ff' \
  && seen "${d}" -F "https://github.com/herdrdev/herdr/releases/tag/${h_next_tag}" \
  && seen "${d}" -F 'skipped-versions.txt'; then
  ok "herdr: 新しい版が GitHub に出て 31 日なら exit 1 で、release notes の URL と見送りの一覧の場所を出す"
else
  ng "herdr: 猶予を過ぎた" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# h3b. GitHub Actions の中では、::error の行の題を Windows の herdr にする (どのパッケージで落ちたかが分かる)
d=$(new_case h3b "${h_pin}" -)
GITHUB_ACTIONS_FOR_TEST=true FAKE_GH_CONTENTS="${herdr_winget_next}" \
  FAKE_GH_RELEASES=$(herdr_releases_json "${h_next_tag}|$(ago 31)" "${h_pin_rel}") run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen_out "${d}" '^::error title=Windows の herdr::.*0\.9\.3-preview'; then
  ok "herdr: GitHub Actions の中では、::error の行の題を Windows の herdr にする"
else
  ng "herdr: ::error の題" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# h4. 版は数として比べる: 0.10.0-preview… は 0.9.4-preview… より新しい (文字列の順では前に来る)
d=$(new_case h4 "${h_latest}" -)
releases=$(herdr_releases_json "preview-2026-11-02-0123456789ab|$(ago 31)" 'preview-2026-10-14-fbd2ae23927f|2026-10-14T15:43:51Z')
FAKE_GH_CONTENTS=$(contents_json 0.10.0-preview.2026-11-02-0123456789ab "${h_latest}") FAKE_GH_RELEASES="${releases}" run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*0\.10\.0-preview\.2026-11-02-0123456789ab'; then
  ok "herdr: 版は数として比べる (0.10.0-preview… は 0.9.4-preview… より新しい)"
else
  ng "herdr: 版の比べ方" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# h5. winget の最新より新しい preview が GitHub にあって winget に無い: 31 日なら exit 1 (パッケージ ID の
#     移動などを捕まえる)、10 日ならまだ待つ
d=$(new_case h5 "${h_latest}" -)
FAKE_GH_CONTENTS="${herdr_winget_now}" \
  FAKE_GH_RELEASES=$(herdr_releases_json "preview-2026-10-20-0123456789ab|$(ago 31)" "${h_rel_now[@]}") run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*2026-10-20-0123456789ab.*Herdr\.Herdr\.Preview'; then
  ok "herdr: winget の最新より新しい preview が GitHub に出て 31 日たっても winget に無ければ exit 1"
else
  ng "herdr: GitHub にだけある preview (31 日)" "rc=$(rc "${d}") $(outerr "${d}")"
fi
d=$(new_case h5b "${h_latest}" -)
FAKE_GH_CONTENTS="${herdr_winget_now}" \
  FAKE_GH_RELEASES=$(herdr_releases_json "preview-2026-10-20-0123456789ab|${at10}" "${h_rel_now[@]}") run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && ! seen "${d}" '⚠' && seen "${d}" '2026-10-20-0123456789ab.*あと 20 日'; then
  ok "herdr: GitHub にだけある preview も、出て 10 日なら exit 0 で待つ"
else
  ng "herdr: GitHub にだけある preview (10 日)" "rc=$(rc "${d}") $(outerr "${d}")"
fi
# h5c. 見送りの一覧の版は、-preview. の後ろで GitHub の preview と照らす (winget に無い preview も、
#      その後ろが同じ版を書けば落とさない)
d=$(new_case h5c "${h_latest}" '0.9.5-preview.2026-10-20-0123456789ab winget に載らなかった build')
FAKE_GH_CONTENTS="${herdr_winget_now}" \
  FAKE_GH_RELEASES=$(herdr_releases_json "preview-2026-10-20-0123456789ab|$(ago 31)" "${h_rel_now[@]}") run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && ! seen "${d}" '⚠'; then
  ok "herdr: 見送りの一覧の版は -preview. の後ろで GitHub の preview と照らす"
else
  ng "herdr: GitHub にだけある preview を見送った" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# h6. いちばん新しい preview (prerelease) の tag が preview-<日付>-<hash> の形でない: 猶予を置かずに exit 1
d=$(new_case h6 "${h_latest}" -)
FAKE_GH_CONTENTS="${herdr_winget_now}" \
  FAKE_GH_RELEASES=$(herdr_releases_json "nightly-2026-10-15|$(ago 1)|pre" "${h_rel_now[@]}") run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*nightly-2026-10-15'; then
  ok "herdr: いちばん新しい preview の tag が preview-<日付>-<hash> の形でなければ exit 1"
else
  ng "herdr: tag の形" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# h7. herdr の版の形でないディレクトリ (安定版の形の 0.9.5) がある: exit 1
d=$(new_case h7 "${h_latest}" -)
contents=$(contents_json 0.9.1-preview.2026-09-28-80c0c07250d2 0.9.5 "${h_latest}")
FAKE_GH_CONTENTS="${contents}" FAKE_GH_RELEASES="${herdr_releases_now}" run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*版の形でない.*0\.9\.5'; then
  ok "herdr: herdr の版の形でないディレクトリ (0.9.5) があれば exit 1"
else
  ng "herdr: 版の形でないディレクトリ" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# h8. 新しい版を見送った: exit 0 で、見送った理由を出す
d=$(new_case h8 "${h_pin}" "${h_next} Windows で pane が開かない (TKT-999)")
FAKE_GH_CONTENTS="${herdr_winget_next}" \
  FAKE_GH_RELEASES=$(herdr_releases_json "${h_next_tag}|$(ago 40)" "${h_pin_rel}") run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && ! seen "${d}" '⚠' && seen "${d}" -F 'Windows で pane が開かない (TKT-999)'; then
  ok "herdr: 新しい版が見送りの一覧にあれば exit 0 で、見送った理由を出す"
else
  ng "herdr: 見送った" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# h9. 見送りの一覧の版も herdr の版の形で読む (0.9.3 だけでは、どの preview かが決まらない): exit 2
d=$(new_case h9 "${h_pin}" '0.9.3 Windows で pane が開かない')
FAKE_GH_CONTENTS="${herdr_winget_next}" FAKE_GH_RELEASES="${herdr_releases_now}" run "${d}" 0
if [[ $(rc "${d}") == 2 ]] && seen "${d}" -F 'skipped-versions.txt'; then
  ok "herdr: 見送りの一覧の版が herdr の版の形でなければ exit 2"
else
  ng "herdr: 見送りの一覧の版の形" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# h10. 固定した版が herdr の版の形でない (安定版の形の 0.9.5): gh を呼ばずに exit 2
d=$(new_case h10 0.9.5 -)
FAKE_GH_CONTENTS="${herdr_winget_now}" FAKE_GH_RELEASES="${herdr_releases_now}" run "${d}" 0
if [[ $(rc "${d}") == 2 ]] && ! gh_called "${d}" && seen "${d}" -F '0.9.5'; then
  ok "herdr: 固定した版が herdr の版の形でなければ、gh を呼ばずに exit 2"
else
  ng "herdr: 固定した版の形" "rc=$(rc "${d}") calls=$(calls "${d}") $(outerr "${d}")"
fi

echo "-- google-japanese-input"
pkg=google-japanese-input

# 今の winget-pkgs (2026-10-16) と、その上に 3.35.6300.0・3.35.6310.0 が載った後。.validation の
# ファイルがあり、名前の文字列順で返る
gime_winget_now=$(contents_json file:.validation 3.33.6130.0 3.34.6230.0 3.34.6260.0)
gime_winget_next=$(contents_json file:.validation 3.33.6130.0 3.34.6230.0 3.34.6260.0 3.35.6300.0)
gime_winget_next2=$(contents_json file:.validation 3.33.6130.0 3.34.6230.0 3.34.6260.0 3.35.6300.0 3.35.6310.0)
g_tree=https://github.com/microsoft/winget-pkgs/tree/master/manifests/g/Google/JapaneseIME

# g1. 固定した版が winget の最新: exit 0。manifests/g/Google/JapaneseIME を見て、.validation は版として
#     数えない。GitHub の release も、新しい版が無いので commit の一覧も引かない
d=$(new_case g1 3.34.6260.0 -)
FAKE_GH_CONTENTS="${gime_winget_now}" run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && ! seen "${d}" '⚠' \
  && called "${d}" -xF 'api repos/microsoft/winget-pkgs/contents/manifests/g/Google/JapaneseIME' \
  && ! called "${d}" -F 'releases' && ! called "${d}" -F 'commits'; then
  ok "Google 日本語入力: 固定した版が最新なら exit 0 (.validation は数えず、GitHub の release を引かない)"
else
  ng "Google 日本語入力: 最新" "rc=$(rc "${d}") calls=$(calls "${d}") $(outerr "${d}")"
fi

# g2. 新しい版が winget に載って 10 日: exit 0 で待つ。載った日は、その版のディレクトリの commit の一覧から取る
d=$(new_case g2 3.34.6260.0 -)
put_commits "${d}" 3.35.6300.0 "${at10}"
FAKE_GH_CONTENTS="${gime_winget_next}" run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && ! seen "${d}" '⚠' && seen "${d}" "3\\.35\\.6300\\.0.*${at10:0:10}.*あと 20 日" \
  && called "${d}" -F 'api repos/microsoft/winget-pkgs/commits?path=manifests/g/Google/JapaneseIME/3.35.6300.0'; then
  ok "Google 日本語入力: 新しい版が winget に載って 10 日なら exit 0 で待つ (載った日は commit の一覧から)"
else
  ng "Google 日本語入力: 猶予の中" "rc=$(rc "${d}") calls=$(calls "${d}") $(outerr "${d}")"
fi

# g3. 新しい版が winget に載って 31 日: exit 1。版・manifest の URL・見送りの一覧の場所を出す
d=$(new_case g3 3.34.6260.0 -)
put_commits "${d}" 3.35.6300.0 "$(ago 31)"
FAKE_GH_CONTENTS="${gime_winget_next}" run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*3\.35\.6300\.0' && seen "${d}" -F "${g_tree}/3.35.6300.0" \
  && seen "${d}" -F 'skipped-versions.txt'; then
  ok "Google 日本語入力: 新しい版が winget に載って 31 日なら exit 1 で、manifest の URL と見送りの一覧の場所を出す"
else
  ng "Google 日本語入力: 猶予を過ぎた" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# g4. その版のディレクトリに commit がいくつかある (足した後に直された): いちばん古い commit (足した日) から
#     数える (31 日前に足し、2 日前に直した版は知らせる)
d=$(new_case g4 3.34.6260.0 -)
put_commits "${d}" 3.35.6300.0 "$(ago 2)" "$(ago 31)"
FAKE_GH_CONTENTS="${gime_winget_next}" run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*3\.35\.6300\.0'; then
  ok "Google 日本語入力: commit がいくつかあれば、いちばん古い commit の日から数える"
else
  ng "Google 日本語入力: いちばん古い commit" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# g5. 新しい版がいくつかあるときは、いちばん早く載った版から数える (25 日前の 3.35.6300.0 から数えて、あと 5 日)
d=$(new_case g5 3.34.6260.0 -)
put_commits "${d}" 3.35.6300.0 "$(ago 25)"
put_commits "${d}" 3.35.6310.0 "$(ago 5)"
FAKE_GH_CONTENTS="${gime_winget_next2}" run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && ! seen "${d}" '⚠' \
  && seen "${d}" '3\.35\.6300\.0.*あと 5 日' && seen "${d}" '3\.35\.6310\.0.*あと 5 日'; then
  ok "Google 日本語入力: 新しい版がいくつかあるときは、いちばん早く載った版から数える (あと 5 日)"
else
  ng "Google 日本語入力: いくつかの新しい版" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# g6. commit の一覧が取れない: 載った日が分からず猶予の中かを決められないので、⚠ を出さずに exit 2
d=$(new_case g6 3.34.6260.0 -)
FAKE_GH_CONTENTS="${gime_winget_next}" FAKE_GH_COMMITS_ERR='gh: HTTP 502' FAKE_GH_COMMITS_RC=1 run "${d}" 0
if [[ $(rc "${d}") == 2 ]] && ! seen "${d}" '⚠' && seen "${d}" '3\.35\.6300\.0' && seen "${d}" -F 'gh: HTTP 502'; then
  ok "Google 日本語入力: commit の一覧が取れなければ、⚠ を出さずに exit 2"
else
  ng "Google 日本語入力: commit の一覧が取れない" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# g7. commit の一覧が空: 載った日が分からないので待たずに exit 1
d=$(new_case g7 3.34.6260.0 -)
FAKE_GH_CONTENTS="${gime_winget_next}" run "${d}" 0
if [[ $(rc "${d}") == 1 ]] && seen "${d}" '⚠.*出た日が分からない'; then
  ok "Google 日本語入力: commit の一覧が空なら、出た日が分からないので待たずに exit 1"
else
  ng "Google 日本語入力: commit が無い" "rc=$(rc "${d}") $(outerr "${d}")"
fi

echo "-- 名前"

# n1. 名前が無い: 使い方 (名前の一覧) を出し、gh を呼ばずに exit 2
pkg=openssh
d=$(new_case n1 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_now}" run_args "${d}" 0
if [[ $(rc "${d}") == 2 ]] && ! gh_called "${d}" && seen "${d}" -F 'google-japanese-input'; then
  ok "名前が無ければ、名前の一覧を出して gh を呼ばずに exit 2"
else
  ng "名前が無い" "rc=$(rc "${d}") calls=$(calls "${d}") $(outerr "${d}")"
fi

# n2. 知らない名前: gh を呼ばずに exit 2
d=$(new_case n2 10.0.0.0 -)
FAKE_GH_CONTENTS="${winget_now}" run_args "${d}" 0 vscode "${d}/Install-OpenSSH.ps1"
if [[ $(rc "${d}") == 2 ]] && ! gh_called "${d}" && seen "${d}" -F 'vscode'; then
  ok "知らない名前なら、gh を呼ばずに exit 2"
else
  ng "知らない名前" "rc=$(rc "${d}") calls=$(calls "${d}") $(outerr "${d}")"
fi

# n3. 名前だけ渡すと、repo (script の 2 つ上) の win/<ディレクトリ>/ の ps1 と skipped-versions.txt を読む。
#     固定した版より新しい版を見送りの一覧に書いておき、その一覧を読んだことも確かめる
repo="${work}/repo"
mkdir -p "${repo}/nix/scripts"
cp "${script}" "${repo}/nix/scripts/check-winget-version.sh"
for spec in \
  'openssh|win/openssh|10.0.0.0|10.1.0.0' \
  "herdr|win/herdr|${h_latest}|0.9.5-preview.2026-10-20-0123456789ab" \
  'google-japanese-input|win/google-japanese-input|3.34.6260.0|3.35.6300.0'; do
  IFS='|' read -r pkg dir pinned newer <<<"${spec}"
  d=$(new_case "n3-${pkg}" "${pinned}" "${newer} 試したら設定が読めなかった")
  mkdir -p "${repo}/${dir}"
  cp "${d}/$(ps1_of "${pkg}")" "${d}/skipped-versions.txt" "${repo}/${dir}/"
  case ${pkg} in
    openssh) releases=${releases_now} ;;
    herdr) releases=$(herdr_releases_json 'preview-2026-10-14-fbd2ae23927f|2026-10-14T15:43:51Z') ;;
    *) releases='' ;;
  esac
  contents=$(contents_json "${pinned}" "${newer}")
  SCRIPT_FOR_TEST="${repo}/nix/scripts/check-winget-version.sh" FAKE_GH_CONTENTS="${contents}" \
    FAKE_GH_RELEASES="${releases}" run_args "${d}" 0 "${pkg}"
  if [[ $(rc "${d}") == 0 ]] && seen "${d}" -F "${dir}/$(ps1_of "${pkg}")" && seen "${d}" -F "${newer} は見送った"; then
    ok "${pkg}: 名前だけ渡すと、repo の ${dir}/ の ps1 と見送りの一覧を読む"
  else
    ng "${pkg}: 既定の場所" "rc=$(rc "${d}") calls=$(calls "${d}") $(outerr "${d}")"
  fi
done

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
