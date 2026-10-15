#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/check-windows-openssh-version.sh の振る舞いを、偽の gh と手で作った
# Install-OpenSSH.ps1 / skipped-versions.txt で確かめる。
#
#   bash nix/tests/check-windows-openssh-version.test.sh [<script のパス>]
#
# flake の checks (check-windows-openssh-version-test) が Nix のサンドボックスで流す。
# CI の `nix flake check` もこれを通る。使うのは bash・jq・coreutils・grep だけ。
#
# ## 確かめること
#
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
#   - 猶予の日数は CHECK_WINDOWS_OPENSSH_GRACE_DAYS で変えられる
#   - GitHub Actions の中では、落ちるときに ::error の行を、猶予の中の版には ::notice の行を出す
#
# ## 本物の gh を見せない
#
# 手元では PATH に本物の gh があり、見えると本物の GitHub API を呼ぶ。要るコマンドだけを
# symlink で並べた PATH で流す (bootstrap-windows-openssh.test.sh と同じ作り)。偽の gh の shebang は
# $BASH から作る (サンドボックスに /usr/bin/env が無い)。偽の gh が返す JSON は、本物の API の
# 応答 (2026-10-15 に取ったもの) と同じ形にしてある。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/check-windows-openssh-version.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/check-windows-openssh-version-test.XXXXXX")
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
#   contents (winget-pkgs のディレクトリ)  FAKE_GH_CONTENTS (stdout)・FAKE_GH_CONTENTS_ERR (stderr)・FAKE_GH_CONTENTS_RC
#   releases (Win32-OpenSSH)               FAKE_GH_RELEASES・FAKE_GH_RELEASES_ERR・FAKE_GH_RELEASES_RC
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
  repos/PowerShell/Win32-OpenSSH/releases*)
    out=${FAKE_GH_RELEASES-} err=${FAKE_GH_RELEASES_ERR-} rc=${FAKE_GH_RELEASES_RC:-0} ;;
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

# winget-pkgs の manifests/m/Microsoft/OpenSSH/Preview の一覧 (contents API の応答)。
# 引数は版 (ディレクトリ)。file: で始めるとファイルの項目にする
contents_json() {
  local e base='https://api.github.com/repos/microsoft/winget-pkgs'
  for e in "$@"; do
    if [[ ${e} == file:* ]]; then
      jq -n --arg n "${e#file:}" --arg base "${base}" '{
        _links: {
          git: ($base + "/git/blobs/0000000000000000000000000000000000000000"),
          html: ("https://github.com/microsoft/winget-pkgs/blob/master/manifests/m/Microsoft/OpenSSH/Preview/" + $n),
          self: ($base + "/contents/manifests/m/Microsoft/OpenSSH/Preview/" + $n + "?ref=master")
        },
        download_url: ("https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/m/Microsoft/OpenSSH/Preview/" + $n),
        git_url: ($base + "/git/blobs/0000000000000000000000000000000000000000"),
        html_url: ("https://github.com/microsoft/winget-pkgs/blob/master/manifests/m/Microsoft/OpenSSH/Preview/" + $n),
        name: $n,
        path: ("manifests/m/Microsoft/OpenSSH/Preview/" + $n),
        sha: "0000000000000000000000000000000000000000",
        size: 123,
        type: "file",
        url: ($base + "/contents/manifests/m/Microsoft/OpenSSH/Preview/" + $n + "?ref=master")
      }'
      continue
    fi
    jq -n --arg v "${e}" --arg base "${base}" '{
      _links: {
        git: ($base + "/git/trees/0000000000000000000000000000000000000000"),
        html: ("https://github.com/microsoft/winget-pkgs/tree/master/manifests/m/Microsoft/OpenSSH/Preview/" + $v),
        self: ($base + "/contents/manifests/m/Microsoft/OpenSSH/Preview/" + $v + "?ref=master")
      },
      download_url: null,
      git_url: ($base + "/git/trees/0000000000000000000000000000000000000000"),
      html_url: ("https://github.com/microsoft/winget-pkgs/tree/master/manifests/m/Microsoft/OpenSSH/Preview/" + $v),
      name: $v,
      path: ("manifests/m/Microsoft/OpenSSH/Preview/" + $v),
      sha: "0000000000000000000000000000000000000000",
      size: 0,
      type: "dir",
      url: ($base + "/contents/manifests/m/Microsoft/OpenSSH/Preview/" + $v + "?ref=master")
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
# 猶予 (30 日) の境目を確かめる release。ago N は、出てからの日数が N になる公開日時、rel <版> <公開日時> は
# releases_json の 1 件。ちょうど N 日前にすると、script が日数を数えるまでの間に時計が 1 秒戻るだけで
# N - 1 日になる (手元で 8 本並べて流したとき、40 日が 39 日になって落ちた)。半日ずらし、どちらへ時計が
# ずれても日数が変わらないようにする
ago() { date -u -d "-$1 day -12 hour" +%Y-%m-%dT%H:%M:%SZ; }
rel() { printf 'v%sp1-Preview|%s|%s' "$1" "$1" "$2"; }
at29=$(ago 29)
# 昨日出た 10.1.0.0 (まだ winget に載っていなくてよい)・Win64 の MSI を持たない 10.1.0.0
releases_101_recent=$(releases_json "$(rel 10.1.0.0 "$(ago 1)")" "${rel_100}" "${rel_983}")
releases_101_nomsi=$(releases_json 'v10.1.0.0p1-Preview||2026-03-02T18:00:00Z' "${rel_100}" "${rel_983}")
not_found='{"message":"Not Found","documentation_url":"https://docs.github.com/rest/repos/contents#get-repository-content","status":"404"}'

# 1 ケースぶんのディレクトリを作る。
#   $1: 名前、$2: 固定した版 (空なら -Version の行を書かない)、$3: 見送りの一覧の中身 (- なら作らない)、
#   $4: パッケージ ID (省くと Microsoft.OpenSSH.Preview、- なら $packageId の行を書かない)
# Install-OpenSSH.ps1 は本物と同じく BOM 付きで、param ブロックと Invoke-InstallOpenSsh の形も本物に合わせる。
new_case() {
  local d="${work}/$1" id=${4:-Microsoft.OpenSSH.Preview}
  mkdir -p "${d}"
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
    if [[ ${id} != - ]]; then
      printf "    \$packageId = '%s'\n" "${id}"
    fi
    # shellcheck disable=SC2016
    printf '    $installDir = Join-Path $env:ProgramFiles '"'"'OpenSSH'"'"'\n}\n'
  } >"${d}/Install-OpenSSH.ps1"
  if [[ $3 != - ]]; then
    printf '%s\n' "$3" >"${d}/skipped-versions.txt"
  fi
  : >"${d}/gh-calls"
  echo "${d}"
}

# $1: ケースのディレクトリ、$2: 1 なら偽の gh を PATH に置かない、残り: script の引数。
# 引数を渡さなければ、ケースの Install-OpenSSH.ps1 と skipped-versions.txt を渡す。
# 環境変数 (FAKE_GH_*・GITHUB_ACTIONS_FOR_TEST・GRACE_DAYS_FOR_TEST) は呼び出し側で付ける。
run() {
  local d=$1 nogh=$2
  shift 2
  local path="${fake_bin}:${sys_bin}"
  if [[ ${nogh} == 1 ]]; then
    path="${sys_bin}"
  fi
  if (($# == 0)); then
    set -- "${d}/Install-OpenSSH.ps1" "${d}/skipped-versions.txt"
  fi
  env PATH="${path}" FAKE_GH_LOG="${d}/gh-calls" GITHUB_ACTIONS="${GITHUB_ACTIONS_FOR_TEST-}" \
    CHECK_WINDOWS_OPENSSH_GRACE_DAYS="${GRACE_DAYS_FOR_TEST-}" \
    "${BASH}" "${script}" "$@" >"${d}/out" 2>"${d}/err"
  echo $? >"${d}/rc"
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

echo "== check-windows-openssh-version.sh: ${script}"

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
run "${d}" 0 "${d}/no-such.ps1" "${d}/skipped-versions.txt"
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
FAKE_GH_CONTENTS="${winget_now}" run "${d}" 0 --bogus
if [[ $(rc "${d}") == 2 ]] && ! gh_called "${d}"; then
  ok "知らない引数は、gh を呼ばずに exit 2"
else
  ng "知らない引数" "rc=$(rc "${d}") calls=$(calls "${d}") $(outerr "${d}")"
fi

# 26. 猶予の日数は CHECK_WINDOWS_OPENSSH_GRACE_DAYS で変えられる (60 日なら、出て 40 日の版はまだ待つ)
d=$(new_case t26 10.0.0.0 -)
GRACE_DAYS_FOR_TEST=60 FAKE_GH_CONTENTS="${winget_101}" FAKE_GH_RELEASES=$(releases_json "$(rel 10.1.0.0 "$(ago 40)")" "${rel_100}") run "${d}" 0
if [[ $(rc "${d}") == 0 ]] && seen "${d}" '10\.1\.0\.0.*あと 20 日'; then
  ok "猶予の日数は CHECK_WINDOWS_OPENSSH_GRACE_DAYS で変えられる (60 日なら、出て 40 日の版はあと 20 日)"
else
  ng "猶予の日数を変える" "rc=$(rc "${d}") $(outerr "${d}")"
fi

# 27. 猶予の日数が読めない: gh を呼ばずに exit 2 (030 は bash の算術で 8 進数になるので受けない)
i=0
for g in '1か月' '-1' '030'; do
  i=$((i + 1))
  d=$(new_case "t27-${i}" 10.0.0.0 -)
  GRACE_DAYS_FOR_TEST=${g} FAKE_GH_CONTENTS="${winget_now}" FAKE_GH_RELEASES="${releases_now}" run "${d}" 0
  if [[ $(rc "${d}") == 2 ]] && ! gh_called "${d}" && seen "${d}" -F 'CHECK_WINDOWS_OPENSSH_GRACE_DAYS'; then
    ok "猶予の日数が ${g} なら、gh を呼ばずに exit 2"
  else
    ng "猶予の日数 ${g}" "rc=$(rc "${d}") calls=$(calls "${d}") $(outerr "${d}")"
  fi
done

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
