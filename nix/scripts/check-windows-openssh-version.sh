#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows の OpenSSH (winget の Microsoft.OpenSSH.Preview) で固定した版が、winget の最新に
# 追いついているかを確かめる。
#
#   check-windows-openssh-version.sh [<Install-OpenSSH.ps1> [<skipped-versions.txt>]]
#
# 既定では repo の win/openssh/Install-OpenSSH.ps1 の -Version の既定値 (固定した版。書くのはここ
# 1 か所だけ) を読み、winget-pkgs (winget の索引の元) の manifests/m/Microsoft/OpenSSH/Preview/<版>/
# の並びと比べる。GitHub API で読むので、Windows も winget も要らない。
#
# GitHub Actions の windows-openssh (.github/workflows/windows-openssh.yml) が週 1 回と、固定した版を
# 変える PR で流し、落ちることで知らせる (TKT-110)。win/ は flake からは見えない (ADR 010) ので、
# flake check ではなく checkout の上で走らせる。手元でも打てる (gh のログインが要る)。
#
# ## 知らせるもの (exit 1)
#
# - 固定した版より新しい版があり、見送りの一覧 (win/openssh/skipped-versions.txt) にも無い。
#   上げるか見送るかの手順は win/README.md の「OpenSSH の新しい版が出たとき」
# - 固定した版が winget-pkgs に無い (新しいマシンで Install-OpenSSH が入れられない)
# - Microsoft.OpenSSH.Preview が winget-pkgs に無い (Microsoft.OpenSSH.Beta は 2025-04-09 に
#   全部の版が外された)
#
# 確かめられなかったとき (固定した版が読めない・見送りの一覧が壊れている・API の失敗・gh が無い)
# は exit 2。揃っている扱いにはしない。
#
# ## 見送りの一覧
#
# 1 行に 1 つ、「版 理由」を空白で区切って書く。# で始まる行と空行は読まない。理由の無い行は
# exit 2。固定した版以下になった行は、消してよいと出すだけで落とさない。
#
# ## 依存
#
# bash・gh (GitHub API。CI では GH_TOKEN)・jq・sort (-V)。GitHub の ubuntu のランナーには
# どれも最初から入っている。

set -eu -o pipefail

script_dir=$(
  cd -- "$(dirname -- "$0")" &>/dev/null
  pwd -P
)
repo_dir=$(dirname "$(dirname "${script_dir}")")

usage() {
  cat <<'EOS'
Windows の OpenSSH で固定した版が、winget の最新に追いついているかを確かめる。

使い方:
  check-windows-openssh-version.sh [<Install-OpenSSH.ps1> [<skipped-versions.txt>]]

  既定は repo の win/openssh/Install-OpenSSH.ps1 と win/openssh/skipped-versions.txt。

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
if ((${#args[@]} > 2)); then
  usage >&2
  exit 2
fi
ps1=${args[0]:-${repo_dir}/win/openssh/Install-OpenSSH.ps1}
skipped_file=${args[1]:-${repo_dir}/win/openssh/skipped-versions.txt}
# 出力では、repo の中のファイルを repo からのパスで見せる (CI ではランナーの長いパスになるため)
ps1_label=${ps1#"${repo_dir}/"}
skipped_label=${skipped_file#"${repo_dir}/"}

package_id=Microsoft.OpenSSH.Preview
manifest_dir=manifests/m/Microsoft/OpenSSH/Preview
contents_api=repos/microsoft/winget-pkgs/contents/${manifest_dir}
releases_api='repos/PowerShell/Win32-OpenSSH/releases?per_page=30'
releases_page=https://github.com/PowerShell/Win32-OpenSSH/releases
version_re='^[0-9]+(\.[0-9]+){1,3}$'

# $1 が $2 より新しいか。sort -V で数として比べる (文字列の大小だと 9.8.3.0 > 10.0.0.0 になる)
newer_than() {
  [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]
}

for c in gh jq; do
  if ! command -v "${c}" &>/dev/null; then
    echo "!! ${c} が見つかりません (CI なら GitHub の ubuntu のランナーに入っている。手元なら home-manager switch)。" >&2
    exit 2
  fi
done

# 固定した版: Install-OpenSSH.ps1 の param の [string]$Version = '<版>'
pinned=""
pinned_re="^[[:space:]]*\\[string\\][\$]Version[[:space:]]*=[[:space:]]*'([0-9]+(\\.[0-9]+){1,3})'"
if [[ -r ${ps1} ]]; then
  while IFS= read -r line || [[ -n ${line} ]]; do
    if [[ ${line} =~ ${pinned_re} ]]; then
      pinned=${BASH_REMATCH[1]}
      break
    fi
  done <"${ps1}"
fi
if [[ -z ${pinned} ]]; then
  echo "!! 固定した版が読めません: ${ps1_label} に [string]\$Version = '<版>' の行がありません。" >&2
  exit 2
fi

# 見送りの一覧 (無ければ空)
skipped_versions=()
skipped_reasons=()
if [[ -f ${skipped_file} ]]; then
  n=0
  while IFS= read -r line || [[ -n ${line} ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    if [[ ${line} =~ ^[[:space:]]*(#|$) ]]; then
      continue
    fi
    read -r v reason <<<"${line}"
    if [[ ! ${v} =~ ${version_re} || -z ${reason} ]]; then
      echo "!! 見送りの一覧の ${n} 行目が読めません (${skipped_label}): ${line}" >&2
      echo "   1 行に「版 理由」を空白で区切って書く (例: 10.1.0.0 1Password の agent に繋がらない)。" >&2
      exit 2
    fi
    skipped_versions+=("${v}")
    skipped_reasons+=("${reason}")
  done <"${skipped_file}"
fi

# $1 を見送っていれば、理由を出して 0 を返す
skip_reason() {
  local i
  for i in "${!skipped_versions[@]}"; do
    if [[ ${skipped_versions[i]} == "$1" ]]; then
      printf '%s' "${skipped_reasons[i]}"
      return 0
    fi
  done
  return 1
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/check-windows-openssh-version.XXXXXX")
trap 'rm -rf "${tmp}"' EXIT

# winget-pkgs の版の一覧。404 はパッケージごと外されたとき (知らせる)。ほかの失敗は確かめられない
gone=0
versions=""
if ! gh api "${contents_api}" >"${tmp}/contents.json" 2>"${tmp}/contents.err"; then
  if ! grep -q 'HTTP 404' "${tmp}/contents.err"; then
    echo "!! winget-pkgs の ${manifest_dir} を読めませんでした (gh api ${contents_api}):" >&2
    sed 's/^/   /' "${tmp}/contents.err" >&2
    exit 2
  fi
  gone=1
else
  if ! names=$(jq -r 'if type == "array" then .[] | select(.type == "dir") | .name else error("ディレクトリの一覧ではない") end' \
    "${tmp}/contents.json" 2>"${tmp}/jq.err"); then
    echo "!! winget-pkgs の応答が読めませんでした (ディレクトリの一覧ではない):" >&2
    head -c 300 "${tmp}/contents.json" | sed 's/^/   /' >&2
    echo >&2
    exit 2
  fi
  versions=$(grep -E "${version_re}" <<<"${names}" | sort -V -r || true)
  if [[ -z ${versions} ]]; then
    gone=1
  fi
fi

findings=()
echo "Windows の OpenSSH (winget の ${package_id})"
echo "  固定した版  : ${pinned} (${ps1_label} の -Version の既定値)"

if ((gone)); then
  echo "⚠ ${package_id} が winget-pkgs に無い (${manifest_dir} が無い)。winget で入れられない"
  echo "    winget search OpenSSH で今のパッケージ ID を探し、Install-OpenSSH.ps1 とこの script を直す"
  findings+=("${package_id} が winget-pkgs に無い")
else
  list=$(tr '\n' ' ' <<<"${versions}")
  echo "  winget の版 : ${list% }"

  if ! grep -qxF "${pinned}" <<<"${versions}"; then
    echo "⚠ 固定した版 ${pinned} が winget-pkgs に無い。新しいマシンで Install-OpenSSH が入れられない"
    echo "    winget の版から選び直し、-Version の既定値を変える (win/README.md の「OpenSSH の新しい版が出たとき」)"
    findings+=("固定した版 ${pinned} が winget-pkgs に無い")
  fi

  unskipped=()
  while IFS= read -r v; do
    if newer_than "${v}" "${pinned}"; then
      if reason=$(skip_reason "${v}"); then
        echo "  ${v} は見送った (${reason})"
      else
        unskipped+=("${v}")
      fi
    fi
  done <<<"${versions}"

  if ((${#unskipped[@]})); then
    echo "⚠ 固定した版 ${pinned} より新しい版が winget にある: ${unskipped[*]}"
    # release notes の URL は添えるだけ。取れなくても知らせるのはやめない
    releases_ok=0
    if gh api "${releases_api}" >"${tmp}/releases.json" 2>"${tmp}/releases.err"; then
      releases_ok=1
    else
      echo "    (release の一覧が取れなかった: $(head -n 1 "${tmp}/releases.err"))"
    fi
    for v in "${unskipped[@]}"; do
      url=""
      if ((releases_ok)); then
        # tag の形は揃っていない (v9.8.3.0p2-Preview / 10.0.0.0p2-Preview) ので、winget と同じ版が
        # 名前に入る MSI (OpenSSH-Win64-v<版>.msi) を持つ release を探す
        url=$(jq -r --arg msi "OpenSSH-Win64-v${v}.msi" \
          'first(.[]? | select(any(.assets[]?; .name == $msi)) | .html_url) // empty' \
          "${tmp}/releases.json" 2>/dev/null || true)
      fi
      echo "    ${v} の release notes: ${url:-${releases_page}}"
    done
    echo "⚠ 上げるか見送るかを決める (win/README.md の「OpenSSH の新しい版が出たとき」):"
    echo "    上げる: 入れずに試してから、${ps1_label} の -Version の既定値を変える"
    echo "    見送る: ${skipped_label} に「版 理由」を 1 行足す"
    findings+=("固定した版 ${pinned} より新しい ${unskipped[*]} が winget にある (上げるか見送るかを決める)")
  fi
fi

for i in "${!skipped_versions[@]}"; do
  if ! newer_than "${skipped_versions[i]}" "${pinned}"; then
    echo "  ※ 見送りの一覧の ${skipped_versions[i]} は固定した版 (${pinned}) 以下なので、消してよい"
  fi
done

if ((${#findings[@]})); then
  # GitHub Actions では実行の画面の先頭に出す (workflow command)
  if [[ ${GITHUB_ACTIONS-} == true ]]; then
    for f in "${findings[@]}"; do
      echo "::error title=Windows の OpenSSH::${f}"
    done
  fi
  exit 1
fi
echo "固定した版 ${pinned} より新しい版で、見送っていないものは winget に無い。"
exit 0
