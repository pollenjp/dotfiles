#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows で winget の版を固定しているもの (OpenSSH・herdr・Google 日本語入力) が、winget の最新に
# 追いついているかを確かめる。
#
#   check-winget-version.sh <名前> [<Install-*.ps1> [<skipped-versions.txt>]]
#
#   名前                    固定した版を書く ps1 (repo の win/ から)                  出た日 (猶予を数える起点)
#   openssh                 openssh/Install-OpenSSH.ps1                              GitHub (PowerShell/Win32-OpenSSH) の release
#   herdr                   herdr/Install-Herdr.ps1                                  GitHub (herdrdev/herdr) の preview の release
#   google-japanese-input   google-japanese-input/Install-GoogleJapaneseInput.ps1    winget-pkgs に載った日
#
# ps1 から、-Version の既定値 (固定した版) と $packageId (winget のパッケージ ID) を読む。どちらも
# 書くのはそこ 1 か所だけ。それを winget-pkgs (winget の索引の元) の manifests/<頭文字>/<ID の . を / に>/<版>/
# の並びと比べる。GitHub API で読むので、Windows も winget も要らない。見送りの一覧は ps1 の隣の
# skipped-versions.txt。
#
# GitHub Actions の winget-versions (.github/workflows/winget-versions.yml) が週 1 回と PR で、名前ごとの
# job で流し、落ちることで知らせる (TKT-110・TKT-156)。win/ は flake からは見えない (ADR 010) ので、
# flake check ではなく checkout の上で走らせる。手元でも打てる (gh のログインが要る)。
#
# ## 出た日
#
# 新しい版を知らせるまでの猶予は、その版が出た日から数える。どこから取るかは名前ごとに違う。
#
# - openssh: GitHub の release が出た日。tag の形が揃っていない (v9.8.3.0p2-Preview / 10.0.0.0p2-Preview)
#   ので、winget の版とは Win64 の MSI (OpenSSH-Win64-v<版>.msi) の名前で突き合わせる
# - herdr: GitHub の preview の build (prerelease) の release が出た日。winget の版
#   (<semver>-preview.<日付>-<hash>) の -preview. の後ろと、tag (preview-<日付>-<hash>) の preview- の後ろで
#   突き合わせる。版の中の日付はビルドの日なので使わない
# - google-japanese-input: GitHub の release が無いので、その版のディレクトリを winget-pkgs に足した commit
#   (commits?path=… のいちばん古いもの) の日。manifest の ReleaseDate は版によって無い (2026-10 の時点で
#   10 個のうち 1 個)
#
# ## 知らせるもの (exit 1)
#
# 新しい版は、出てから猶予の 30 日がたつまで知らせない。猶予の中は exit 0 で、版・出た日・あと何日で
# 知らせるかを ※ の 1 行に出す (GitHub Actions の中なら ::notice の行にも)。数えるのは、追いついていない版
# (見送った版は除く) のうち、いちばん早く出た版の日から (遅れ始めてから 30 日で知らせる。新しい版が続けて
# 出ても先送りしない)。日数を決めるのは、この下の grace_days の 1 か所だけ (テストは環境変数
# CHECK_WINGET_VERSION_GRACE_DAYS で変える)。
#
# - 固定した版より新しい版が winget にあり、見送りの一覧にも無い。上げるか見送るかの手順は win/README.md の
#   「<名前> の新しい版が出たとき」。出た日が分からない (合う release や commit が無い) ときは待たない
# - GitHub の release の版が、winget のこのパッケージの最新より新しいのに winget に無い (見送った版は除く。
#   openssh と herdr だけ)。パッケージ ID が移ると、古い ID には新しい版が来ないまま残る (2024-10 に
#   Microsoft.OpenSSH.Preview ができてから、Beta には 9.5.0.0 より新しい版が来なかった)。比べるのは winget に
#   載る側の release だけ (openssh は prerelease を除き、herdr は preview だけ。herdr の安定版は winget に
#   パッケージが無い)。新しいかは、openssh は版で比べ、herdr は winget の最新に合う release より後に出たかで
#   決める (鍵の <日付>-<hash> では、同じ日の build の前後が hash の大小になる。合う release が無ければ鍵で
#   比べる)。google-japanese-input は比べる相手が無く、ID が移っても気付けない
#
# 次は新しい版の知らせではなく、壊れていることの知らせなので、猶予を置かない。
#
# - 固定した版が winget-pkgs に無い (新しいマシンで Install-* が入れられない)
# - パッケージが winget-pkgs に無い (Microsoft.OpenSSH.Beta は 2025-04-09 に全部の版が外された)
# - 版の形でないディレクトリがある (版の付け方が変わると、新しい版を読み落とす)
# - GitHub の最新の release から版が読めない (openssh は OpenSSH-Win64-v<版>.msi が無い、herdr は tag が
#   preview-<日付>-<hash> の形でない)・取った release に winget に載る側のものが無い (herdr なら preview が
#   無い)。出し方や付け方が変わると、版も出た日も引けない
#
# 確かめられなかったとき (ps1 が読めない・見送りの一覧が壊れている・API の失敗・gh が無い・猶予の日数が
# 読めない) は exit 2。揃っている扱いにはしない。出た日を引く一覧 (GitHub の release・winget-pkgs の commit)
# だけが取れないときも、新しい版が猶予の中かを決められないので exit 2。知らせることもあれば exit 1 を優先する。
# GitHub Actions の中では、落ちる理由を ::error の行にも出す (実行の画面の先頭に出る。題は名前ごと)。
#
# ## 見送りの一覧
#
# 1 行に 1 つ、「版 理由」を空白で区切って書く。# で始まる行と空行は読まない。理由の無い行と、版が
# その名前の版の形でない行は exit 2。固定した版以下になった行は、消してよいと出すだけで落とさない。
# 版は鍵 (herdr は -preview. の後ろの <日付>-<hash>) で比べる。herdr は、winget に無い preview のために
# 鍵だけの行も書ける (semver が分からない)。
#
# ## 依存
#
# bash・gh (GitHub API。CI では GH_TOKEN)・jq・sort (-V)。GitHub の ubuntu のランナーには
# どれも最初から入っている。

set -eu -o pipefail

# 新しい版を知らせるまでの猶予 (出てからの日数)。決めるのはここ 1 か所だけ (3 つの名前で同じ)。
# テストは CHECK_WINGET_VERSION_GRACE_DAYS で変える (空なら既定)
grace_days=${CHECK_WINGET_VERSION_GRACE_DAYS:-30}

script_dir=$(
  cd -- "$(dirname -- "$0")" &>/dev/null
  pwd -P
)
repo_dir=$(dirname "$(dirname "${script_dir}")")

usage() {
  cat <<'EOS'
Windows で winget の版を固定しているものが、winget の最新に追いついているかを確かめる。

使い方:
  check-winget-version.sh <名前> [<Install-*.ps1> [<skipped-versions.txt>]]

  名前: openssh・herdr・google-japanese-input
  ps1 と見送りの一覧の既定は、repo の win/<名前>/ の Install-*.ps1 と skipped-versions.txt。

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
if ((${#args[@]} < 1 || ${#args[@]} > 3)); then
  usage >&2
  exit 2
fi
name=${args[0]}

# 名前ごとに違うもの。dates_from は出た日の取り方 (github: GitHub の release / winget: winget-pkgs の commit)。
# github のときは、release から winget の版に突き合わせる鍵 (release_key。読めなければ "") と、winget に
# 載る側の release か (release_channel) を jq の式で持つ。key_strip は、winget の版から鍵を出すときに
# 前から外す glob。見送りの一覧の版も、比べるときは鍵にする。skip_re は見送りの一覧の版の形 (空なら version_re)。
# ahead_by は、GitHub の release が winget の最新より新しいかの決め方 (version: 鍵を sort -V で比べる /
# published: winget の最新に合う release より後に出たか。合う release が無ければ鍵で比べる)
release_key=''
release_channel=''
releases_repo=''
releases_per_page=30
key_strip=''
skip_re=''
skip_note=''
ahead_by=version
channel_desc=''
latest_word=''
ahead_word=''
key_missing=''
moved_example=''
case ${name} in
  openssh)
    title='Windows の OpenSSH'
    ps1_name=Install-OpenSSH.ps1
    version_re='^[0-9]+(\.[0-9]+){1,3}$'
    version_example=10.1.0.0
    readme_section='OpenSSH の新しい版が出たとき'
    search_word=OpenSSH
    upgrade_before='入れずに試してから、'
    upgrade_after=''
    dates_from=github
    releases_repo=PowerShell/Win32-OpenSSH
    release_key='[.assets[]?.name | capture("^OpenSSH-Win64-v(?<v>[0-9]+(\\.[0-9]+){1,3})\\.msi$").v] | first // ""'
    # prerelease は winget に載らない
    release_channel='.prerelease | not'
    channel_desc='prerelease でない release'
    latest_word=release
    key_missing='に OpenSSH-Win64-v<版>.msi が無い'
    moved_example='Beta から Preview へ移った前例がある'
    ;;
  herdr)
    title='Windows の herdr'
    ps1_name=Install-Herdr.ps1
    version_re='^[0-9]+\.[0-9]+\.[0-9]+-preview\.[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]+$'
    version_example=0.9.3-preview.2026-10-12-6d697e1e75ff
    readme_section='herdr の新しい版が出たとき'
    search_word=herdr
    upgrade_before='変更点を読み、'
    upgrade_after=''
    dates_from=github
    releases_repo=herdrdev/herdr
    # preview と安定版がそれぞれ週に何度か出るので、30 件では 2 か月ほどしか遡れない
    releases_per_page=100
    release_key='(.tag_name // "" | capture("^preview-(?<k>[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]+)$").k) // ""'
    # winget の Herdr.Herdr.Preview に載るのは preview の build (GitHub では prerelease) だけ。
    # 安定版 (vX.Y.Z) は winget にパッケージが無い
    release_channel='.prerelease == true'
    key_strip='*-preview.'
    # winget に無い preview は semver が分からないので、見送りの一覧には鍵 (<日付>-<hash>) だけも書ける
    skip_re='^([0-9]+\.[0-9]+\.[0-9]+-preview\.)?[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]+$'
    skip_note='。winget に無い preview は -preview. の後ろ (<日付>-<hash>) だけでもよい'
    # 鍵の並びでは、同じ日の build の前後が hash の大小になる
    ahead_by=published
    channel_desc=preview
    latest_word=preview
    ahead_word='preview の '
    key_missing='の tag が preview-<日付>-<hash> の形でない'
    moved_example='安定版のパッケージができて preview が止まった、など'
    ;;
  google-japanese-input)
    title='Google 日本語入力'
    ps1_name=Install-GoogleJapaneseInput.ps1
    version_re='^[0-9]+(\.[0-9]+){1,3}$'
    version_example=3.35.6300.0
    readme_section='Google 日本語入力の新しい版が出たとき'
    search_word=JapaneseIME
    upgrade_before=''
    upgrade_after='。この PC で上げて設定を読み書きできるかを確かめてから commit する'
    dates_from=winget
    ;;
  *)
    echo "知らない名前です: ${name} (openssh・herdr・google-japanese-input のどれか)" >&2
    usage >&2
    exit 2
    ;;
esac
if [[ ${dates_from} == github ]]; then
  born_ta='GitHub に出た'
  born_te='GitHub に出て'
  undated_why='に合う GitHub の release が無く'
  notes_word='release notes'
  sources_word='winget にも GitHub にも'
else
  born_ta='winget に載った'
  born_te='winget に載って'
  undated_why='を足した winget-pkgs の commit が見つからず'
  notes_word='manifest'
  sources_word='winget に'
fi
install_cmd=${ps1_name%.ps1}

ps1=${args[1]:-${repo_dir}/win/${name}/${ps1_name}}
skipped_file=${args[2]:-${repo_dir}/win/${name}/skipped-versions.txt}
# 出力では、repo の中のファイルを repo からのパスで見せる (CI ではランナーの長いパスになるため)
ps1_label=${ps1#"${repo_dir}/"}
skipped_label=${skipped_file#"${repo_dir}/"}

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
  echo "::${level} title=${title}::${m}"
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

# winget の版から、release の鍵を出す (herdr は -preview. の後ろ。ほかは版そのまま)
key_of() {
  # shellcheck disable=SC2295 # key_strip は glob のパターンとして効かせる
  printf '%s' "${1#${key_strip}}"
}

# 030 のような 0 始まりは、bash の算術で 8 進数として読まれるので受けない
if [[ ! ${grace_days} =~ ^(0|[1-9][0-9]*)$ ]]; then
  cannot_check "猶予の日数が読めません (CHECK_WINGET_VERSION_GRACE_DAYS=${grace_days})。0 か、0 で始まらない整数 (日数) を渡す。"
fi

for c in gh jq; do
  if ! command -v "${c}" &>/dev/null; then
    cannot_check "${c} が見つかりません (CI なら GitHub の ubuntu のランナーに入っている。手元なら home-manager switch)。"
  fi
done

# ps1 から、固定した版 (param の [string]$Version = '<版>') とパッケージ ID ($packageId = '<ID>') を読む
if [[ ! -r ${ps1} ]]; then
  cannot_check "${ps1_name} が読めません: ${ps1_label}"
fi
pinned=""
pinned_line=0
package_id=""
pinned_re="^[[:space:]]*\\[string\\][\$]Version[[:space:]]*=[[:space:]]*'([^']*)'"
id_re="^[[:space:]]*[\$]packageId[[:space:]]*=[[:space:]]*'([A-Za-z0-9][A-Za-z0-9.-]*)'"
while IFS= read -r line || [[ -n ${line} ]]; do
  if ((! pinned_line)) && [[ ${line} =~ ${pinned_re} ]]; then
    pinned=${BASH_REMATCH[1]}
    pinned_line=1
  elif [[ -z ${package_id} && ${line} =~ ${id_re} ]]; then
    package_id=${BASH_REMATCH[1]}
  fi
done <"${ps1}"
if ((! pinned_line)); then
  cannot_check "固定した版が読めません: ${ps1_label} に [string]\$Version = '<版>' の行がありません。"
fi
if [[ ! ${pinned} =~ ${version_re} ]]; then
  cannot_check "固定した版が読めません: ${ps1_label} の -Version の既定値 '${pinned}' が ${title} の版の形ではありません (例: ${version_example})。"
fi
if [[ -z ${package_id} ]]; then
  cannot_check "パッケージ ID が読めません: ${ps1_label} に \$packageId = '<ID>' の行がありません。"
fi
# winget-pkgs の置き場所: manifests/<ID の頭文字 (小文字)>/<ID の . を / にしたもの>
initial=${package_id:0:1}
manifest_dir="manifests/${initial,,}/${package_id//.//}"
contents_api="repos/microsoft/winget-pkgs/contents/${manifest_dir}"
tree_url="https://github.com/microsoft/winget-pkgs/tree/master/${manifest_dir}"

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
    if [[ ! ${v} =~ ${skip_re:-${version_re}} || -z ${reason} ]]; then
      cannot_check "見送りの一覧の ${n} 行目が読めません (${skipped_label}): ${line}" \
        "1 行に「版 理由」を空白で区切って書く。版は ${title} の版の形 (例: ${version_example} 試したら設定が読めなかった)${skip_note}。"
    fi
    skipped_versions+=("${v}")
    skipped_reasons+=("${reason}")
  done <"${skipped_file}"
fi

# winget の版 $1 を見送っていれば、理由を出して 0 を返す (鍵で比べる)
skip_reason() {
  local i key
  key=$(key_of "$1")
  for i in "${!skipped_versions[@]}"; do
    if [[ $(key_of "${skipped_versions[i]}") == "${key}" ]]; then
      printf '%s' "${skipped_reasons[i]}"
      return 0
    fi
  done
  return 1
}

# release の鍵 $1 に当たる版を見送っていれば 0 を返す (見送りの一覧の版から鍵を出して比べる)
skipped_key() {
  local v
  for v in "${skipped_versions[@]}"; do
    if [[ $(key_of "${v}") == "$1" ]]; then
      return 0
    fi
  done
  return 1
}

# winget の版 $1 の出た日の行 (date_rows の 1 行) を出す。いくつかあれば、いちばん早く出たもの。
# 無ければ 1 を返す
dated() {
  local key row
  key=$(key_of "$1")
  while IFS= read -r row; do
    if [[ -n ${row} && ${row%%$'\x1f'*} == "${key}" ]]; then
      printf '%s\n' "${row}"
      return 0
    fi
  done <<<"${date_rows}"
  return 1
}

# 出た日の分からない版に、release notes などの代わりに添える URL
fallback_url() {
  if [[ ${dates_from} == github ]]; then
    echo "https://github.com/${releases_repo}/releases"
  else
    echo "${tree_url}/$1"
  fi
}

# 猶予の中の版の、出た日とあと何日で知らせるか。$1: 追いついていない版の数、$2: いちばん早く出た版、
# $3: その版が出た日、$4: 出てからの日数
grace_left() {
  local who=""
  if (($1 > 1)); then
    who="、いちばん早い $2 が"
  fi
  echo "${born_ta}のは${who} $3 ($4 日前)。あと $((grace_days - $4)) 日で知らせる (猶予 ${grace_days} 日)"
}

# 猶予がたった版の、出てからの日数。引数は grace_left の $1・$2・$4
grace_over() {
  local who=""
  if (($1 > 1)); then
    who="いちばん早い $2 が "
  fi
  echo "${who}${born_te} $3 日たった。猶予は ${grace_days} 日"
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
echo "${title} (winget の ${package_id})"
echo "  固定した版    : ${pinned} (${ps1_label} の -Version の既定値)"

if ((gone)); then
  echo "⚠ ${package_id} が winget-pkgs に無い (${manifest_dir} が無い)。winget で入れられない"
  echo "    winget search ${search_word} で今のパッケージ ID を探し、${ps1_label} の \$packageId を直す"
  findings+=("${package_id} が winget-pkgs に無い")
  annotate error "${findings[-1]}"
  exit 1
fi

# winget の版 (新しい順)。固定した版が winget にあれば、それより古い版は数だけにする (herdr の preview は
# 週に何度も増える)。無ければ、選び直せるよう全部を出す
pinned_listed=0
if grep -qxF "${pinned}" <<<"${versions}"; then
  pinned_listed=1
  shown=()
  older=0
  while IFS= read -r v; do
    if [[ ${v} == "${pinned}" ]] || newer_than "${v}" "${pinned}"; then
      shown+=("${v}")
    else
      older=$((older + 1))
    fi
  done <<<"${versions}"
  list="${shown[*]}"
  if ((older)); then
    list+=" (ほかに古い版が ${older} 個)"
  fi
else
  list=$(tr '\n' ' ' <<<"${versions}")
  list=${list% }
fi
echo "  winget の版   : ${list}"
winget_latest=$(head -n 1 <<<"${versions}")

if [[ -n ${odd} ]]; then
  echo "⚠ 版の形でないディレクトリが winget-pkgs の ${manifest_dir} にある: $(tr '\n' ' ' <<<"${odd}")"
  echo "    版の付け方が変わったなら、新しい版を読み落とす。この script の版の読み方を直す"
  findings+=("版の形でないディレクトリが winget-pkgs にある: $(tr '\n' ' ' <<<"${odd}")")
fi

if ((! pinned_listed)); then
  echo "⚠ 固定した版 ${pinned} が winget-pkgs に無い。新しいマシンで ${install_cmd} が入れられない"
  echo "    winget の版から選び直し、-Version の既定値を変える (win/README.md の「${readme_section}」)"
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

# 出た日を引く。date_rows は、出た日の分かる版 (release の鍵) を出た順 (古い順) に 1 行ずつ、鍵・出た時刻
# (epoch)・出た日・出てからの日数・winget に載る側か (1 / 0)・URL。空の欄が詰まらないよう、区切りは空白でない
# \x1f にする
dates_ok=0
dates_problem=""
date_rows=""
latest=""
if [[ ${dates_from} == github ]]; then
  # GitHub の releases。新しい版が出た日と release notes の URL を引くのと、winget に載るのが止まって
  # いないかを見る。latest は、下書きを除き winget に載る側でいちばん新しく出た release の tag・鍵・
  # 出てからの日数・URL
  releases_api="repos/${releases_repo}/releases?per_page=${releases_per_page}"
  jq_defs="def key: ${release_key}; def channel: ${release_channel};"
  if gh api "${releases_api}" >"${tmp}/releases.json" 2>"${tmp}/releases.err"; then
    # latest は、winget に載る側の release が取った中に 1 つも無ければ空 (読めないのとは分けて知らせる)
    if date_rows=$(jq -r "${jq_defs}"'
        if type == "array" then . else error("release の一覧ではない") end
        | [.[] | select((.draft | not) and .published_at != null)
          | { k: (key), at: (.published_at | fromdateiso8601), day: .published_at[0:10],
              ch: (channel), url: .html_url }
          | select(.k != "") ]
        | sort_by(.at)[]
        | [ .k, (.at | tostring), .day, ((now - .at) / 86400 | floor | tostring),
            (if .ch then "1" else "0" end), .url ]
        | join("\u001f")' "${tmp}/releases.json" 2>/dev/null) \
      && latest=$(jq -r "${jq_defs}"'
        [.[] | select((.draft | not) and channel)] | max_by(.published_at) // empty
        | [ .tag_name, key, ((now - (.published_at | fromdateiso8601)) / 86400 | floor | tostring), .html_url ]
        | join("\u001f")' "${tmp}/releases.json" 2>/dev/null); then
      dates_ok=1
    else
      dates_problem="GitHub の release の一覧が読めない (${releases_api} の応答が release の一覧ではない)"
    fi
  else
    dates_problem="GitHub の release の一覧が取れない ($(head -n 1 "${tmp}/releases.err"))"
  fi
elif ((${#unskipped[@]})); then
  # winget-pkgs に載った日。新しい版ごとに、その版のディレクトリの commit の一覧 (新しい順) を引き、
  # いちばん古い commit (その版を足した commit) の日を取る。URL は manifest のディレクトリ
  dates_ok=1
  for v in "${unskipped[@]}"; do
    commits_api="repos/microsoft/winget-pkgs/commits?path=${manifest_dir}/${v}&per_page=100"
    if ! gh api "${commits_api}" >"${tmp}/commits.json" 2>"${tmp}/commits.err"; then
      dates_ok=0
      dates_problem="winget-pkgs の commit の一覧が取れない ($(head -n 1 "${tmp}/commits.err"))"
      break
    fi
    if ! row=$(jq -r --arg v "${v}" --arg url "${tree_url}/${v}" '
        if type == "array" then . else error("commit の一覧ではない") end
        | last // empty
        | (.commit.committer.date | fromdateiso8601) as $at
        | [ $v, ($at | tostring), .commit.committer.date[0:10], ((now - $at) / 86400 | floor | tostring), "1", $url ]
        | join("\u001f")' "${tmp}/commits.json" 2>/dev/null); then
      dates_ok=0
      dates_problem="winget-pkgs の commit の一覧が読めない (${commits_api} の応答が commit の一覧ではない)"
      break
    fi
    if [[ -n ${row} ]]; then
      date_rows+=${row}$'\n'
    fi
  done
fi

# 固定した版より新しく、見送っていない版。出てから猶予の日数がたつまでは待つ。数えるのは
# いちばん早く出た版から (遅れ始めてから数える)。出た日が分からない版があれば待たない
waiting=0
if ((${#unskipped[@]})); then
  if ((dates_ok)); then
    first_v=""
    first_at=""
    first_day=""
    first_age=0
    undated=()
    for v in "${unskipped[@]}"; do
      if row=$(dated "${v}"); then
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
        why="${undated[*]} ${undated_why}、出た日が分からないので待たない"
      else
        why=$(grace_over "${#unskipped[@]}" "${first_v}" "${first_age}")
      fi
      echo "⚠ 固定した版 ${pinned} より新しい版が winget にある: ${unskipped[*]} (${why})"
      for v in "${unskipped[@]}"; do
        url=""
        if row=$(dated "${v}"); then
          url=${row##*$'\x1f'}
        fi
        echo "    ${v} の ${notes_word}: ${url:-$(fallback_url "${v}")}"
      done
      echo "⚠ 上げるか見送るかを決める (win/README.md の「${readme_section}」):"
      echo "    上げる: ${upgrade_before}${ps1_label} の -Version の既定値を変える${upgrade_after}"
      echo "    見送る: ${skipped_label} に「版 理由」を 1 行足す"
      findings+=("固定した版 ${pinned} より新しい ${unskipped[*]} が winget にある (上げるか見送るかを決める)")
    fi
  else
    echo "  ※ 固定した版 ${pinned} より新しい ${unskipped[*]} が winget にあるが、${born_ta}日が分からず、待つか知らせるかを決められない"
  fi
fi

# GitHub と比べる (openssh と herdr)。winget に載る側の release で、winget のこのパッケージの最新より新しいのに
# winget に無い版 (見送った版は除く) を、猶予がたったら知らせる
if [[ ${dates_from} == github ]]; then
  if ((dates_ok)) && [[ -z ${latest} ]]; then
    echo "⚠ GitHub の直近 ${releases_per_page} 件の release に ${channel_desc} が無い。出し方や付け方が変わったなら、この script の読み方を直す"
    echo "    https://github.com/${releases_repo}/releases"
    findings+=("GitHub の直近 ${releases_per_page} 件の release に ${channel_desc} が無い")
  elif ((dates_ok)); then
    IFS=$'\x1f' read -r gh_tag gh_key gh_age gh_url <<<"${latest}"
    echo "  GitHub の最新 : ${gh_key:-?} (${gh_tag}、出て ${gh_age} 日)"
    if [[ -z ${gh_key} ]]; then
      echo "⚠ GitHub の最新 ${latest_word} ${gh_tag} ${key_missing}。付け方が変わったなら、この script の読み方を直す"
      echo "    ${gh_url}"
      findings+=("GitHub の最新 ${latest_word} ${gh_tag} ${key_missing}")
    elif [[ -n ${winget_latest} ]]; then
      winget_latest_key=$(key_of "${winget_latest}")
      winget_latest_at=""
      if [[ ${ahead_by} == published ]] && row=$(dated "${winget_latest}"); then
        IFS=$'\x1f' read -r _ winget_latest_at _ <<<"${row}"
      fi
      # 鍵 $1・出た時刻 $2 の release が、winget の最新より新しいか (ahead_by で決め方が変わる)
      after_winget_latest() {
        if [[ -n ${winget_latest_at} ]]; then
          (($2 > winget_latest_at))
        else
          newer_than "$1" "${winget_latest_key}"
        fi
      }
      winget_keys=""
      while IFS= read -r v; do
        winget_keys+=$(key_of "${v}")$'\n'
      done <<<"${versions}"
      # date_rows は出た順なので、最初に見つかった行がいちばん早く出た版
      ahead=()
      ahead_row=""
      while IFS= read -r row; do
        if [[ -z ${row} ]]; then
          continue
        fi
        IFS=$'\x1f' read -r k at _ _ ch _ <<<"${row}"
        if [[ ${ch} == 1 && " ${ahead[*]-} " != *" ${k} "* ]] && after_winget_latest "${k}" "${at}" \
          && ! grep -qxF "${k}" <<<"${winget_keys}" && ! skipped_key "${k}"; then
          ahead+=("${k}")
          if [[ -z ${ahead_row} ]]; then
            ahead_row=${row}
          fi
        fi
      done <<<"${date_rows}"
      if ((${#ahead[@]})); then
        IFS=$'\x1f' read -r first_v _ first_day first_age _ first_url <<<"${ahead_row}"
        if ((first_age < grace_days)); then
          waiting=1
          wait_note "GitHub の ${ahead_word}${ahead[*]} が winget の ${package_id} にまだ無い。$(grace_left "${#ahead[@]}" "${first_v}" "${first_day}" "${first_age}")"
        else
          why=$(grace_over "${#ahead[@]}" "${first_v}" "${first_age}")
          echo "⚠ GitHub の ${ahead_word}${ahead[*]} が winget の ${package_id} に無い (${why})"
          echo "    パッケージ ID が移ったかもしれない (${moved_example})。winget search ${search_word} で確かめる"
          echo "    ${first_url}"
          findings+=("GitHub の ${ahead_word}${ahead[*]} が winget の ${package_id} に無い (${why})")
        fi
      fi
    fi
  else
    echo "  ※ ${dates_problem}"
  fi
fi

for i in "${!skipped_versions[@]}"; do
  if ! newer_than "$(key_of "${skipped_versions[i]}")" "$(key_of "${pinned}")"; then
    echo "  ※ 見送りの一覧の ${skipped_versions[i]} は固定した版 (${pinned}) 以下なので、消してよい"
  fi
done

if ((${#findings[@]})); then
  for f in "${findings[@]}"; do
    annotate error "${f}"
  done
  exit 1
fi
if [[ -n ${dates_problem} ]]; then
  if ((${#unskipped[@]})); then
    cannot_check "${dates_problem}" "固定した版より新しい ${unskipped[*]} が ${born_ta}日が分からず、猶予の中かを決められなかった。"
  fi
  cannot_check "${dates_problem}" "winget の版では知らせることは無いが、GitHub の最新 ${latest_word} と比べられなかった。"
fi
if ((waiting)); then
  echo "知らせることは無い (新しい版は猶予の中。上げるか見送るかは、知らせる前に決めてもよい)。"
else
  echo "固定した版 ${pinned} より新しい版で、見送っていないものは ${sources_word}無い。"
fi
exit 0
