#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows の OpenSSH (winget の Microsoft.OpenSSH.Preview) で固定した版が、winget の最新に
# 追いついているかを確かめる。
#
#   check-winget-version.sh [<Install-OpenSSH.ps1> [<skipped-versions.txt>]]
#
# 既定では repo の win/openssh/Install-OpenSSH.ps1 から、-Version の既定値 (固定した版) と
# $packageId (winget のパッケージ ID) を読む。どちらも書くのはそこ 1 か所だけ。それを
# winget-pkgs (winget の索引の元) の manifests/<頭文字>/<ID の . を / に>/<版>/ の並び
# (今は manifests/m/Microsoft/OpenSSH/Preview/) と比べる。GitHub API で読むので、Windows も
# winget も要らない。
#
# GitHub Actions の windows-openssh (.github/workflows/windows-openssh.yml) が週 1 回と PR で流し、
# 落ちることで知らせる (TKT-110)。win/ は flake からは見えない (ADR 010) ので、flake check ではなく
# checkout の上で走らせる。手元でも打てる (gh のログインが要る)。
#
# ## 知らせるもの (exit 1)
#
# 新しい版は、GitHub (PowerShell/Win32-OpenSSH) に出てから猶予の 30 日がたつまで知らせない。
# 猶予の中は exit 0 で、版・出た日・あと何日で知らせるかを ※ の 1 行に出す (GitHub Actions の中なら
# ::notice の行にも)。数えるのは、追いついていない版 (見送った版は除く) のうち、いちばん早く出た版の
# 日から (遅れ始めてから 30 日で知らせる。新しい版が続けて出ても先送りしない)。日数を決めるのは、
# この下の grace_days の 1 か所だけ (テストは環境変数 CHECK_WINDOWS_OPENSSH_GRACE_DAYS で変える)。
#
# - 固定した版より新しい版が winget にあり、見送りの一覧 (win/openssh/skipped-versions.txt) にも無い。
#   上げるか見送るかの手順は win/README.md の「OpenSSH の新しい版が出たとき」。その版に合う GitHub の
#   release (OpenSSH-Win64-v<版>.msi を持つもの) が無く、出た日が分からないときは待たない
# - GitHub の release の版 (prerelease は除く) が、winget のこのパッケージに無い (見送った版は除く)。
#   パッケージ ID が移ると、古い ID には新しい版が来ないまま残る (2024-10 に Preview ができてから、
#   Beta には 9.5.0.0 より新しい版が来なかった)。これまで載るまでは 5 時間〜4 日だった
#
# 次は新しい版の知らせではなく、壊れていることの知らせなので、猶予を置かない。
#
# - 固定した版が winget-pkgs に無い (新しいマシンで Install-OpenSSH が入れられない)
# - パッケージが winget-pkgs に無い (Microsoft.OpenSSH.Beta は 2025-04-09 に全部の版が外された)
# - 版の形でないディレクトリがある (版の付け方が変わると、新しい版を読み落とす)
# - GitHub の最新 release に OpenSSH-Win64-v<版>.msi が無い (名前が変わると、版も出た日も引けない)
#
# 確かめられなかったとき (Install-OpenSSH.ps1 が読めない・見送りの一覧が壊れている・API の失敗・
# gh が無い・猶予の日数が読めない) は exit 2。揃っている扱いにはしない。GitHub の release の一覧だけが
# 取れないときも、新しい版が猶予の中かを決められないので exit 2。知らせることもあれば exit 1 を優先する。
# GitHub Actions の中では、落ちる理由を ::error の行にも出す (実行の画面の先頭に出る)。
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

# 新しい版を知らせるまでの猶予 (GitHub に出てからの日数)。決めるのはここ 1 か所だけ。
# テストは CHECK_WINDOWS_OPENSSH_GRACE_DAYS で変える (空なら既定)
grace_days=${CHECK_WINDOWS_OPENSSH_GRACE_DAYS:-30}

script_dir=$(
  cd -- "$(dirname -- "$0")" &>/dev/null
  pwd -P
)
repo_dir=$(dirname "$(dirname "${script_dir}")")

usage() {
  cat <<'EOS'
Windows の OpenSSH で固定した版が、winget の最新に追いついているかを確かめる。

使い方:
  check-winget-version.sh [<Install-OpenSSH.ps1> [<skipped-versions.txt>]]

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

releases_api='repos/PowerShell/Win32-OpenSSH/releases?per_page=30'
releases_page=https://github.com/PowerShell/Win32-OpenSSH/releases
version_re='^[0-9]+(\.[0-9]+){1,3}$'

# GitHub Actions の中なら、実行の画面の先頭に出る ::<$1> の行 (error か notice) を出す (workflow command)。
# 本文の % と改行は、GitHub の決まりどおりに書き換える
annotate() {
  local level=$1 m=$2
  if [[ ${GITHUB_ACTIONS-} != true ]]; then
    return 0
  fi
  m=${m//'%'/'%25'}
  m=${m//$'\r'/'%0D'}
  m=${m//$'\n'/'%0A'}
  echo "::${level} title=Windows の OpenSSH::${m}"
}

# 確かめられなかった: 1 つめの引数を見出しに、残りを字下げして stderr へ出し、exit 2
cannot_check() {
  local first=$1
  shift
  echo "!! ${first}" >&2
  if (($#)); then
    printf '%s\n' "$@" | sed 's/^/   /' >&2
  fi
  annotate error "確かめられなかった: ${first}"
  exit 2
}

# $1 が $2 より新しいか。sort -V で数として比べる (文字列の大小だと 9.8.3.0 > 10.0.0.0 になる)
newer_than() {
  [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]
}

# 030 のような 0 始まりは、bash の算術で 8 進数として読まれるので受けない
if [[ ! ${grace_days} =~ ^(0|[1-9][0-9]*)$ ]]; then
  cannot_check "猶予の日数が読めません (CHECK_WINDOWS_OPENSSH_GRACE_DAYS=${grace_days})。0 か、0 で始まらない整数 (日数) を渡す。"
fi

for c in gh jq; do
  if ! command -v "${c}" &>/dev/null; then
    cannot_check "${c} が見つかりません (CI なら GitHub の ubuntu のランナーに入っている。手元なら home-manager switch)。"
  fi
done

# Install-OpenSSH.ps1 から、固定した版 (param の [string]$Version = '<版>') と
# パッケージ ID ($packageId = '<ID>') を読む
if [[ ! -r ${ps1} ]]; then
  cannot_check "Install-OpenSSH.ps1 が読めません: ${ps1_label}"
fi
pinned=""
package_id=""
pinned_re="^[[:space:]]*\\[string\\][\$]Version[[:space:]]*=[[:space:]]*'([0-9]+(\\.[0-9]+){1,3})'"
id_re="^[[:space:]]*[\$]packageId[[:space:]]*=[[:space:]]*'([A-Za-z0-9][A-Za-z0-9.-]*)'"
while IFS= read -r line || [[ -n ${line} ]]; do
  if [[ -z ${pinned} && ${line} =~ ${pinned_re} ]]; then
    pinned=${BASH_REMATCH[1]}
  elif [[ -z ${package_id} && ${line} =~ ${id_re} ]]; then
    package_id=${BASH_REMATCH[1]}
  fi
done <"${ps1}"
if [[ -z ${pinned} ]]; then
  cannot_check "固定した版が読めません: ${ps1_label} に [string]\$Version = '<版>' の行がありません。"
fi
if [[ -z ${package_id} ]]; then
  cannot_check "パッケージ ID が読めません: ${ps1_label} に \$packageId = '<ID>' の行がありません。"
fi
# winget-pkgs の置き場所: manifests/<ID の頭文字 (小文字)>/<ID の . を / にしたもの>
initial=${package_id:0:1}
manifest_dir="manifests/${initial,,}/${package_id//.//}"
contents_api="repos/microsoft/winget-pkgs/contents/${manifest_dir}"

# 見送りの一覧 (無ければ空)。win/ の ps1 と同じく BOM 付き・CRLF で保存されても読む
skipped_versions=()
skipped_reasons=()
if [[ -f ${skipped_file} ]]; then
  n=0
  while IFS= read -r line || [[ -n ${line} ]]; do
    n=$((n + 1))
    if ((n == 1)); then
      line=${line#$'\xef\xbb\xbf'}
    fi
    line=${line%$'\r'}
    if [[ ${line} =~ ^[[:space:]]*(#|$) ]]; then
      continue
    fi
    read -r v reason <<<"${line}"
    if [[ ! ${v} =~ ${version_re} || -z ${reason} ]]; then
      cannot_check "見送りの一覧の ${n} 行目が読めません (${skipped_label}): ${line}" \
        "1 行に「版 理由」を空白で区切って書く (例: 10.1.0.0 1Password の agent に繋がらない)。"
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

# $1 の版の Win64 の MSI を持つ release のうち、いちばん早く出たものの行 (release_rows の 1 行) を出す。
# 無ければ 1 を返す
release_of() {
  local row
  while IFS= read -r row; do
    if [[ -n ${row} && ${row%%$'\x1f'*} == "$1" ]]; then
      printf '%s\n' "${row}"
      return 0
    fi
  done <<<"${release_rows}"
  return 1
}

# 猶予の中の版の、出た日とあと何日で知らせるか。$1: 追いついていない版の数、$2: いちばん早く出た版、
# $3: その版が GitHub に出た日、$4: 出てからの日数
grace_left() {
  local who=""
  if (($1 > 1)); then
    who="、いちばん早い $2 が"
  fi
  echo "GitHub に出たのは${who} $3 ($4 日前)。あと $((grace_days - $4)) 日で知らせる (猶予 ${grace_days} 日)"
}

# 猶予がたった版の、出てからの日数。引数は grace_left の $1・$2・$4
grace_over() {
  local who=""
  if (($1 > 1)); then
    who="いちばん早い $2 が "
  fi
  echo "${who}GitHub に出て $3 日たった。猶予は ${grace_days} 日"
}

# 猶予の中の版を、※ の 1 行で出す。GitHub Actions の中なら、同じ文を ::notice の行にも出す
wait_note() {
  echo "  ※ $1"
  annotate notice "$1"
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/check-winget-version.XXXXXX")
trap 'rm -rf "${tmp}"' EXIT

# winget-pkgs の版の一覧。404 はパッケージごと外されたとき (知らせる)。ほかの失敗は確かめられない
gone=0
versions=""
odd=""
if ! gh api "${contents_api}" >"${tmp}/contents.json" 2>"${tmp}/contents.err"; then
  if ! grep -q 'HTTP 404' "${tmp}/contents.err"; then
    cannot_check "winget-pkgs の ${manifest_dir} を読めませんでした (gh api ${contents_api}):" \
      "$(cat "${tmp}/contents.err")"
  fi
  gone=1
else
  if ! names=$(jq -r 'if type == "array" then .[] | select(.type == "dir") | .name else error("ディレクトリの一覧ではない") end' \
    "${tmp}/contents.json" 2>/dev/null); then
    cannot_check "winget-pkgs の応答が読めませんでした (ディレクトリの一覧ではない):" \
      "$(head -c 300 "${tmp}/contents.json")"
  fi
  if [[ -z ${names} ]]; then
    gone=1
  fi
  versions=$(grep -E "${version_re}" <<<"${names}" | sort -V -r || true)
  odd=$(grep -vE "${version_re}" <<<"${names}" || true)
fi

findings=()
echo "Windows の OpenSSH (winget の ${package_id})"
echo "  固定した版    : ${pinned} (${ps1_label} の -Version の既定値)"

if ((gone)); then
  echo "⚠ ${package_id} が winget-pkgs に無い (${manifest_dir} が無い)。winget で入れられない"
  echo "    winget search OpenSSH で今のパッケージ ID を探し、${ps1_label} の \$packageId を直す"
  findings+=("${package_id} が winget-pkgs に無い")
  annotate error "${findings[-1]}"
  exit 1
fi

list=$(tr '\n' ' ' <<<"${versions}")
echo "  winget の版   : ${list% }"
winget_latest=$(head -n 1 <<<"${versions}")

if [[ -n ${odd} ]]; then
  echo "⚠ 版の形でないディレクトリが winget-pkgs の ${manifest_dir} にある: $(tr '\n' ' ' <<<"${odd}")"
  echo "    版の付け方が変わったなら、新しい版を読み落とす。この script の版の読み方を直す"
  findings+=("版の形でないディレクトリが winget-pkgs にある: $(tr '\n' ' ' <<<"${odd}")")
fi

if ! grep -qxF "${pinned}" <<<"${versions}"; then
  echo "⚠ 固定した版 ${pinned} が winget-pkgs に無い。新しいマシンで Install-OpenSSH が入れられない"
  echo "    winget の版から選び直し、-Version の既定値を変える (win/README.md の「OpenSSH の新しい版が出たとき」)"
  findings+=("固定した版 ${pinned} が winget-pkgs に無い")
fi

unskipped=()
if [[ -n ${versions} ]]; then
  while IFS= read -r v; do
    if newer_than "${v}" "${pinned}"; then
      if reason=$(skip_reason "${v}"); then
        echo "  ${v} は見送った (${reason})"
      else
        unskipped+=("${v}")
      fi
    fi
  done <<<"${versions}"
fi

# GitHub の releases。新しい版が出た日と release notes の URL を引くのと、winget に載るのが止まって
# いないかを見る
releases_ok=0
releases_problem=""
latest=""
release_rows=""
if gh api "${releases_api}" >"${tmp}/releases.json" 2>"${tmp}/releases.err"; then
  # latest: 下書きと prerelease を除き、いちばん新しく出た release の tag・Win64 の MSI の版・出てからの
  # 日数・URL。release_rows: Win64 の MSI を持つ release を出た順 (古い順) に 1 行ずつ、MSI の版・
  # 出た時刻 (epoch)・出た日・出てからの日数・prerelease か (1 / 0)・URL。tag の形は揃っていない
  # (v9.8.3.0p2-Preview / 10.0.0.0p2-Preview) ので、winget の版とは MSI (OpenSSH-Win64-v<版>.msi) の
  # 名前で突き合わせる。空の欄が詰まらないよう、区切りは空白でない \x1f にする
  if latest=$(jq -r '
      [.[]? | select((.draft or .prerelease) | not)] | max_by(.published_at) // empty
      | [ .tag_name,
          ([.assets[]?.name | capture("^OpenSSH-Win64-v(?<v>[0-9]+(\\.[0-9]+){1,3})\\.msi$").v] | first // ""),
          ((now - (.published_at | fromdateiso8601)) / 86400 | floor | tostring),
          .html_url ]
      | join("\u001f")' "${tmp}/releases.json" 2>/dev/null) && [[ -n ${latest} ]] \
    && release_rows=$(jq -r '
      [.[]? | select((.draft | not) and .published_at != null)
        | { v: ([.assets[]?.name | capture("^OpenSSH-Win64-v(?<v>[0-9]+(\\.[0-9]+){1,3})\\.msi$").v] | first // ""),
            at: (.published_at | fromdateiso8601), day: .published_at[0:10],
            pre: (.prerelease == true), url: .html_url }
        | select(.v != "") ]
      | sort_by(.at)[]
      | [ .v, (.at | tostring), .day, ((now - .at) / 86400 | floor | tostring),
          (if .pre then "1" else "0" end), .url ]
      | join("\u001f")' "${tmp}/releases.json" 2>/dev/null); then
    releases_ok=1
  else
    releases_problem="GitHub の release の一覧が読めない (${releases_api} の応答が release の一覧ではない)"
  fi
else
  releases_problem="GitHub の release の一覧が取れない ($(head -n 1 "${tmp}/releases.err"))"
fi

# 固定した版より新しく、見送っていない版。GitHub に出てから猶予の日数がたつまでは待つ。数えるのは
# いちばん早く出た版から (遅れ始めてから数える)。出た日が分からない版があれば待たない
waiting=0
if ((${#unskipped[@]})); then
  if ((releases_ok)); then
    first_v=""
    first_at=""
    first_day=""
    first_age=0
    undated=()
    for v in "${unskipped[@]}"; do
      if row=$(release_of "${v}"); then
        IFS=$'\x1f' read -r _ at day age _ _ <<<"${row}"
        if [[ -z ${first_at} ]] || ((at < first_at)); then
          first_v=${v}
          first_at=${at}
          first_day=${day}
          first_age=${age}
        fi
      else
        undated+=("${v}")
      fi
    done
    if ((${#undated[@]} == 0 && first_age < grace_days)); then
      waiting=1
      wait_note "固定した版 ${pinned} より新しい ${unskipped[*]} が winget にある。$(grace_left "${#unskipped[@]}" "${first_v}" "${first_day}" "${first_age}")"
    else
      if ((${#undated[@]})); then
        why="${undated[*]} に合う GitHub の release が無く、出た日が分からないので待たない"
      else
        why=$(grace_over "${#unskipped[@]}" "${first_v}" "${first_age}")
      fi
      echo "⚠ 固定した版 ${pinned} より新しい版が winget にある: ${unskipped[*]} (${why})"
      for v in "${unskipped[@]}"; do
        url=""
        if row=$(release_of "${v}"); then
          url=${row##*$'\x1f'}
        fi
        echo "    ${v} の release notes: ${url:-${releases_page}}"
      done
      echo "⚠ 上げるか見送るかを決める (win/README.md の「OpenSSH の新しい版が出たとき」):"
      echo "    上げる: 入れずに試してから、${ps1_label} の -Version の既定値を変える"
      echo "    見送る: ${skipped_label} に「版 理由」を 1 行足す"
      findings+=("固定した版 ${pinned} より新しい ${unskipped[*]} が winget にある (上げるか見送るかを決める)")
    fi
  else
    echo "  ※ 固定した版 ${pinned} より新しい ${unskipped[*]} が winget にあるが、GitHub に出た日が分からず、待つか知らせるかを決められない"
  fi
fi

if ((releases_ok)); then
  IFS=$'\x1f' read -r gh_tag gh_v gh_age gh_url <<<"${latest}"
  echo "  GitHub の最新 : ${gh_v:-?} (${gh_tag}、出て ${gh_age} 日)"
  if [[ -z ${gh_v} ]]; then
    echo "⚠ GitHub の最新 release ${gh_tag} に OpenSSH-Win64-v<版>.msi が無い。名前が変わったなら、この script の読み方を直す"
    echo "    ${gh_url}"
    findings+=("GitHub の最新 release ${gh_tag} に OpenSSH-Win64-v<版>.msi が無い")
  elif [[ -n ${winget_latest} ]]; then
    # GitHub にあって、winget のこのパッケージの最新より新しい版 (prerelease と見送った版は除く)。
    # release_rows は出た順なので、最初に見つかった行がいちばん早く出た版
    ahead=()
    ahead_row=""
    while IFS= read -r row; do
      if [[ -z ${row} ]]; then
        continue
      fi
      IFS=$'\x1f' read -r v _ _ _ pre _ <<<"${row}"
      if [[ ${pre} == 0 && " ${ahead[*]-} " != *" ${v} "* ]] && newer_than "${v}" "${winget_latest}" \
        && ! skip_reason "${v}" >/dev/null; then
        ahead+=("${v}")
        if [[ -z ${ahead_row} ]]; then
          ahead_row=${row}
        fi
      fi
    done <<<"${release_rows}"
    if ((${#ahead[@]})); then
      IFS=$'\x1f' read -r first_v _ first_day first_age _ first_url <<<"${ahead_row}"
      if ((first_age < grace_days)); then
        waiting=1
        wait_note "GitHub の ${ahead[*]} が winget の ${package_id} にまだ無い。$(grace_left "${#ahead[@]}" "${first_v}" "${first_day}" "${first_age}")"
      else
        why=$(grace_over "${#ahead[@]}" "${first_v}" "${first_age}")
        echo "⚠ GitHub の ${ahead[*]} が winget の ${package_id} に無い (${why})"
        echo "    パッケージ ID が移ったかもしれない (Beta から Preview へ移った前例がある)。winget search OpenSSH で確かめる"
        echo "    ${first_url}"
        findings+=("GitHub の ${ahead[*]} が winget の ${package_id} に無い (${why})")
      fi
    fi
  fi
else
  echo "  ※ ${releases_problem}"
fi

for i in "${!skipped_versions[@]}"; do
  if ! newer_than "${skipped_versions[i]}" "${pinned}"; then
    echo "  ※ 見送りの一覧の ${skipped_versions[i]} は固定した版 (${pinned}) 以下なので、消してよい"
  fi
done

if ((${#findings[@]})); then
  for f in "${findings[@]}"; do
    annotate error "${f}"
  done
  exit 1
fi
if [[ -n ${releases_problem} ]]; then
  if ((${#unskipped[@]})); then
    cannot_check "${releases_problem}" "固定した版より新しい ${unskipped[*]} が GitHub に出た日が分からず、猶予の中かを決められなかった。"
  fi
  cannot_check "${releases_problem}" "winget の版では知らせることは無いが、GitHub の最新 release と比べられなかった。"
fi
if ((waiting)); then
  echo "知らせることは無い (新しい版は猶予の中。上げるか見送るかは、知らせる前に決めてもよい)。"
else
  echo "固定した版 ${pinned} より新しい版で、見送っていないものは winget にも GitHub にも無い。"
fi
exit 0
